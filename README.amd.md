# Running this player on an AMD Radeon (DLSS-NR through the AMD backend)

This is an addition to the upstream project, not a replacement for it. It lets
`DLSSVideoPlayer` use the DLSS 5 neural renderer on a Radeon, where NVIDIA's NGX
feature 18 — the thing the upstream neural pass hangs off — cannot exist.

Everything upstream says about NVIDIA still holds. Nothing here loosens a gate:
the AMD path has its own runtime lock, its own preflight and its own per-frame
evidence, and every one of them fails closed exactly as the NVIDIA ones do.

---

## 1. What changed and why

Upstream decides whether neural rendering is possible from one line in
`src/RuntimePolicy.cpp`:

```cpp
if (vendorId != kNvidiaVendorId) return GpuGeneration::Unsupported;
```

A Radeon is `0x1002`, so it fell through to `Unsupported`, `NeuralAddonDesired()`
returned false, and the whole neural path was switched off. That is not a
misconfiguration — it is a hard gate, and it is correct for the architecture the
project was built on.

### Why the gate exists

The upstream neural pass does not call an inference library. `DLSSBackend`
deliberately calls the raw NGX symbols so that the RenoDX add-on in the same
process intercepts one `CreateFeature` / `EvaluateFeature`, and runs the network
*inside* that call. There is no NGX on a Radeon, so the trigger does not exist.

### What this fork does instead

The AMD backend keeps the same four roles the atomic runtime layout describes,
under the names the AMD add-on uses:

| Role | NVIDIA set | AMD set |
|---|---|---|
| Proxy | `dxgi.dll` | `dxgi.dll` (ReShade, shared) |
| Add-on | `renodx-dlss5.addon64` | `amd-nr.addon64` (OpenNR) |
| Neural runtime | `nvngx_dlssnr.dll` | `dlssnr_amd_pass1.dll` (danielblnc) |
| Weights | inside the NR DLL | `dlssnr_on_amd_weights.bin` |

`ReShade.ini` is shared. The add-on still hangs off `Present`, which is why the
worker still presents every frame — the same mechanism, different runtime.

## 2. Files

| File | What it does |
|---|---|
| `src/RuntimePolicy.h/.cpp` | `AmdRdna3` / `OtherAmd` generations; `ClassifyGpu` accepts `0x1002`; `IsAmdBackend()`; `ClassifyAmdNeuralRuntimeLayout()`; no NVIDIA driver floor on AMD |
| `src/main.cpp` | boot gate picks the layout by backend; start-screen state; `NeuralDriverNoticeText()` returns empty on AMD (the 610.47 floor is an NGX fact); convert probe picks the lock by backend |
| `src/RuntimeLock.h/.cpp` | `EmbeddedAmdRuntimeLock()`, `AmdRuntimeStaged()` |
| `packaging/runtime-lock-amd.json` | the AMD lock — same schema, same enforcement, different files |
| `src/RuntimeLockData.h.in`, `CMakeLists.txt` | embed the AMD lock at configure time |
| `src/NeuralPreflight.h/.cpp` | `AmdLockedRuntimeFileNames()` (weights included: swapping them changes the picture, so they belong in the render identity) |
| `src/NeuralPreflightProbe.cpp` | AMD preflight branch: run frames, read the add-on's own evidence, never ask NVIDIA's driver floor; `NeuralPreflightCause::AmdRuntimeFailed` |
| `src/NeuralWorkerMain.cpp` | unlocked-module check and runtime stamps pick the lock by backend |
| `src/StageExport.cpp` | export-time runtime refusal picks the lock by backend |
| `src/D3D12Renderer.h` | `SetAmdNeuralBackend()`; `DLSSFeatureCreated()` answers for it |
| `src/OfflineNeuralRenderer.cpp` | evidence source, log path, per-frame counter and failure vocabulary all branch on the backend |
| `tools/amd/fetch_amd_runtime.ps1` | fetch and verify the AMD runtime set |
| `tools/amd/dlss5-amd-video.ps1` | direct video processing through DLSS-NR, no player |

## 3. The AMD evidence chain

Upstream judges a render from `ReShade.log`: `feature 18 created`, `(native 1:1)`,
`inline feature 18 evaluation succeeded`, `EnableHooks=2: NGX hooks only`. None of
those exist on a Radeon. The AMD backend asks the same questions of `amd-nr.log`:

