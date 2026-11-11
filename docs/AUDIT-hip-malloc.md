# HIP 崩溃：真正的失败点（ISA 编译），以及管理员权限为什么能绕过

日期：2026-11-11 20:2x
触发：用户实测「管理员运行时 `m2.exe` 通过：`malloc64 -> no error`」。

## 决定性日志

用 `AMD_LOG_LEVEL=3` 跑 `m2.exe`（非提权），HIP 内部日志给出完整失败链：

```
:3:hip_memory.cpp :971 :  hipMemGetInfo ( ... )
:4:palmemory.cpp  :212 :  Alloc: 400000 bytes, ptr[2004c0000-2008c0000]     <- 显存分配成功
:4:palmemory.cpp  :212 :  Alloc: 408000 bytes, ptr[200a00000-200e08000]     <- 成功
:1:devprogram.cpp :1391:  Error: Creating the executable from ISA assembly text failed.
:1:devprogram.cpp :1391:  Error: Failed to compile source (from CL or HIP source to LLVM IR).
:1:paldevice.cpp  :2777:  Couldn't create blit kernels!
:1:palvirtual.cpp :1060:  Could not create BlitManager!
:1:paldevice.cpp  :1189:  Couldn't create the device transfer manager!
:3:hip_memory.cpp :984 :  hipMemGetInfo: Returned hipErrorInvalidValue
memInfo free=0 total=0
:3:hip_memory.cpp :818 :  hipMalloc ( ... )          <- 随后 0xC0000005
```

**失败点是「把 ISA 汇编文本编译成可执行码」这一步**，不是显存不足、不是设备枚举、
不是驱动挂起。`palmemory` 那几行证明显存本身是能分配的。

HIP 在初始化时要为「显存拷贝」编译一组内置 blit kernel；这些 kernel 以 ISA 汇编
文本形式内嵌，需要 COMGR 把它编译成机器码。**这一步在当前环境下失败。**

## 为什么管理员能通过

用户实测：管理员运行 → `malloc64 -> no error`。

而在同一个非提权会话里，我复现了崩溃：

```
dev=1
memInfo free=0 total=0
exit=-1073741819
```

即：**同一个二进制、同一台机器、同一批 DLL，唯一的变量是进程权限。**
所以这是权限相关的编译失败，而不是代码或硬件。

## 但这不等于「非提权就一定不能用」

必须同时记录这条反例：**PyTorch 是非提权跑的，它却能用 HIP。**

```
PS> D:\anaconda3\python.exe -c "...torch.zeros(128,128,device='cuda')..."
torch non-elevated HIP OK: 16384.0
```

而且早先的测试里，在 PyTorch 已初始化的进程内用 ctypes 直接调
`amdhip64_7.dll`，`hipMalloc rc=0` 返回真实指针。

所以准确的表述是：

| 环境 | HIP 可用 |
|---|---|
| 提权进程，直接调 `amdhip64_7.dll` | **可用**（用户实测） |
| 非提权进程，直接调 `amdhip64_7.dll` | 崩（ISA 编译失败） |
| 非提权进程，**PyTorch 自带的 HIP 栈** | **可用** |

## PyTorch 与非提权崩溃的差异（已排查，未完全定位）

| 项 | PyTorch | 直调系统 HIP | 结果 |
|---|---|---|---|
| HIP DLL | `_rocm_sdk_core\amdhip64_7.dll` (10.0.3581.0) | System32 (10.0.3679.0) | 两者单独跑都崩 |
| COMGR | `amd_comgr0702.dll` (105 MB) | `amd_comgr_3.dll` (108.6 MB) | 把 0702 放到系统 HIP 旁 → **仍加载 `_3`，仍崩** |
| 配套 | 自带 amdocl64 / hiprtc / hipblas 等整套 | 只有 System32 的几个 | — |

已试过把 `amd_comgr0702.dll` 放在 `amdhip64_7.dll` 旁边希望优先加载，
但系统 HIP 硬编码加载 `amd_comgr_3.dll`，未生效。

**这说明 PyTorch 能用的原因不在「哪一份 COMGR」，而在它自己的初始化流程**
（它先用自带的 OpenCL/rocclr 路径建好设备与队列，再暴露 HIP 接口）。

## 对播放器的直接影响

`DLSSVideoPlayer.exe` 的 manifest 是 `asInvoker`（不请求提权），
`NeuralWorker.exe` 由它启动、继承同一完整性级别。因此在当前环境下：

1. 用户双击播放器（非提权）→ 神经渲染在 preflight 阶段崩溃 → 退回原片
2. 用户右键「以管理员身份运行」→ 具备走通的条件

这与所有已观察到的现象一致。

## 立即可用的两种做法

### 做法 A：管理员身份运行播放器（零改动，已验证方向）

```powershell
# 右键 DLSSVideoPlayer.exe → 以管理员身份运行
# 或在 PowerShell（管理员）中：
& 'F:\dlss5\src-upstream\build\DLSSVideoPlayer.exe'
```

验证神经渲染是否启动：

```powershell
Get-Content 'F:\dlss5\src-upstream\build\neural-runtime\NeuralWorker.log' -Tail 5
# 应有新的会话；DLSSVideoPlayer.log 里 "Neural cold start" 的
# preflight / launch / runtimeReady 不再全是 "-"
```

### 做法 B：让播放器在需要时请求提权

如果 A 验证成立，再考虑改 `DLSSVideoPlayer.manifest` 为
`requireAdministrator`，或让 `NeuralWorker` 单独以提权方式启动。
后者改动更大（跨完整性级别启动子进程需要 UAC 或服务），需要单独设计。

**在 A 验证通过之前不动代码** —— 否则可能为一个尚未确认的原因改坏架构。

## 需要用户确认的一条

请以管理员身份开一次播放器，打开那个视频，按 `增强 → DLSS 5 神经渲染`，
然后把 `DLSSVideoPlayer.log` 里 `Neural cold start` 那一行发我。

- 若 `preflight=` / `runtimeReady=` 有数值 → 结论成立，我按做法 B 改
- 若仍为 `-` → 说明播放器路径还有别的阻塞点，我继续查
