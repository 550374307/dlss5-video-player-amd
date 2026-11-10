<#
.SYNOPSIS
    Fetches and stages the AMD neural-runtime set beside a built DLSSVideoPlayer.exe.

.DESCRIPTION
    The NVIDIA runtime set is fetched by tools\fetch_neural_runtime.ps1 and verified
    against packaging\runtime-lock.json. This is the AMD counterpart: the same four
    roles (a ReShade proxy, an add-on, a neural runtime and its weights) under the
    names the AMD backend uses, verified against packaging\runtime-lock-amd.json.

    Nothing here is redistributed by this repository. Every file comes from its own
    publisher, at the pinned digest, and the runtime and weights are NVIDIA-derived
    community work with their own terms - see THIRD_PARTY.md.

    What gets staged into <Destination>\neural-runtime\:
      dxgi.dll                      ReShade 6.8.0 proxy (same file the NVIDIA set uses)
      amd-nr.addon64                OpenNR add-on
      dlssnr_amd_pass1.dll          danielblnc DLSS-NR-on-AMD runtime, patched build
      dlssnr_on_amd_weights.bin     the network weights (NVIDIA-derived)
      amd-nr.ini                    defaults for the add-on
      dlssnr_on_amd.ini             defaults for the runtime
      ReShade.ini                   marks the add-on as enabled

.PARAMETER Destination
    The build output directory holding DLSSVideoPlayer.exe. Defaults to build\.

.PARAMETER Force
    Re-download and overwrite files that are already present and correct.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\amd\fetch_amd_runtime.ps1 -Destination build
#>
[CmdletBinding()]
param(
    [string]$Destination = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Destination) { $Destination = Join-Path $repositoryRoot 'build' }
$runtimeDirectory = Join-Path $Destination 'neural-runtime'
$lock = Get-Content -LiteralPath (Join-Path $repositoryRoot 'packaging\runtime-lock-amd.json') -Raw | ConvertFrom-Json

# Where each locked file comes from. The lock pins the bytes; this table says who
# publishes them, and it is kept beside the digests so a fetch can never put a file
# under a name the lock does not describe.
$sources = @{
    'dxgi.dll' = @{
        Url    = 'https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe'
        Member = 'ReShade64.dll'
        Extractor = 'zip'
    }
    'amd-nr.addon64' = @{
        Url = 'https://github.com/zmodelerlover/OpenNR-ReShade/releases/download/v0.7.15/amd-nr.addon64'
    }
    'dlssnr_amd_pass1.dll' = @{
        # The add-on patches two call sites and refuses any build it does not know,
        # so this is the patched digest, not the one inside dlssnr_on_amd_setup.exe.
        Url = 'https://huggingface.co/datasets/zmodelerlover/amd-nr/resolve/main/runtime/0.6.0/dlssnr_amd_pass1.dll'
    }
    'dlssnr_on_amd_weights.bin' = @{
        Url = 'https://huggingface.co/datasets/zmodelerlover/amd-nr/resolve/main/dlssnr_on_amd_weights.bin'
    }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-Remote([string]$Url, [string]$OutFile) {
    $attempts = 5
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.Timeout = 900000
            $request.ReadWriteTimeout = 900000
            $request.UserAgent = 'dlss5-video-player/amd-runtime-fetch'
            $request.AllowAutoRedirect = $true
            $response = $request.GetResponse()
            $expected = $response.ContentLength
            $stream = $response.GetResponseStream()
            $target = [System.IO.File]::Create($OutFile)
            try {
                $buffer = New-Object byte[] (1MB)
                $total = 0
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $target.Write($buffer, 0, $read)
                    $total += $read
                }
            } finally {
                $target.Close(); $stream.Close(); $response.Close()
            }
            if ($expected -gt 0 -and $total -ne $expected) { throw "short read $total of $expected" }
            return
        } catch {
            Write-Warning ("attempt {0}/{1} for {2}: {3}" -f $i, $attempts, (Split-Path -Leaf $Url), $_.Exception.Message)
            if ($i -eq $attempts) { throw }
            Start-Sleep -Seconds ([Math]::Min(3 * $i, 20))
        }
    }
}

function Expand-Member([string]$Archive, [string]$Member, [string]$OutFile, [string]$Extractor) {
    # ReShade ships its proxy DLLs inside a self-extracting installer that is really
    # a ZIP container; the member is lifted out without running anything.
    if ($Extractor -eq 'zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $Member } | Select-Object -First 1
            if (-not $entry) { throw "$Member not found in the ReShade installer" }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $OutFile, $true)
        } finally { $zip.Dispose() }
        return
    }
    throw "unknown extractor $Extractor"
}

