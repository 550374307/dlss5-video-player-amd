# 在 AMD 显卡上运行这个播放器（DLSS-NR 走 AMD 后端）

这是对上游项目的**增补**，不是替代。它的作用是让 `DLSSVideoPlayer` 能在 Radeon 上
使用 DLSS 5 神经渲染器 —— 而这在 N 卡上依赖的 NGX feature 18，Radeon 根本无法创建。

上游关于 NVIDIA 的所有说明仍然成立。这里**没有放松任何一道 fail-closed 闸门**：
AMD 路径有自己的运行时哈希锁、自己的预检、自己的逐帧证据，每一个都像 N 卡那份一样
严格拒绝不可信的情况。

> English: [README.amd.md](README.amd.md)

---

## 一、为什么原版跑不了

上游在 `src/RuntimePolicy.cpp` 用一行代码决定能不能开神经渲染：

```cpp
if (vendorId != kNvidiaVendorId) return GpuGeneration::Unsupported;
```

Radeon 的厂商 ID 是 `0x1002`，于是落到 `Unsupported`，`NeuralAddonDesired()` 返回
false，整条神经路径被关掉。**这不是配置问题，是硬编码的门。**

### 这道门为什么存在

上游的神经 pass 不是"调用一个推理库"。`DLSSBackend` 故意调用 raw NGX 符号，让同进程
里的 RenoDX 插件截到一次 `CreateFeature`/`EvaluateFeature`，然后在那个调用**内部**跑网络。
Radeon 上没有 NGX，这个触发器根本不存在。

### 这份分支改成了什么

AMD 后端保留了原子布局描述的那四个角色，用的是 AMD 插件的文件名：

| 角色 | NVIDIA 那套 | AMD 这套 |
|---|---|---|
| 代理 | `dxgi.dll` | `dxgi.dll`（ReShade，两家共用） |
| 插件 | `renodx-dlss5.addon64` | `amd-nr.addon64`（OpenNR） |
| 神经运行时 | `nvngx_dlssnr.dll` | `dlssnr_amd_pass1.dll`（danielblnc） |
| 权重 | 在 NR DLL 里 | `dlssnr_on_amd_weights.bin` |

插件同样挂在 `Present` 上，所以 helper 仍然每帧提交 —— 同一套机制，不同的运行时。

## 二、AMD 的证据链

上游从 `ReShade.log` 判断渲染成败：`feature 18 created`、`(native 1:1)`、
`inline feature 18 evaluation succeeded`、`EnableHooks=2: NGX hooks only`。
这些在 Radeon 上都不存在。AMD 后端改问 `amd-nr.log` 同样的问题：

| 要证明的事 | NVIDIA 证据 | AMD 证据 |
|---|---|---|
| 运行时起来了 | `feature 18 created` | `runtime: danielblnc` + `engine ready.` |
| 在原生尺寸跑 | `(native 1:1)` | `raster: … (scale 1.00)` |
| 真的评估了帧 | `inline feature 18 evaluation succeeded` | `frame N processed` |
| 走的是自己的路径 | `EnableHooks=2: NGX hooks only` | `HIP: adapter … matches the game's D3D12 device` |
| 没有中途失败 | NGX 的失败词表 | `engine init failed.`、`reported a native failure`、`weight files are missing`、`could not build the weights`、`engine latched async` |

**有两句刻意不算失败**，因为健康运行也会出现：
`off: the game destroyed its D3D12 device`（正常收尾，在最后一帧之后打印）
和 `pass 1 refused (n total)`（插件会重试的逐帧拒绝，好的渲染也会有几句，但仍然处理完每一帧）。

## 三、构建

上游指南适用，但这台机器上有个额外的坑：CMake 找不到 Visual Studio 实例，因为
`VC\Auxiliary\Build\` 下只有 `Microsoft.VCToolsVersion.v143.default.txt`，
而 CMake 读的是 `Microsoft.VCToolsVersion.default.txt`。那个目录需要管理员权限。

**没有管理员权限时**，先加载 MSVC 环境再用 Ninja：

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=amd64
cd /d <仓库>
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build build --parallel
```

编译器**仍然是 MSVC**，只是换了生成器，所以 `CMakeLists.txt` 里"必须是 MSVC"的检查
依然满足。

## 四、铺设运行时

```powershell
powershell -ExecutionPolicy Bypass -File tools\amd\fetch_amd_runtime.ps1 -Destination build
```

它从各家发布方下载，逐个对照 `packaging/runtime-lock-amd.json` 校验（大小 + SHA-256），
两个 ini 只在不存在时写入，**不会覆盖你自己的调参**。这里不重新分发任何文件。

验证：

```
dlss5-convert.exe probe <任意视频>       # 应显示 neural_runtime=verified
```

播放器日志应出现：

```
GPU=AMD Radeon RX 7800 XT driver=… generation=amd-rdna3 backend=amd-hip
```

