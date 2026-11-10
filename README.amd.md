# Running this player on an AMD Radeon (DLSS-NR through the AMD backend)

> 中文版：[README.amd.zh-CN.md](README.amd.zh-CN.md)

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
| `src/NeuralWorkerMain.cpp` | unlocked-module check and runtime stamps pick the lock by backend; the NVIDIA add-on contract in `DisabledAddons` is skipped on AMD |
| `src/StageExport.cpp` | export-time runtime refusal picks the lock by backend |
| `src/StartScreenPolicy.h` | the start screen reports the AMD backend and says the driver floor does not apply, instead of "not an RTX GPU, so no DLSS" and "needs 610.47 or newer" |
| `src/D3D12Renderer.h/.cpp` | `SetAmdNeuralBackend()`; `DLSSFeatureCreated()` answers for it; `RecordAmdPresentedCopy` and `AmdPresentedSRV` are the capture's view of the presented frame |
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

- **Export and cache work, verified on hardware.** `dlss5-convert --stages nr` over a
  120-frame 720p clip exits 0 and writes the file with its audio, and the exported
  frame carries red as red, green as green, blue as blue.

  The capture reads the frame the add-on composited: `RecordAmdPresentedCopy` copies
  the presented backbuffer into a private texture that `AmdPresentedSRV` views, in
  place of the NGX output texture that only exists on NVIDIA.

  Getting there took five fixes that only became visible one after another — the
  evaluation-count equality (the add-on *samples* its log, so 117 of 120 was a
  counting artefact, not a passthrough), the neural-timing floor (NGX timestamp
  queries do not exist on AMD, so a 0.0 read became a zero sample), the runtime
  choice (no AMD entry meant the export demanded `nvngx_dlssnr.dll`), the log's own
  naming (the runtime loads as `version.dll`, so the path check could never pass —
  the lock that hashes `dlssnr_amd_pass1.dll` before launch still runs), and the
  colour (the copy was `B8G8R8A8` against an `R8G8B8A8` backbuffer, which
  `CopyResource` accepted and reinterpreted: red `252,0,0` came back as `40,42,255`,
  4.5 dB; matching the format and viewing it as `_SRGB` gave 14.4 dB).

  The frame still differs from the source across 100% of pixels — that is the
  network's edit, not a passthrough. Solid patches after export: red `253,0,0` →
  `253,18,65`, green `0,254,0` → `62,200,59`, blue `0,0,254` → `0,12,253`; channels
  in order, the shifts are the tone adjustment.
- **`amdhip64_7.dll +0x465007` faults on engine init when the GPU is idle.**
  This one had a long false trail — a stale directory, then uptime — and the control
  that settles it is concurrency: with the video pipeline running in the background,
  three consecutive manual invocations in the same directory all succeeded
  (27.999 / 22.608 / 22.964 ms per frame, exit 0). Seconds after that script exits, the
  identical command fails with no reboot and no file change — only the GPU going idle.

  That explains the rest: the video pipeline works end to end (4, 6 and 12 consecutive
  segments at 166–476 ms/frame) because it keeps the GPU busy, while a lone probe
  always initialises from idle. Engine init calls into `amdhip64_7.dll` and faults at
  `+0x465007` before any frame runs (`last job -1`).

  Ruled out by experiment: the NVIDIA `nvngx_dlssnr.dll` beside the runtime, `Scale`
  0.75 vs 1.0, `InlineWaitMs` 100 vs 200, frame content and size, 2.7 GB of residual
  dumps, VRAM (4.1 GB of 16 GB in use), an artificial `ffmpeg` decode load, and
  inter-process delay (0 s and 15 s both fail). Tracked in issue #3.

  **Practical consequence:** `tools/amd/dlss5-amd-video.ps1` is reliable because it
  holds the GPU for the length of a run. Anything that starts the runtime from an idle
  desktop — including the player's own export — can hit this, so if an export fails
  immediately, run something GPU-heavy alongside it and try again.
- No RTX VSR, no DLSS Super Resolution, no frame generation on AMD. The convert
  probe says so: `sr_engines=none`, `stages=nr,fg`. Earlier builds of this branch
  advertised `sr_engines=dlss` on a Radeon, which would have offered a stage whose
  engine cannot start.
- Upstream's CTest suites: 19 of 20 pass. The one failure,
  `NeuralPrerenderTests` ("Cache root probe fallback"), reproduces on an unmodified
  upstream checkout on this machine, so it is environmental and not caused by the
  AMD backend. Four AMD-specific cases were added to `PolicyTests` and all five of
  the start-screen and capture gates they cover run without a GPU.
- Only `gfx1101` has been exercised. `OtherAmd` is classified so the backend is
  reachable, but nothing claims RDNA2 or RDNA4 behave.

## 9. Licensing

This fork's own changes are MIT, like upstream. The runtime files are not
redistributed and are not covered by this repository's licence: they are
NVIDIA-derived community work with their own terms, obtained by the user from
their publishers. See `THIRD_PARTY.md` and the runtime lock's `provenance` fields.