New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dlss5-amd-runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

try {
    foreach ($entry in $lock.entries) {
        $name = [string]$entry.destination
        $target = Join-Path $runtimeDirectory $name
        $wanted = ([string]$entry.sha256).ToUpperInvariant()

        if ((Test-Path $target) -and -not $Force) {
            if ((Get-Sha256 $target) -eq $wanted) {
                Write-Host ("= {0} already present and verified" -f $name)
                continue
            }
            Write-Warning ("{0} is present but does not match the lock; replacing it" -f $name)
        }

        if (-not $sources.ContainsKey($name)) {
            throw "the lock names '$name' and this script has no source for it"
        }
        $source = $sources[$name]
        Write-Host ("+ {0} <- {1}" -f $name, $source.Url)

        $archive = Join-Path $scratch ([Guid]::NewGuid().ToString('N') + '.bin')
        Get-Remote $source.Url $archive
        if ($source.ContainsKey('Member')) {
            Expand-Member $archive $source.Member $target $source.Extractor
            Remove-Item $archive -Force
        } else {
            Move-Item $archive $target -Force
        }

        $actual = Get-Sha256 $target
        if ($actual -ne $wanted) {
            Remove-Item $target -Force -ErrorAction SilentlyContinue
            throw ("{0} does not match the lock: got {1}, expected {2}" -f $name, $actual, $wanted)
        }
        $size = (Get-Item $target).Length
        if ($size -ne [int64]$entry.size) {
            throw ("{0} is {1} bytes, the lock says {2}" -f $name, $size, $entry.size)
        }
        Write-Host ("  verified {0:N0} bytes" -f $size)
    }
} finally {
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# The two INI files are configuration, not identity: they are written here only when
# absent, so a user's own tuning survives an upgrade.
$addonIni = Join-Path $runtimeDirectory 'amd-nr.ini'
if (-not (Test-Path $addonIni)) {
    Set-Content -LiteralPath $addonIni -Encoding ASCII -Value @'
[amd-nr]
; Scale is the resolution the network runs at, as a fraction of the frame.
; Measured on an RX 7800 XT (gfx1101), 1080p source: 1.0 = 51.9 ms,
; 0.75 = 31.6 ms, 0.5 = 15.8 ms. 0.75 is the first rung that holds 30 fps.
StartOn=1
Scale=0.75
Passes=1
Encoding=0
Language=0
Intensity=1
Style=0
Depth=0
GameGuides=0
Motion=1
History=1
Temporal=2
'@
    Write-Host '+ wrote amd-nr.ini (Scale=0.75, the 30 fps rung on gfx1101)'
} else {
    Write-Host '= amd-nr.ini kept as it was'
}

$runtimeIni = Join-Path $runtimeDirectory 'dlssnr_on_amd.ini'
if (-not (Test-Path $runtimeIni)) {
    Set-Content -LiteralPath $runtimeIni -Encoding ASCII -Value @'
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
'@
    Write-Host '+ wrote dlssnr_on_amd.ini'
} else {
    Write-Host '= dlssnr_on_amd.ini kept as it was'
}

$reshadeIni = Join-Path $runtimeDirectory 'ReShade.ini'
if (-not (Test-Path $reshadeIni)) {
    Set-Content -LiteralPath $reshadeIni -Encoding ASCII -Value @'
[ADDON]
DisabledAddons=
'@
    Write-Host '+ wrote ReShade.ini (add-ons enabled)'
}

# The helper ships into neural-runtime\, so a build's copy has to be there too.
$worker = Join-Path $Destination 'Release\neural-runtime\NeuralWorker.exe'
$workerTarget = Join-Path $runtimeDirectory 'NeuralWorker.exe'
if ((Test-Path $worker) -and -not (Test-Path $workerTarget)) {
    Copy-Item $worker $workerTarget -Force
    Write-Host '+ copied NeuralWorker.exe from the build'
} elseif (-not (Test-Path $workerTarget)) {
    Write-Warning "NeuralWorker.exe is neither in $Destination\Release\neural-runtime nor staged; build first."
}

Write-Host ''
Write-Host "AMD neural runtime staged in $runtimeDirectory"
Write-Host 'Verify with:  dlss5-convert.exe probe <a video file>   (expect neural_runtime=verified)'
Write-Host 'The player log should then say: generation=amd-rdna3 backend=amd-hip'
