# HIP 显存分配：新证据（PyTorch 可用，独立进程崩溃）

日期：2026-11-11 20:0x
起因：用户提供了 `hipconfig` / `hipinfo` 的完整输出，并指出「打游戏时 GPU 正常」。

## 这一轮的转折

用户贴出的 `hipconfig` 暴露了此前没注意的事实：**机器上存在三套 HIP 运行时**。

```
C:\Windows\System32\amdhip64_7.dll                                    10.0.3679.0   (驱动自带)
C:\Program Files\AMD\ROCm\7.2\bin\amdhip64_7.dll                      10.0.3679.0   (ROCm 7.2)
D:\anaconda3\Lib\site-packages\_rocm_sdk_core\bin\amdhip64_7.dll      10.0.3581.0   (pip 装的)
```

而 `hipconfig` 报的 `HIP_PATH` 指向 `C:\Program Files\AMD\ROCm\7.2\`，
其 `HIP_RUNTIME` 是 `rocclr`。

## 最重要的新证据：PyTorch 的 HIP 完全可用

`torch 2.9.1+rocm7.10.0`，在同一台机器上：

```python
>>> import torch
>>> torch.cuda.is_available()
True
>>> torch.cuda.get_device_name(0)
'AMD Radeon RX 7800 XT'
>>> x = torch.zeros(1024, 1024, device='cuda')
>>> float((x + 1).sum())
1048576.0
```

分配与计算都成功。`torch.version.hip = 7.2.0-f17625ad56`。

**更关键的是**：在同一个已经初始化好的 PyTorch 进程里，直接 `ctypes` 调
`amdhip64_7.dll` 的导出函数：

```
hipGetDeviceCount rc=0 n=1
hipMalloc rc=0 ptr=c_void_p(12884918272)      <- 成功
```

## 而独立进程里 `hipMalloc` 必定崩溃

我写的三个最小程序（不含任何 DLSS / ReShade / OpenNR 代码）：

| 程序 | 做了什么 | 结果 |
|---|---|---|
| `m2.exe` | `hipGetDeviceCount` → `hipMemGetInfo` → `hipMalloc(64)` | 枚举 OK，`memInfo free=0 total=0`，malloc 崩 |
| `m3.exe` | 同上 + 枚举已加载模块 | `deviceCount=1`，之后加载 `amd_comgr_3.dll`，malloc 崩 |
| `init.exe` | 显式 `hipInit(0)` → count → malloc | `hipInit rc=0`，`count=1`，malloc 崩 |
| `ld.exe` | `LoadLibrary` + `GetProcAddress` 手工调用 | count OK，malloc 崩 |

四种写法、四种 DLL 来源（System32 / ROCm 7.2 / anaconda SDK / 混合）全部崩在
同一个调用上。

## 已排除的可能（本轮新增）

| 假设 | 实验 | 结果 |
|---|---|---|
| ROCm SDK 与驱动冲突 | 移除 PATH 中的 ROCm，用 System32 驱动自带 HIP | 崩 |
| anaconda SDK 版本更旧导致 | 只用 anaconda 那份 hip + 它配套的 `amd_comgr0702.dll` | 崩 |
| 缺 OpenCL 后端（rocclr 需要） | 把 DriverStore 的 `amdocl64.dll` + `AMD_OpenCL64.dll` 放到程序旁 | 崩（且 amdocl64 未被加载） |
| 缺 COMGR 配套 | 放 `amd_comgr_3.dll` / `amd_comgr0702.dll` 对应版本 | 崩 |
| 未初始化 | 显式调 `hipInit(0)` | 崩 |
| 环境变量干扰 | 清空 `HIP_VISIBLE_DEVICES` / `ROCR_VISIBLE_DEVICES` | 崩 |
| AMD 降噪残留进程 | 结束两个 `AMDNoiseSuppression` | 崩 |
| 显存不足 | `hipInfo` 报 99% 空闲；整机占用 1.7 GB / 16 GB | 未满 |

## 目前的准确结论

- **D3D12 图形路径：正常**（用户打游戏实测，驱动 `32.0.31021.6002`）
- **HIP 硬件与设备枚举：正常**（`hipInfo` 全字段正常，`gfx1101`，15.98 GB）
- **PyTorch 进程内的 HIP 分配：正常**
- **独立进程的 `hipMalloc`：必崩 `0xC0000005`**
- **AMD 自家 ANR（ONNX）：崩**（10 份 dump，重启后 2 份）

也就是说：**同一个 GPU 上，HIP 的「设备层」好，但「独立进程从零初始化并分配」
这条路走不通，而 PyTorch 那条路走得通。**

## 这解释了所有现象

| 场景 | 走哪条路 | 结果 |
|---|---|---|
| 游戏 | D3D12 | 正常 |
| PyTorch | 它自带的 HIP 运行时（`torch_hip.dll` + SDK） | 正常 |
| DLSS5 / OpenNR framecheck | 独立进程直接调 `amdhip64_7.dll` | 崩 |
| AMD 自家 AI 降噪 | ONNX Runtime | 崩 |

后两者都是「独立进程，从零建立一个 GPU 计算上下文」。这条路在本机是坏的。

## 建议的下一步

**重装 AMD 驱动**仍然是第一选择，理由更新为：

- 设备层正常（`hipInfo` 全字段、枚举、属性都对）
- 但只要从零建上下文分配显存就崩
- 这是「驱动的用户态计算组件（HIP/COMGR）与其内核态部分不匹配」的形状
- 同一驱动下 D3D12 正常，说明内核态本身没问题

重装后按此顺序验证（一分钟内出结果）：

```powershell
# 1. 最小验证
cd F:\dlss5\TEMP\audit\hiptest
.\init.exe
#   期望：hipInit rc=0 / count=1 / malloc rc=0

# 2. HIP 官方工具
hipinfo

# 3. 若 1 通过，再跑 DLSS
cd F:\dlss5\TEMP\audit\clean
.\amd-nr-framecheck.exe --seq .\frames frames=4
```

若重装同一版本仍崩，**换一个 WHQL 版本**（不要用 PRO Edition，当前装的是
`AMD Software: PRO Edition 26.10.21.06`）；两个版本都在 `hipMalloc` 崩，
才需要考虑硬件。

## 用户可自行确认的一条

如果 PyTorch 能用而 DLSS 不能用，也可以**先用 PyTorch 的 HIP 跑一次实际的
DLSS 推理**作为旁证——但那需要把模型搬到 PyTorch，不在本次范围内。