## 五、RX 7800 XT（gfx1101）实测

纯网络耗时，1080p 源：

| Scale | ms/帧 | ≈ fps |
|---|---|---|
| 1.0 | 51.9 | 19 |
| 0.75 | 31.6 | 31.6 |
| 0.5 | 15.8 | 63 |

720p @1.0 是 23.7 ms。4K 约 200 ms 纯网络。

默认 `Scale=0.75`，因为它是这张卡上第一个能守住 30 fps 的档位。4K 请再降。

神经输出已确认是真渲染而非直通：合成帧 99.88% 像素改变、对源 PSNR 17.10 dB；
真实 4K 帧在 t=60s 处 92.06% 像素改变、32.17 dB。

## 六、直接处理视频（不经过播放器）

`tools/amd/dlss5-amd-video.ps1` 把视频跑过 DLSS-NR 并写出新文件：

```powershell
# 需要先构建一次 OpenNR 的 framecheck：
#   git clone https://github.com/zmodelerlover/OpenNR-ReShade external\opennr
#   cd external\opennr ; .\build.ps1 -Target framecheck -Exe

powershell -ExecutionPolicy Bypass -File tools\amd\dlss5-amd-video.ps1 `
    -Video "D:\片源.mp4" -Out "D:\片源-dlss5.mp4" -Scale 0.75
```

它解码成 PPM，**分段**送进运行时（每段处理完即删，所以磁盘峰值只取决于分段大小，
与片长无关），再编码并把源音频直接复制过去。这台卡上 140 秒 4K 片约 50 分钟。

分段是必要的：4K 帧的 PPM 是 25 MB、合成 RGBA 是 33 MB，整片一次性处理需要 243 GB。

## 七、已知限制

- **导出与缓存已实现，但未在硬件上验证。** 捕获路径现在读插件合成的那一帧
  （`RecordAmdPresentedCopy` 把呈现后的后缓冲拷进私有纹理，`AmdPresentedSRV` 供采样），
  不再读只存在于 N 卡的 NGX 输出纹理。它能编译、可移植单测也过，但写这份代码的机器
  跑不起来 —— 见下一条 —— 所以**还没有任何一次 AMD 导出真的产出过文件**。
  在有人于可用硬件上确认之前，`tools/amd/dlss5-amd-video.ps1` 是**已验证可用**的出片方式。
- **`amdhip64_7.dll +0x465007`：GPU 空闲时引擎初始化崩溃。**
  这条走了很长的弯路（先怪目录、后怪开机时长），最终定案的对照是**并发**：
  后台跑视频管线时，在同目录手动连续调用 3 次全部成功
  （27.999 / 22.608 / 22.964 ms/帧，exit 0）。脚本退出几秒后，同一条命令就崩，
  没有重启、没有改文件——只是 GPU 空闲了。

  这解释了其余现象：视频管线能完整跑通（连续 4、6、12 个分段，166–476 ms/帧），
  因为它全程占着 GPU；而单独一次探针总是从空闲状态初始化。
  引擎初始化会调进 `amdhip64_7.dll`，在 `+0x465007` 处崩，早于任何一帧运行
  （`last job -1`）。

  已排除：同目录的 NVIDIA `nvngx_dlssnr.dll`、`Scale` 0.75 vs 1.0、
  `InlineWaitMs` 100 vs 200、帧内容与尺寸、2.7 GB 残留 dump、VRAM 耗尽
  （用 4.1 GB / 16 GB）、人为 `ffmpeg` 解码负载、进程间延迟（0 秒和 15 秒都失败）。
  见 Issue #3。

  **实际影响**：`tools/amd/dlss5-amd-video.ps1` 是可靠的，因为它在整次运行中占着 GPU。
  任何从空闲桌面启动运行时的操作——包括播放器自己的导出——都可能撞上这个，
  所以导出如果立刻失败，先跑点吃 GPU 的东西再试。
- AMD 上没有 RTX VSR、没有 DLSS 超分、没有帧生成。convert probe 如实报告：
  `sr_engines=none`、`stages=nr`。
- 上游可移植单测 19/20 通过。唯一失败的 `NeuralPrerenderTests`（缓存根探测）在
  **未修改的纯上游**上同样失败，是环境问题，不是这份分支引入的。
  `PolicyTests` 新增了 5 个 AMD 专用用例，全部不依赖 GPU。
- 只在 `gfx1101` 上验证过。`OtherAmd` 分类存在是为了让后端可达，但不声称
  RDNA2 或 RDNA4 的行为。

## 八、许可

这份分支自己的改动是 MIT，与上游一致。运行时文件**不再分发**，也不在本仓库许可范围内：
它们是 NVIDIA 派生的社区成果，有各自的条款，由用户从各自的发布方取得。
见 `THIRD_PARTY.md` 和运行时锁里的 `provenance` 字段。
