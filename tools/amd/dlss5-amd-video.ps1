param(
    [Parameter(Mandatory=$true)][string]$Video,
    [Parameter(Mandatory=$true)][string]$Out,
    [double]$Scale = 1.0,
    [int]$Passes = 1,
    [int]$Crf = 16,
    [int]$SegmentFrames = 450,
    [string]$Work = '',
    [string]$Framecheck = ''
)

# Direct DLSS5 (DLSS-NR) video processing, segmented.
#
# 4K frames are 25 MB (PPM) and 33 MB (RGBA composed) each, so a whole film does
# not fit on disk as one batch: 140 s of 4K needs 243 GB. Each segment decodes,
# runs the network, encodes, and is deleted before the next one starts, so the
# peak footprint is one segment regardless of how long the film is. Segments are
# joined with the concat demuxer, which copies the video without re-encoding it.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The encoder writes $Out directly and ffmpeg does not create directories, so a
# destination folder that does not exist yet fails the join - after every segment
# has already been rendered and encoded. That happened once during development and
# cost about an hour of GPU time, so the folder is made up front and again just
# before the join.
$outParent = Split-Path -Parent $Out
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Work) { $Work = Join-Path $repo 'build\amd-video-work' }
$ff      = Join-Path $repo 'external\ffmpeg\bin\ffmpeg.exe'
$ffp     = Join-Path $repo 'external\ffmpeg\bin\ffprobe.exe'
$runtime = Join-Path $repo 'build\neural-runtime'

# framecheck is OpenNR's own offline harness: it includes the add-on's neural code
# and drives the runtime through the same call sequence a frame goes through, which
# is what makes this a direct DLSS5 pass rather than a re-implementation.
$frameck = if ($Framecheck) { $Framecheck } else { Join-Path $repo 'external\opennr\build\amd-nr-framecheck.exe' }
if (-not (Test-Path $frameck)) {
    throw @"
amd-nr-framecheck.exe not found at $frameck

Build it from OpenNR's source once (https://github.com/zmodelerlover/OpenNR-ReShade):
    git clone https://github.com/zmodelerlover/OpenNR-ReShade external\opennr
    cd external\opennr
    .\build.ps1 -Target framecheck -Exe

Then pass its path with -Framecheck, or leave it where this script expects it.
"@
}

foreach ($p in @($ff, $ffp, $frameck)) {
    if (-not (Test-Path $p)) { throw "missing tool: $p" }
}
foreach ($n in 'dlssnr_amd_pass1.dll','dlssnr_on_amd_weights.bin') {
    if (-not (Test-Path (Join-Path $runtime $n))) { throw "missing runtime file: $n" }
}

# ---- source ---------------------------------------------------------------
$probe = & $ffp -v error -select_streams v:0 `
    -show_entries stream=width,height,r_frame_rate,nb_frames `
    -show_entries format=duration -of default=noprint_wrappers=1 $Video
$w   = [int](($probe | Where-Object { $_ -match '^width=' })  -replace 'width=','')
$h   = [int](($probe | Where-Object { $_ -match '^height=' }) -replace 'height=','')
$fpsText = ($probe | Where-Object { $_ -match '^r_frame_rate=' }) -replace 'r_frame_rate=',''
$num,$den = $fpsText -split '/'
if (-not $den -or [double]$den -eq 0) { $den = 1 }
$fps = [double]$num / [double]$den
$dur = [double](($probe | Where-Object { $_ -match '^duration=' }) -replace 'duration=','')
$total = if ($dur -gt 0 -and $fps -gt 0) { [int][Math]::Ceiling($dur * $fps) } else { 0 }
if ($w -le 0 -or $h -le 0) { throw 'could not read the source geometry' }

Write-Host '== source =='
Write-Host ("   {0}x{1} @ {2:N3} fps, {3:N1}s (~{4} frames)" -f $w, $h, $fps, $dur, $total)
$perMB = ($w * $h * 4) / 1MB
Write-Host ("   per segment peak ~{0:N0} MB disk ({1} frames)" -f (($w*$h*3 + $w*$h*4) * $SegmentFrames / 1MB), $SegmentFrames)

