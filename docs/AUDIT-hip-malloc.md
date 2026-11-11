# HIP 显存分配在本机崩溃（自建最小复现）

日期：2026-11-11 19:1x
起因：用户指出「可是我打游戏的时候 GPU 也正常啊」。这句话推翻了我上一轮
「GPU 计算栈整体坏了」的过宽结论，需要重新界定边界。

## 结论

**图形路径正常，HIP 的显存查询与分配坏了。** 两者用的是不同的运行时。

## 最小复现（不含任何 DLSS / ReShade / OpenNR 代码）

```cpp
#include <hip/hip_runtime.h>
#include <cstdio>
int main(){
    int n=0; hipGetDeviceCount(&n);
    printf("dev=%d\n", n); fflush(stdout);

    size_t f=0,t=0; hipMemGetInfo(&f,&t);
    printf("memInfo free=%zu total=%zu\n", f, t); fflush(stdout);

    void* d=nullptr;
    hipError_t e=hipMalloc(&d,64);
    printf("malloc64 -> %s\n", hipGetErrorString(e)); fflush(stdout);
    return 0;
}
```

构建（需要 MSVC 的 INCLUDE/LIB）：

```bat
set INCLUDE=<MSVC>\include;<WinSdk>\ucrt;<WinSdk>\shared;<WinSdk>\um
set LIB=<MSVC>\lib\x64;<WinSdk>\Lib\...\ucrt\x64;<WinSdk>\Lib\...\um\x64
hipcc --offload-arch=gfx1101 -o m2.exe m2.cpp
```

运行结果：

```
dev=1                                    <- 设备枚举正常
memInfo free=0 total=0                   <- 显存信息全零（异常）
（随后进程以 0xC0000005 终止）             <- hipMalloc(64) 崩溃
```

## 界定到哪一步

| HIP 调用 | 结果 |
|---|---|
| `hipGetDeviceCount` | 正常，返回 1 |
| `hipGetDeviceProperties` | 正常，`AMD Radeon RX 7800 XT` / `gfx1101` |
| `hipMemGetInfo` | **返回 free=0 total=0**（异常） |
| `hipMalloc(64)` | **崩溃 `0xC0000005`** |
| 内核 launch（`addone.exe`） | 崩溃（更早就在 malloc 死） |

注意：`hipInfo.exe`（AMD 自带工具）能报 `15.98 GB / free 15.84 GB`，
但它走的是另一条查询路径。**应用侧调 `hipMemGetInfo` 拿到的是全零。**

## 这与「游戏正常」为什么不矛盾

| 用途 | 运行时 | 状态 |
|---|---|---|
| 游戏渲染 | D3D12 + 驱动的 D3D 显存分配器 | 正常（用户实测） |
| DLSS5 神经渲染 | HIP 的显存查询/分配 | **崩溃** |
| AMD 自家 AI 降噪 | ONNX Runtime（`ANRonnxLib.dll`） | **崩溃**（10 份 dump，重启后又有 2 份） |

游戏不经过 HIP。它用 D3D12 的 `CreateCommittedResource` / 驱动的 D3D 分配器，
那条路径是好的。DLSS-NR 和 AMD 自家的 ANR 都走额外的推理运行时，那两条都坏。

**「能打游戏」不能推出「HIP 能用」——它们是两套独立的显存管理。**

## 这修正了上一轮的说法

上一轮我写「本机 GPU 计算栈整体有问题」，把话说宽了。准确的说法是：

- **D3D12 图形 + 驱动 D3D 分配器：正常**
- **HIP 应用侧（`hipMemGetInfo` / `hipMalloc` 起）：异常并崩溃**
- **ONNX Runtime（AMD ANR 用的）：崩溃**

后两者的共同点是：都要从驱动申请 GPU 显存，都不是游戏必经之路。

## 已排除

| 假设 | 实验 | 结果 |
|---|---|---|
| ROCm SDK 与驱动冲突 | 移除 PATH 中的 ROCm，用 System32 驱动自带 HIP | 同样崩 |
| 环境变量干扰 | 清空 `HIP_VISIBLE_DEVICES` / `ROCR_VISIBLE_DEVICES` | 同样崩 |
| 加载了错误的 HIP 版本 | 检查导入表：DLSS 运行时与 framecheck 都只导 `amdhip64_7.dll` | 一致 |
| AMD 降噪残留进程占用 | 结束两个 `AMDNoiseSuppression` 进程后重测 | 同样崩 |
| 显存不足 | `hipInfo` 报 99% 空闲；崩前整机占用 1.7 GB / 16 GB | 未满 |
| RyzenMaster 干预 | 检查进程与服务 | 未运行 |

## 与 DLSS 崩溃的对应关系

DLSS-NR 崩溃时 `last job -1`（尚未跑过一帧），插件日志停在
`input contract: ...` 之后 —— 那正是引擎开始为权重和内核申请显存的阶段。
与「`hipMemGetInfo` 返回全零、`hipMalloc` 就崩」完全对得上。

## 建议的下一步

1. **干净重装 AMD 驱动**（当前 32.0.31021.6002 / 2026-08-04）。
   依据：设备枚举与属性正常（说明驱动把设备暴露给了 HIP），但
   `hipMemGetInfo` 返回全零、`hipMalloc` 访问违例；同一驱动的 D3D12 路径正常。
   这是「驱动的 HIP 侧组件损坏」的典型形状，重装是最小成本的第一步。
2. 重装后立刻跑 `F:\dlss5\TEMP\audit\hiptest\m2.exe`：
   - 打印 `memInfo free=<非零>` 且 `malloc64 -> no error` → HIP 恢复
   - 仍崩 → 换一个 WHQL 驱动版本再试
3. 若两个不同驱动版本都在 `hipMalloc` 崩，才考虑硬件侧问题。

## 复现文件

```
F:\dlss5\TEMP\audit\hiptest\m2.cpp       <- 最小复现（枚举+memInfo+malloc64）
F:\dlss5\TEMP\audit\hiptest\m2.exe
F:\dlss5\TEMP\audit\hiptest\m1.cpp       <- 更早的版本
F:\dlss5\TEMP\audit\hiptest\alloc.cpp    <- 枚举+属性+分配
F:\dlss5\TEMP\audit\hiptest\addone.exe   <- 完整内核（也崩）
```