| What must be proved | NVIDIA evidence | AMD evidence |
|---|---|---|
| The runtime came up | `feature 18 created` | `runtime: danielblnc` + `engine ready.` |
| It ran at native size | `(native 1:1)` | `raster: … (scale 1.00)` |
| It evaluated frames | `inline feature 18 evaluation succeeded` | `frame N processed` |
| It used this player's path | `EnableHooks=2: NGX hooks only` | `HIP: adapter … matches the game's D3D12 device` |
| Nothing failed later | the NGX failure vocabulary | `engine init failed.`, `reported a native failure`, `weight files are missing`, `could not build the weights`, `engine latched async` |

Two things deliberately are **not** treated as failures, because a healthy session
logs both: `off: the game destroyed its D3D12 device` (ordinary teardown, after the
last frame) and `pass 1 refused (n total)` (a per-frame decline the add-on retries;
a good render has some and still processes every frame).

## 4. Build

The upstream guide applies, with one wrinkle found on this machine: CMake could not
discover the Visual Studio instance because `VC\Auxiliary\Build\` carried only
`Microsoft.VCToolsVersion.v143.default.txt` and CMake reads
`Microsoft.VCToolsVersion.default.txt`. That directory needs administrator rights.

Without administrator rights, load MSVC first and use Ninja:

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=amd64
cd /d <repo>
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build build --parallel
```

MSVC is still what compiles it; only the generator changes, so the MSVC-only guard
in `CMakeLists.txt` is satisfied.

## 5. Stage the runtime

```powershell
powershell -ExecutionPolicy Bypass -File tools\amd\fetch_amd_runtime.ps1 -Destination build
```

It downloads each file from its own publisher, checks it against
`packaging/runtime-lock-amd.json` (size and SHA-256), and writes the two INI files
only when absent so your tuning survives an upgrade. Nothing is redistributed here.

Verify:

```
dlss5-convert.exe probe <a video file>        # expect: neural_runtime=verified
```

and the player log should say:

```
GPU=AMD Radeon RX 7800 XT driver=… generation=amd-rdna3 backend=amd-hip
```

## 6. Measured on an RX 7800 XT (gfx1101)

GPU time per frame, network only, 1080p source:

| Scale | ms/frame | ≈ fps |
|---|---|---|
| 1.0 | 51.9 | 19 |
| 0.75 | 31.6 | 31.6 |
| 0.5 | 15.8 | 63 |

720p at 1.0 is 23.7 ms. 4K is about 200 ms of pure network.

`Scale=0.75` is the shipped default because it is the first rung that holds 30 fps
on this card. Lower it further for 4K.

The neural output was verified to be a real render rather than a passthrough:
99.88 % of pixels change, PSNR 17.10 dB against the source on a synthetic frame,
and 92.06 % / 32.17 dB on a real 4K frame at t=60 s.

## 7. Direct video processing (no player)

`tools/amd/dlss5-amd-video.ps1` runs a video through DLSS-NR and writes a new file:

```powershell
# needs OpenNR's framecheck built once:
#   git clone https://github.com/zmodelerlover/OpenNR-ReShade external\opennr
#   cd external\opennr ; .\build.ps1 -Target framecheck -Exe

powershell -ExecutionPolicy Bypass -File tools\amd\dlss5-amd-video.ps1 `
    -Video "D:\clip.mp4" -Out "D:\clip-dlss5.mp4" -Scale 0.75
```

It decodes to PPM, drives the runtime segment by segment (each segment is deleted
before the next, so peak disk is one segment regardless of the film's length),
then encodes and copies the source audio through. A 140 s 4K film took about
50 minutes on this card.

## 8. Known limits

- **Export and cache are implemented but unverified.** The capture path now reads
  the frame the AMD add-on composited (`RecordAmdPresentedCopy` copies the presented
  backbuffer into a private texture that `AmdPresentedSRV` views), instead of the
  NGX output texture that only exists on NVIDIA. It builds and the portable suites
  pass, but the machine this was written on could not run it — see the next point —
  so no AMD export has actually produced a file yet. `tools/amd/dlss5-amd-video.ps1`
  is the verified way to get a file until someone confirms it on working hardware.
- **Intermittent `amdhip64_7.dll +0x465007` crash on engine init.** Seen after
  several hundred sessions; a cold reboot clears it and `hipInfo` stays healthy
  throughout, so it reads as GPU-side state rather than this code. The same binary
  in the same directory produced 20 good frames minutes before it started failing
  100 % of the time.
- No RTX VSR, no DLSS Super Resolution, no frame generation on AMD.
- Upstream's CTest suites: 19 of 20 pass. The one failure,
  `NeuralPrerenderTests` ("Cache root probe fallback"), reproduces on an unmodified
  upstream checkout on this machine, so it is environmental and not caused by the
  AMD backend.
- Only `gfx1101` has been exercised. `OtherAmd` is classified so the backend is
  reachable, but nothing claims RDNA2 or RDNA4 behave.

## 9. Licensing

This fork's own changes are MIT, like upstream. The runtime files are not
redistributed and are not covered by this repository's licence: they are
NVIDIA-derived community work with their own terms, obtained by the user from
their publishers. See `THIRD_PARTY.md` and the runtime lock's `provenance` fields.