# ---- runtime beside framecheck -------------------------------------------
$stage = Join-Path $Work 'rt'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item $frameck (Join-Path $stage 'amd-nr-framecheck.exe') -Force
Copy-Item (Join-Path $runtime 'dlssnr_amd_pass1.dll') $stage -Force
Copy-Item (Join-Path $runtime 'dlssnr_on_amd_weights.bin') $stage -Force
Set-Content (Join-Path $stage 'amd-nr.ini') @"
[amd-nr]
StartOn=1
Scale=$Scale
Passes=$Passes
Encoding=0
Language=0
Intensity=1
Style=0
Depth=0
GameGuides=0
Motion=1
History=1
Temporal=2
"@ -Encoding ASCII
Set-Content (Join-Path $stage 'dlssnr_on_amd.ini') @"
[DlssNrOnAmd]
Enabled=1
Async=0
InlineWaitMs=200
Interop=1
UseFsrInputs=1
UseDepth=0
Temporal=0
Tonemap=0
HipDevice=-1
"@ -Encoding ASCII

$parts   = Join-Path $Work 'parts'
$listTxt = Join-Path $Work 'parts.txt'
# Clear only the parts and the list. $stage holds the runtime beside framecheck
# and must survive, so it is not touched here.
if (Test-Path $parts) { Remove-Item $parts -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $parts | Out-Null
if (Test-Path $listTxt) { Remove-Item $listTxt -Force }
if (Test-Path $Out) { Remove-Item $Out -Force }

$start = 0
$seg   = 0
$done  = 0
$swAll = [Diagnostics.Stopwatch]::StartNew()

while ($true) {
    $seg++
    $segW = Join-Path $Work "seg$seg"
    $inD  = Join-Path $segW 'in'
    New-Item -ItemType Directory -Force -Path $inD | Out-Null

    # --- decode this segment ---------------------------------------------
    # Seek first (-ss before -i) and cap the count (-frames:v), so each segment
    # reads only its own span instead of decoding from the start of the film.
    # The earlier select-based form re-decoded up to frame N for every segment,
    # which made later segments quadratically slower.
    $skipSec = $start / $fps
    $segLimit = if ($total -gt 0) { [Math]::Min($SegmentFrames, $total - $start) } else { $SegmentFrames }
    & $ff -hide_banner -loglevel error -ss ('{0:N6}' -f $skipSec) -i $Video `
          -frames:v $segLimit -fps_mode passthrough -vf 'format=rgb24' `
          -f image2 -start_number 0 (Join-Path $inD 'frame%04d.ppm')
    if ($LASTEXITCODE -ne 0) { throw "decode failed on segment $seg" }
    $n = (Get-ChildItem $inD -Filter '*.ppm').Count
    if ($n -eq 0) { Write-Host "   segment ${seg}: nothing left"; Remove-Item $segW -Recurse -Force; break }

    Write-Host ''
    Write-Host ("== segment {0}: frames {1}..{2} ({3} frames) ==" -f $seg, $start, ($start+$n-1), $n)

    # --- network ----------------------------------------------------------
    Push-Location $stage
    try {
        & cmd.exe /c "amd-nr-framecheck.exe --seq `"$inD`" frames=$n dump=composed 2>&1" |
            Tee-Object -FilePath (Join-Path $segW 'fc.out') | Out-Null
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) {
        Get-Content (Join-Path $segW 'fc.out') | Select-Object -Last 4 | ForEach-Object { "   $_" }
        $rtLog = Join-Path $stage 'dlssnr_on_amd.log'
        if (Test-Path $rtLog) { Write-Host '   -- runtime --'; Get-Content $rtLog | Select-Object -Last 6 | ForEach-Object { "      $_" } }
        throw "DLSS-NR failed on segment $seg (exit $code)"
    }

    # --- concatenate + encode --------------------------------------------
    # Wait until the dump stops growing. framecheck can return while the last
    # files it wrote are still being flushed, and copying during that window
    # produced a short composed.raw (24.5 frames of 60) with every file later
    # reading as complete - the length at copy time is what matters, not after.
    $expectBytes = [int64]$w * $h * 4 * $n
    $stableFor = 0
    $lastSum = -1
    for ($i = 0; $i -lt 120; $i++) {
        $sum = (Get-ChildItem $stage -Filter 's*-composed.raw' -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        if ($sum -eq $lastSum -and $sum -ge $expectBytes) { $stableFor++; if ($stableFor -ge 2) { break } } else { $stableFor = 0 }
        $lastSum = $sum
        Start-Sleep -Milliseconds 250
    }
    if ($lastSum -lt $expectBytes) {
        throw "segment ${seg}: dump incomplete, $lastSum of $expectBytes bytes"
    }

    $raw = @(Get-ChildItem $stage -Filter 's*-composed.raw' | Sort-Object { [int]($_.Name.Substring(1,4)) })
    if ($raw.Count -eq 0) { throw "no composed frames in segment $seg" }
    $allRaw = Join-Path $segW 'composed.raw'
    $fs = [System.IO.File]::Create($allRaw)
    try {
        $buf = New-Object byte[] (16MB)
        foreach ($f in $raw) {
            $src = [System.IO.File]::OpenRead($f.FullName)
            try { while (($r = $src.Read($buf,0,$buf.Length)) -gt 0) { $fs.Write($buf,0,$r) } }
            finally { $src.Close() }
        }
    } finally { $fs.Close() }
    $expect = [int64]$w * $h * 4 * $raw.Count
    $got = (Get-Item $allRaw).Length
    if ($got -ne $expect) { throw "segment $seg size mismatch: $got vs $expect" }
    # Only once the copy is complete and verified, so a delete can never race
    # the enumeration above.
    foreach ($f in $raw) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }

    $part = Join-Path $parts ('part{0:D4}.mp4' -f $seg)
    & $ff -hide_banner -loglevel error -f rawvideo -pixel_format rgba -video_size "${w}x${h}" `
          -framerate $fps -i $allRaw -c:v libx264 -crf $Crf -pix_fmt yuv420p -an -y $part
    if ($LASTEXITCODE -ne 0) { throw "encode failed on segment $seg" }
    Add-Content $listTxt ("file '{0}'" -f ($part -replace '\\','/'))

    $done += $raw.Count
    $elapsed = $swAll.Elapsed.TotalSeconds
    $rate = if ($done -gt 0) { $elapsed / $done } else { 0 }
    $eta  = if ($total -gt 0 -and $done -gt 0) { ($total - $done) * $rate } else { 0 }
    Write-Host ("   encoded part{0:D4}.mp4  [{1}/{2} frames, {3:N0} ms/frame, ETA {4:N0} min]" -f `
        $seg, $done, $total, ($rate*1000), ($eta/60))

    # --- free the segment before the next one -----------------------------
    Remove-Item $segW -Recurse -Force -ErrorAction SilentlyContinue

    if ($total -gt 0 -and $done -ge $total) { break }
    if ($n -lt $SegmentFrames) { break }
    $start += $SegmentFrames
}

$parts_ = Get-ChildItem $parts -Filter 'part*.mp4' | Sort-Object Name
Write-Host ''
Write-Host ("== joining {0} parts ==" -f $parts_.Count)
if ($parts_.Count -eq 0) { throw 'no parts produced' }
# Again here: an hour of rendering must not be lost to a missing folder.
if ($outParent) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
if ($parts_.Count -eq 1) {
    & $ff -hide_banner -loglevel error -i $parts_[0].FullName -i $Video -map 0:v:0 -map 1:a:0? -c:v copy -c:a copy -shortest -y $Out
} else {
    & $ff -hide_banner -loglevel error -f concat -safe 0 -i $listTxt -i $Video `
          -map 0:v:0 -map 1:a:0? -c:v copy -c:a copy -shortest -y $Out
}
if ($LASTEXITCODE -ne 0) { throw "join failed ($LASTEXITCODE)" }

$o = Get-Item $Out
$swAll.Stop()
Write-Host ''
Write-Host ("DONE: {0}" -f $o.FullName)
Write-Host ("      {0:N1} MB, {1} frames, {2}x{3}, {4:N1} min total" -f `
    ($o.Length/1MB), $done, $w, $h, ($swAll.Elapsed.TotalMinutes))
