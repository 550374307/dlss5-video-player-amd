# 交叉审计：DLSS5 崩溃是否与播放器代码有关

日期：2026-11-11
起因：用户质疑「你确定和你的代码没关系吗？对照 GitHub 上能用的参考，交叉审计」。

结论先行：**同一次崩溃有六个相互独立的证据，全部指向 `amdhip64_7.dll + 0x465007`，
且其中一条用未经本仓库任何修改的 OpenNR 原始二进制复现了它。**
但审计也发现了一件我之前没说清的事：这条路径和参考项目走的不是同一套后端，
参考项目的做法在 RX 7800 XT 上不适用。详见第四节。

---

## 一、崩溃转储（14 份，零例外）

用 `minidump` 解析 `neural-runtime\*.dmp`：

```
14 dumps
  EXCEPTION_ACCESS_VIOLATION   amdhip64_7.dll   offset=+0x465007   count=14
```

14 份 dump 全部是同一个异常码、同一个模块、同一个偏移。没有一份落在
`NeuralWorker.exe`、`dlssnr_amd_pass1.dll`、`amd-nr.addon64` 或 `dxgi.dll` 里。

崩溃时已加载的模块（取自最新 dump）：

```
NeuralWorker.exe            F:\dlss5\src-upstream\build\neural-runtime\
dxgi.dll                    F:\dlss5\src-upstream\build\neural-runtime\   (ReShade)
dxgi.dll                    C:\Windows\System32\                          (系统)
amd-nr.addon64              F:\dlss5\src-upstream\build\neural-runtime\
amdhip64_7.dll              C:\Windows\System32\                          (驱动自带)
dlssnr_amd_pass1.dll        F:\dlss5\src-upstream\build\neural-runtime\
```

调用栈的**最内层帧**在 `amdhip64_7.dll`，不在我们的二进制里。

## 二、未经本仓库修改的原始二进制同样崩溃

这是最直接的一条。从 `F:\dlss5\opennr\build`（OpenNR 上游构建产物，本项目从未改动）
取 `amd-nr-framecheck.exe`，放进全新空目录，只放运行时文件：

```
F:\dlss5\TEMP\audit\clean\
  amd-nr-framecheck.exe        4E19B13BCA8A7BFA   (与 opennr\build 同一文件)
  dlssnr_amd_pass1.dll
  dlssnr_on_amd_weights.bin
  dlssnr_on_amd.ini
  amd-nr.ini
  frames\frame0000..0003.ppm
```

结果：`exit = -1073741819`（`0xC0000005`）。

这个目录里**没有** `NeuralWorker.exe`、没有 `dxgi.dll`、没有 `ReShade.ini`、
没有 `amd-nr.addon64` —— 本仓库在这个进程里一行代码都没有。

## 三、运行时文件未被篡改

对照 `packaging/runtime-lock-amd.json` 逐个核 SHA-256 与大小：

```
dxgi.dll                     MATCH     size=5592064
amd-nr.addon64               MATCH     size=887296
dlssnr_amd_pass1.dll         MATCH     size=56677888
dlssnr_on_amd_weights.bin    MATCH     size=147689451
```

四个文件与锁中的值逐位一致，说明「我的代码写坏了运行时文件」这一可能性不成立。

## 四、对照参考项目：它走的不是同一条路

参考 `lmxxf/dlss5-on-amd-9070xt-porting`（本地 `F:\dlss5\lmxxf`）的 README：

- `gfx1101` 出现 **0** 次
- `gfx1200` / `gfx1201` 出现 **8** 次
- 环境要求原文：「**RDNA 4 显卡**（RX 9070 XT 实测；RX 9060 的内核随包但没机器测）和带
  `amdhip64_7.dll` 的 AMD 驱动」

也就是说：**参考项目只做 RDNA 4（gfx1200/1201），RX 7800 XT 是 RDNA 3（gfx1101），
不在它的支持范围内。** 它绕开问题的办法是把自己的 40 个 HIP 内核预编译成
gfx1200/1201 专用模块，这条路在 gfx1101 上需要另编一套内核，不是配置能切换的。

