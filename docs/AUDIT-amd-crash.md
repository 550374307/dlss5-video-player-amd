# 交叉审计：DLSS5 崩溃是否与播放器代码有关

日期：2026-11-11（18:29 冷重启后更新）
起因：用户质疑「你确定和你的代码没关系吗？对照 GitHub 上能用的参考，交叉审计」。

## 结论

**不是本仓库的代码。** 冷重启也没能恢复。而现在有一条比之前所有证据都更有力的
旁证：**AMD 自家的 AI 降噪程序在同一台机器、同一次重启之后，同样崩在 GPU 计算初始化处。**

---

## 一、崩溃转储（14 份，零例外）

用 `minidump` 解析 `neural-runtime\*.dmp`：

```
14 dumps
  EXCEPTION_ACCESS_VIOLATION   amdhip64_7.dll   offset=+0x465007   count=14
```

14 份全部同一个异常码、同一个模块、同一个偏移。没有一份落在
`NeuralWorker.exe`、`dlssnr_amd_pass1.dll`、`amd-nr.addon64` 或 `dxgi.dll` 里。

崩溃时已加载的模块（取自最新 dump）：

```
NeuralWorker.exe            F:\dlss5\src-upstream\build\neural-runtime\
dxgi.dll                    F:\dlss5\src-upstream\build\neural-runtime\   (ReShade)
dxgi.dll                    C:\Windows\System32\                          (系统)
amd-nr.addon64              F:\dlss5\src-upstream\build\neural-runtime\
amdhip64_7.dll              C:\Windows\System32\                          (驱动自带)
dlssnr_amd_pass1.dll        F:\dlss5\src-upstream\build\neural-runtime\
amd_comgr_3.dll             C:\Windows\System32\
```

## 二、未经本仓库修改的原始二进制同样崩溃

从 `F:\dlss5\opennr\build`（OpenNR 上游构建产物，本项目从未改动）取
`amd-nr-framecheck.exe`（`4E19B13BCA8A7BFA`），放进全新空目录，只放运行时文件：

结果：`exit = -1073741819`（`0xC0000005`）。

该目录里**没有** `NeuralWorker.exe`、没有 `dxgi.dll`、没有 `ReShade.ini`、
没有 `amd-nr.addon64` —— 本仓库在这个进程里一行代码都没有。

## 三、运行时文件未被篡改

对照 `packaging/runtime-lock-amd.json` 逐个核 SHA-256 与大小：

```
dxgi.dll                     MATCH     size=5592064
amd-nr.addon64               MATCH     size=887296
dlssnr_amd_pass1.dll         MATCH     size=56677888
dlssnr_on_amd_weights.bin    MATCH     size=147689451
```

## 四、昨晚 70/70 成功的那个目录，现在原封不动地崩溃

`TEMP\vidfull\rt` 在 2026-11-11 00:49 之前连续 **70 次会话全部成功**：

```
seq.csv: 59 帧，gpu_ms 平均 237.8（min 195.2 / max 340.5），全部 accepted=1
```

文件哈希与现在逐位一致（`dlssnr_amd_pass1.dll` = `430BE589…`，
权重 = `6BF8DC93…`，mtime 均为 2026/11/10 20:43:43）。

现在直接跑，崩。

## 五、最强旁证：AMD 自家的程序也在崩

`%LOCALAPPDATA%\CrashDumps` 里有 10 份 `AMDNoiseSuppression.exe` 崩溃转储，
其中**两份发生在本次重启之后**：

```
AMDNoiseSuppression.exe.15940.dmp   2026/11/11 18:30:18   (重启后 50 秒)
AMDNoiseSuppression.exe.14008.dmp   2026/11/11 18:35:08   (重启后 6 分钟)
```

解析其中一份：

```
EXCEPTION: EXCEPTION_ACCESS_VIOLATION
MODULE:    C:\Windows\System32\AMD\ANR\ANRonnxLib.dll
OFFSET:    +0x2122B
```

这是 AMD 自己的 AI 降噪组件，崩在 AMD 自己的 ONNX 推理库里。它与本仓库
没有任何关系，走的是不同的推理栈（ONNX 而非 HIP 内核），却在同一台机器上、
同一个时间窗内同样发生访问违例。

**两个来源不同、代码不同、推理后端不同的程序，都在 GPU 计算初始化处崩溃**
—— 这把故障归属从「本仓库代码」推到了「本机 GPU 计算栈」。

## 六、冷重启后的完整复测（18:29，重启后 3 分钟开始）

| 实验 | 目录 | 结果 |
|---|---|---|
| 全新空目录 + 最小文件 + 纯色帧 | `TEMP\audit\fresh` | 崩 |
| 4K 帧（23.73 MB） | `TEMP\audit\res` | 崩 |
| `Interop=0`（关 D3D12↔HIP 共享） | `TEMP\audit\nointerop` | 崩 |
| 换成 ROCm 的 `amd_comgr_3.dll` | `TEMP\audit\comgr` | 崩 |
| 完全照抄昨晚成功命令（含 `dump=composed`） | `TEMP\audit\dump` | 崩 |
| 昨晚 70/70 成功的目录，原封不动 | `TEMP\vidfull\rt` | 崩 |

## 七、排除清单（每条都有实验）

| 假设 | 实验 | 结果 |
|---|---|---|
| 运行时文件被代码改坏 | 逐文件核 SHA-256 | 全部 MATCH |
| 目录残留状态 | 全新空目录 | 同样崩 |
| 引用 NVIDIA 的 `nvngx_dlssnr.dll` | 移走该文件 | 同样崩 |
| `Scale` 设置 | 用成功的 `0.75` | 同样崩 |
| `InlineWaitMs` | 100 与 200 都试 | 同样崩 |
| 帧内容/尺寸 | 4K 帧、720p 帧、纯色帧 | 都崩 |
| 残留 dump（2.7 GB） | 干净 6 文件目录 | 同样崩 |
| 显存耗尽 | 崩前 VRAM 4.1/16 GB | 未满 |
| GPU 空闲降频 | ffmpeg 持续解码 4K（445 s CPU） | 同样崩 |
| 进程间延迟 | 0 秒与 15 秒 | 同样崩 |
| 驱动挂起 | `pnputil /restart-device` | 同样崩 |
| 冷重启 | 18:29 重启，3 分钟后测 | **同样崩** |
| `Interop` 互操作 | `Interop=0` | 同样崩 |
| COMGR 版本 | 换 ROCm 7.2 自带的 | 同样崩 |
| `dump=composed` 参数 | 完整照抄成功命令 | 同样崩 |
| TDR | 系统事件日志 | 无记录 |

## 八、仍然健康的部分（说明不是整卡报废）

- `hipInfo.exe` 正常：`gfx1101`、15.98 GB、`memInfo.free` 99%，exit=0
- 纯 HIP 设备枚举与显存查询正常
- 驱动 `32.0.31021.6002`（2026/8/4），`amdhip64_7.dll` 哈希 `EF34BB16…`
  与昨天记录完全一致，未被更新
- 所有 `C:\Windows\System32\amd*.dll` 的 mtime 都是 2026/8/5，未变动
- 无 TDR 事件
- 会话 1 是本地 console（非 RDP），不是远程会话导致

## 九、对照参考项目：它走的不是同一条路

参考 `lmxxf/dlss5-on-amd-9070xt-porting`（本地 `F:\dlss5\lmxxf`）的 README：

- `gfx1101` 出现 **0** 次
- `gfx1200` / `gfx1201` 出现 **8** 次
- 环境要求原文：「**RDNA 4 显卡**（RX 9070 XT 实测；RX 9060 的内核随包但没机器测）」

RX 7800 XT 是 RDNA 3（`gfx1101`），不在它的支持范围内。它绕开问题的办法是为
gfx1200/1201 手写编译 40 个 HIP 内核 —— 换架构要重编一套，不是配置能切换的。

所以「参考项目能用」不能推出「这张卡也应该能用」，两者后端实现不同。

## 十、本仓库代码可能仍有问题的地方（诚实清单）

1. **播放器路径比 framecheck 多加载 `dxgi.dll`(ReShade) 与 `amd-nr.addon64`。**
   第二节证明 framecheck 不加载这两个也能崩，所以不是它们引起的，但那个实验
   没有覆盖「ReShade 在场时」这一情形。
2. `RunNeuralPreflight` 的重试（4 次 / 400 ms）是本次会话加的。在这个状态下
   4 次全失败，**没有让情况变坏**（preflight 从 1.598 s 变成 5.4 s），也没修好它。
3. 改过的 `OfflineNeuralRenderer.cpp` 计时逻辑与本次崩溃**无关**
   —— 崩溃发生在 preflight 阶段，早于任何渲染。
4. 之前的「GPU 空闲导致崩溃」判断**已被推翻**：ffmpeg 持续占用 GPU 时同样崩。

## 十一、建议的下一步（按优先级）

1. **干净重装 AMD 驱动**（当前 8/4 的包，或换一个 WHQL 版本）。理由：HIP 能枚举
   设备但内核构建必崩，且 AMD 自家 ONNX 组件同时崩，指向驱动侧的 GPU 计算运行时。
2. 装完驱动后先跑 `TEMP\audit\clean` 那个最小目录验证。
3. 仍崩再考虑硬件送修/换卡。
4. 若要向上游报告，把下面第十二节的复现材料带给 OpenNR / danielblnc；但上游大概率
   会回答「本机其他 GPU 计算组件也在崩，先修驱动」。

## 十二、给上游的复现材料

- 崩溃模块：`C:\Windows\System32\amdhip64_7.dll`，版本 `10.0.3679.0`
- 偏移：`+0x465007`
- 异常：`EXCEPTION_ACCESS_VIOLATION (0xC0000005)`
- 运行时代码：`dlssnr_amd v0.6.0 (build a82ddc8a)`
- 崩溃前插件日志最后三行：

```
HIP: device 0 code 0 "AMD Radeon RX 7800 XT" LUID 00000000:000164F5
HIP: adapter AMD Radeon RX 7800 XT matches the game's D3D12 device.
input contract: encoding 0, tonemap requested -1 -> runtime 0; FP16 is transport, not a colour-space declaration.
```

- `dlssnr_on_amd.log` 的崩溃记录：

```
FAULT: exception 0xc0000005 at ... (C:\WINDOWS\SYSTEM32\amdhip64_7.dll + 0x465007) thread ..., last job -1
CRASH: exception 0xc0000005 ... in C:\WINDOWS\SYSTEM32\amdhip64_7.dll (thread ..., last job -1, mode async)
```

即：设备已解析、适配器已匹配，`last job -1`（尚未跑过任何一帧），
崩在引擎建权重与内核的阶段。