所以「参考项目能用」不能推出「这张卡也应该能用」，两者的后端实现不同。

另有一处值得记录：lmxxf 明确说**不需要 HIP SDK**，用驱动自带的 HIP 7。本机
`C:\Windows\System32\amdhip64_7.dll` 与 `C:\Program Files\AMD\ROCm\7.2\bin\amdhip64_7.dll`
**不是同一个文件**（SHA-256 不同），但版本号都是 `10.0.3679.0`。崩溃时加载的是
System32 那个，与参考项目一致，所以这不是差异点。

## 五、已排除的假设（每条都有实验）

| 假设 | 实验 | 结果 |
|---|---|---|
| 运行时文件被我的代码改坏 | 逐文件核 SHA-256 | 全部 MATCH |
| 目录残留状态 | 全新空目录 | 同样崩 |
| 引用了 NVIDIA 的 `nvngx_dlssnr.dll` | 移走该文件 | 同样崩 |
| `Scale` 设置 | 用成功的 `0.75` | 同样崩 |
| `InlineWaitMs` 100 vs 200 | 对齐到成功值 | 同样崩 |
| 帧内容/尺寸 | 4K 视频帧、720p 测试图案 | 都崩 |
| 残留 dump 文件（2.7 GB） | 干净 6 文件目录 | 同样崩 |
| 显存耗尽 | 崩前 VRAM 4.1 GB / 16 GB | 未满 |
| GPU 空闲降频 | ffmpeg 持续解码 4K（445 s CPU） | 同样崩 |
| 进程间延迟 | 0 秒与 15 秒间隔 | 同样崩 |
| 驱动挂起 | `pnputil /restart-device` 重置 GPU | 同样崩 |
| TDR | 系统事件日志 | 无 TDR 记录 |

## 六、尚未验证的

**冷重启。** 这是唯一没做过的一步。系统自 11/09 18:24 开机至今未重启。
`pnputil` 重置设备不足以恢复，说明状态比单纯的设备挂起更深。

为什么它值得一试：**同一天早些时候，同一台机器、同一批文件、同样的
`amd-nr-framecheck.exe` 成功跑完了 4199 帧的 4K 导出**（见 `output/final-4k.mkv`，
324 MB，70.04% 像素改变，PSNR 27.91 dB）。之后它开始 100% 失败。中间没有换过任何
运行时文件、没有改过驱动、没有改过本仓库与运行时交互的代码。

## 七、本仓库代码可能仍有问题的地方（诚实清单）

审计没能排除的是「我的代码用某种罕见方式诱导了崩溃」，理由如下：

1. **播放器路径比 framecheck 路径多加载两个模块**：`dxgi.dll`(ReShade) 与
   `amd-nr.addon64`。第二节证明 framecheck 不加载这两个也能崩，所以**不是它们引起的**，
   但这也意味着第二节的实验没有覆盖「ReShade 在场时」这一情形。
2. `RunNeuralPreflight` 的重试（4 次 / 400 ms）是我今天加的。它在这个状态下
   4 次全失败，**没有让情况变坏**（时间从 1.598 s 变成 5.4 s），但也没修好它。
3. 我今天改过的 `OfflineNeuralRenderer.cpp` 计时逻辑与本次崩溃**无关**
   （崩溃发生在 preflight 阶段，早于任何渲染）。

## 八、给上游的复现材料

- 崩溃模块：`C:\Windows\System32\amdhip64_7.dll`，版本 `10.0.3679.0`
- 偏移：`+0x465007`
- 异常：`EXCEPTION_ACCESS_VIOLATION (0xC0000005)`
- 崩溃前插件日志最后三行：

```
HIP: device 0 code 0 "AMD Radeon RX 7800 XT" LUID 00000000:00016D42
HIP: adapter AMD Radeon RX 7800 XT matches the game's D3D12 device.
input contract: encoding 0, tonemap requested -1 -> runtime 0; FP16 is transport, not a colour-space declaration.
```

即：设备已解析、适配器已匹配，崩在引擎建权重与内核的阶段。
