# RTX 4090 D Tensor-Unlock Kit（Linux + Windows 双系统解锁套件）

**English**: Unlock halved FP32-accumulate tensor-core rates (FP16/BF16→FP32, FP8/e4m3,
TF32) on NVIDIA Ada (RTX 40) and Ampere (RTX 30) GPUs on **both Linux and Windows**,
with a self-healing GRUB boot entry that runs the pre-OS UEFI firmware transaction
before `bootmgfw.efi`. Volatile, no VBIOS/flash/driver patching.
Keywords: RTX 4090D unlock, 4090D 解锁, tensor core FP32 accumulate, FP8, Ada, AD102,
GSP-RM, PLM, nv-uefi-unlocker, gpu-unlock-ada, GRUB chainload, dual boot unlock.

[![License: GPL-2.0-only](https://img.shields.io/badge/license-GPL--2.0--only-blue)](LICENSE)
![platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-informational)
![tested](https://img.shields.io/badge/tested-RTX%204090D%20(10de%3A2685)%20%C3%974%20boots-green)

在双系统机器上，让 RTX 4090 D (AD102, `10de:2685`) 在进入 Windows 时同样获得与
Linux `gpu_unlock` 内核模块一致的张量算力解锁；启动项自动持久（内核升级、
GRUB 升级、ESP 载荷被清均能自愈），可一键完整卸载。本仓库 = 集成脚本 +
双平台统一单文件基准 + 可复现实测证据，是上游研究项目的**参考实现**。
Upstream research & implementation: [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)；
Windows pre-OS tool: [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker).

---

## 1. 原理：锁是什么，怎么解

NVIDIA 在 Ada 的消费级 GSP-RM 固件里用一组 feature 选择器（PLM/SS0/SS1 寄存器，
内核侧观测为 `fmla32` 等位）把**张量核算法中"FP32 累加"路径限制在半速**：

| 通路 | 锁住 | 解锁后 |
|---|---|---|
| FP16×FP16→**FP32** mma | 半速 | **2.00×** |
| BF16→**FP32** mma | 半速 | **2.2×** |
| TF32 mma | 半速 | 1.8× |
| **FP8 (e4m3)→FP32** mma | 半速 | **2.18×** |
| FP16→FP16 / INT8 / dp4a / 标量 FP32 (FFMA) | 不受锁影响 | 不变 |

解锁不是刷 VBIOS、不是改驱动、不是超频，而是一次**冷启动固件事务**
（与本仓库 Linux 模块 `unlock_610.c` 相同的交易族，同一份 AD102 载荷）：

```
UEFI DXE 时窗（任何 OS/驱动加载之前）
  SEC2 scrubber 停机 → FWSEC (FRTS) 拉起签名 Booter → 装载 GSP-RM 固件
  → 注入 V67 四写载荷 (WPR_CFG=0xfffff0ff, FBPA/WPR/FEAT_OVR_PLM=0xffffffff)
  → mailbox marker 0x67b00001 → 权限/SEC2-HALT 读回验证 → 一次 PCIe FLR
  → 校验读回 → 交链式加载器启动 Windows Boot Manager
```

关键性质：

- **易失**：写在 GPU 寄存器，断电即失；每次开机需重跑（由启动项自动完成）。
- **OS 无关**：事务发生在 boot services 阶段，与 Windows/Linux、与驱动版本
  完全解耦。实测 Windows（CUDA driver API 13.5，比 Linux 侧 615.71.09/13.4
  更新的分支）拿到与 Linux **逐位吻合**的满速（见 §5）。
- **安全失败**：载荷哈希、ROM/FWSEC 几何、控制台/DMA 图全部钉死后才允许写；
  任何一步验证不过 → 零写入直接链回 Windows。`tx-require-d0.txt` 保证
  休眠/热态恢复时不落一笔。已解锁再跑返回 EALREADY（跳过，不会二次 FLR
  打爆活动中的解锁状态）。

Windows 侧实现采用社区项目
[nv-uefi-unlocker v2.1.5](https://github.com/physicsdolphin/nv-uefi-unlocker)
（Rust, 264 KB `BOOTX64.EFI`，SHA-256
`9c615a3f5f16dfbe4800a5c46251cdb20f2886bbb4bec70fecab3400a3c2f7c9`），
其 `2600..28ff` 设备段覆盖 `10de:2685`，AD102 家族资产由本项目
`make-usbroot.sh --family ad102` 从钉定的公共输入离线再生，
**与本仓库 `firmware/ada-610.43.03.json` 钉定清单逐字节一致**：

| 资产 | SHA-256 前缀 | 与上游仓库清单 |
|---|---|---|
| `v67-ad102-four-plm.bin` | `44c36b2d…` | ✅ 一致（同一份四写载荷） |
| `booter_load_ad102.bin` | `6ee05b20…` | ✅ |
| `gsp_boot_ad102.bin` | `45d6335a…` | ✅ |
| `gsp_boot_desc_ad102.bin` | `83f8f3f1…` | ✅ |

## 2. 安装

```bash
# 1) 取工具与资产（需代理/网络；资产下载后脚本自动校验钉定哈希）
cd /tmp && curl -LO https://github.com/physicsdolphin/nv-uefi-unlocker/releases/download/v2.1.5/nv-uefi-unlocker-v2.1.5.zip
unzip -o nv-uefi-unlocker-v2.1.5.zip
./make-usbroot.sh --family ad102 --out /tmp/nvu/usbroot --work /tmp/nvu/inputs
# 2) 安装集成（母本 → /usr/local/share，载荷 → ESP 根，GRUB 钩子 → /etc/grub.d/26）
sudo ./linux/install_windows_unlock.sh /tmp/nvu/usbroot
sudo update-grub
```

`26_unlock_windows` 钩子在**每次 GRUB 重新生成时**（装内核、升 grub/驱动触发
postinst、手动 update-grub）自动执行：

1. 探测 Windows（已挂载 ESP 中存在 `bootmgfw.efi`，或固件启动项含该路径）——
   探测不到就不生成条目，双系统被移除后不留死项；
2. **自愈**：以 `/usr/local/share/nv-uefi-unlocker` 母本为准逐个比对哈希，
   缺失或被 Windows Update 清掉的载荷文件自动补回 ESP；
3. `search --fs-uuid` 动态写入当前 ESP UUID，重分区/重格式化后仍有效。

ESP 根目录载荷与语义（工具从自身所在卷根读取）：

| 文件 | 作用 |
|---|---|
| `BOOTX64.EFI` | 解锁工具本体 |
| `booter_load/gsp_boot(_desc)/fwimage/fwsignature/scrubber_*.bin` | 事务固件输入 |
| `v67-ad102-four-plm.bin` | **存在=解锁模式**；删除则变只读复演 |
| `tx-select-bdf.txt` | 钉卡 `0000:01:00.0`，多卡防误写 |
| `tx-require-d0.txt` | 非 D0（热/休眠恢复）时零写入中止 |
| `chain-target.txt` | 链回目标钉为 `\EFI\Microsoft\Boot\bootmgfw.efi` |
| `loader.log` | 每次运行的完整证据日志（Linux 下可直接读） |
| `i_know_what_i_am_doing.txt` | （可选）armed 模式：5s 倒计时自动执行 |

## 3. 使用

1. GRUB 选 **Windows 11 (GPU Unlock)**；
2. 工具屏显横幅，**30 秒内按 Space/Enter 执行事务**（超时/任意其他键 =
   零写入直接进 Windows）；armed 模式下 5 秒自动执行；
3. 事务开始后该卡输出黑屏属正常（按设计剥离控制台拥有者），日志继续写入
   `loader.log`，随后自动进入 Windows；
4. 回 Linux 后 `cat /boot/efi/loader.log`，关键行：
   `SELECTOR RESULT: transaction complete`、PLM 四写读回、`CHAIN: … bootmgfw`。

Windows 前置条件：**关闭"快速启动"**（混合关机导致非 D0，工具将按设计中止），
使用 610/615/616 分支驱动均可。若日常从已解锁的 Linux 热重启进入 Windows，
PLM 已开 → EALREADY 跳过，亦无害。

## 4. 验证工具（Linux 与 Windows 均含于本项目 `bench/`）

统一单文件基准 `bench/gpu_unlock_bench.c`（同一份 C 源码、同两个内嵌 cubin
编译出双平台二进制；**仅依赖系统 C 库**，运行时动态加载
`libcuda.so.1`/`nvcuda.dll`，缺驱动时给出带指引的中文式报错而非静默退出）：

| 文件 | SHA-256 前缀 | 说明 |
|---|---|---|
| `bench/gpu_unlock_bench_linux` | `0142c33d…` | 静态依赖仅 libc，双击/终端直接跑 |
| `bench/GpuUnlockBench.exe` | `3f43496d…` | PE32+ 静态，拷到 Windows 任意目录运行 |
| `bench/cubin_embed.h` + `embed_cubins.py` | — | 内嵌 cubin（`4fe8459d…`/`7f5aec64…`）及可复现生成器（自动哈希校验） |

- 两者输出相同格式 `unlock_bench_<时间戳>.txt`（含驱动 API 版本、cubin SHA、
  逐项 TF/s、270,336 单元全量校验、自动 UNLOCKED/STOCK/INDETERMINATE 判定）。
- Linux 侧另保留 `../unlock_probe.sh`（shell 版）：额外记录环境、模块参数、
  内核日志与 SM 频率/节流采样，适合建立正式基线。
- 错误路径已实测：cubin 损坏/驱动过旧 → `CUDA 200 device kernel image is
  invalid` + 版本提示；缺 `nvcuda.dll`/`libcuda.so.1` → 明确告知安装驱动。

## 5. 实测（本机：RTX 4090 D 48G 改，X670E，Linux `7.3.0-x64v3-xanmod1`
NVIDIA `615.71.09` / Windows CUDA API 13.5，2026-10-29，同 cubin、同 iters/reps）

| 指标 (TF/s) | Win 原版 | Win 解锁 | 倍率 | Linux 解锁(基线) | Win 解锁 vs Linux |
|---|---|---|---|---|---|
| fp8/e4m3 | 270.1 | **589.6** | **2.18×** | 589.4 | +0.03% |
| f16/f32 | 148.3 | **296.6** | **2.00×** | 295.2 | +0.5% |
| bf16/f32 | 133.7 | **296.3** | 2.22× | 295.1 | +0.4% |
| tf32 | 73.8 | 135.5 | 1.84× | 135.7 (runner) | ±1% |
| s8/s32（对照） | 535.6 | 590.0 | ~1.0× | 589.9 | 一致 |
| dp4a / ffma（对照） | 132.1 / 66.2 | 146.8 / 70.9 | ~1.0× | 146.6 / 70.7 | 一致 |
| runner f16_f32/tf32/u4 | 134.2/73.8/1173.2 | 273.9/135.5/1173.5 | — | 271.3/135.7/1179.7 | ±2% |
| 全单元校验 | 0 错误 | 0 错误 | — | 0 错误 | — |

与上游 4090 (2684) 报告的形状一致（FE：165.6→331.6 精确 2.00×）；
2.18× 的 fp8 与 README 记录的"FP8 半速→满速"结构吻合。

## 6. 什么场景真的更快（诚实版）

**受益（矩阵乘走 FP32-accumulate 或 FP8 的负载）**：

- **本地大模型推理（bf16/fp16 权重，prefill/首字）**：vLLM、TensorRT-LLM、
  llama.cpp CUDA 后端的 GEMM 在 FP32 累加下运行——prefill/批处理吞吐最高
  接近 2×；decode 受显存带宽限制，提升有限。
- **FP8 模型与 FP8 KV cache**（Ada 独有 e4m3）：vLLM/TensorRT-LLM 的 FP8
  GEMM 计算上限直接翻倍，长上下文预填充、批量服务受益明显。
- **训练/微调（LoRA、QLoRA、全参 bf16/fp16-mixed）**：PyTorch autocast
  bf16 的 matmul 即 FP32 累加路径；矩阵乘主导的迭代（如 7B LoRA 在
  48G 卡上）步时下降可感。
- **Diffusers/ComfyUI FP8·bf16 管线**（Flux、SD3.5-Max 等）：去噪步中
  GEMM 占比高的模型受益，U-Net 纯 fp16acc16 管线受益有限。
- **Whisper 训练/大语音批处理、Embedding 批量计算**等 GEMM-bound 服务。

**不受益（明确别指望）**：

- **INT8/INT4 量化推理**（dp4a/IMMA 路径未锁，也从未翻倍）——上游 README
  记录的量化 MoE 服务负载"无变化"正是此因；
- **游戏与 DLSS 渲染**：图形管线走 FP16→FP16 与光栅单元，不受影响；
- **纯 FP32 科学计算 (FFMA)、NVENC 视频编码、显存容量、PCIe/内存带宽瓶颈型
  负载、延迟敏感的访存操作**；
- 已上线的 Windows-only 游戏帧数不会因此提高。

简言之：**这是一次"面向 AI 数学库"的解锁**，凡 CUDA 调用 cuBLAS/CUTLASS
里 `16F*16F+32F` / `BF16+32F` / `E4M3` GEMM 的都受益；渲染与 INT8 不受益。

## 7. 风险与边界

- 事务不写 VBIOS/不刷固件/不打驱动补丁；解锁状态断电即失。
- 失败路径全部设计为"零写入 + 直接进 Windows"；最坏情况是屏幕停在工具横幅，
  重启走原启动项即可。
- `loader.log` 为证据记录；建议保留首次成功日志。
- 本集成基于社区工具 + 上游研究，属**实验性**；对生产力机器请在可停机窗口验证。
- 若更换显卡/刷 VBIOS，ROM/FWSEC 钉定资产需要重新生成（见上游 testing.md）。

## 8. 卸载

```bash
sudo ./linux/uninstall_windows_unlock.sh
```
按母本清单哈希精确删除 ESP 载荷（哈希不符的他方文件保留并报告）、移除 GRUB
钩子与 `/usr/local/share/nv-uefi-unlocker`，重新生成 `grub.cfg`；
现有正常 Windows/Linux 条目不受任何影响。探针产物
（`probe-results-*`、`unlock_probe.sh`、自己拷贝的 bench 二进制副本）按需自行删除。

## 9. 致谢 / Acknowledgments

- [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) —
  上游项目：解锁原理、Linux 内核模块、探针工具与 `firmware/` 钉定资产清单（本套件
  的 v67 四写载荷与其逐字节一致）；`docs/` 的大量实测报告。
- [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker) —
  Windows/UEFI pre-driver 解锁工具（v2.1.5，GPL-2.0）；RTD3、GSP、Turing 差异等
  关键工程文档；本集成的事务执行体。
- [impacifist/Windows-GPU-UNLOCK](https://github.com/impacifist/Windows-GPU-UNLOCK) —
  Windows UEFI 移植的先驱实现。
- [matrixxx1/gpuunlock-windows](https://github.com/matrixxx1/gpuunlock-windows) —
  基于上游事务核的 RTX 4090 Laptop 专案，其选择器/托盘/状态脚本工程范式被本文借鉴。
- TOTORONG/AD103_win_unlocker — AD102 四写载荷的指令级来源（经上游仓库致谢链）。
- [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) —
  钉定固件资产的公开来源。
- 上游 issue/PR 的实测贡献者（4090D 八卡 #7、VFIO 2782 #15、各型号 matched 报告），
  以及本机 2026-10-29 首次桌面 `10de:2685` Windows 双端验证的全部数据记录。

## 10. 收录关键词 / Keywords (SEO)

RTX 4090D 解锁, RTX 4090 D unlock, 4090D 解锁, 4080 SUPER unlock, 4070 Ti SUPER,
Ada tensor core unlock, FP32 accumulate 2x, FP8 e4m3 unlock, TF32 unlock,
GSP-RM transaction, PLM open, fmla32, WPR2, SEC2 scrubber, nv-uefi-unlocker,
gpu-unlock-ada, Windows GPU unlock, UEFI pre-driver unlock, GRUB chainload EFI,
dual boot 解锁, vBIOS 不刷, tensor issue-rate benchmark, cuBLAS A/B, AD102 AD103,
10de:2685, GpuUnlockBench, CUDA driver API benchmark

---

# English

## 1. How it works

NVIDIA gates Ada's **FP32-accumulate tensor paths** (FP16→FP32, BF16→FP32,
TF32) and **FP8 (e4m3)** mma issue rates at half speed behind GSP-RM feature
selectors (PLM / SS0 / SS1, `fmla32`). Unlock = a cold-boot **firmware
transaction before any OS driver exists**: SEC2 scrub → FWSEC → signed Booter
→ GSP-RM load → the same V67 four-write payload the Linux module uses
(`44c36b2d…`, byte-identical to this repo's pinned `firmware/ada-610.43.03.json`)
→ marker `0x67b00001` → readback → one PCIe FLR → chainload
`bootmgfw.efi`. Volatile (dies at power-off, re-run every boot), OS- and
driver-version-independent (validated on Windows CUDA API 13.5 vs Linux
615.71.09), and every unsafe path aborts with zero writes (EALREADY on warm
boot, non-D0 abort via `tx-require-d0.txt`, handle-graph pinning).

Tool: [nv-uefi-unlocker v2.1.5](https://github.com/physicsdolphin/nv-uefi-unlocker)
(BOOTX64.EFI `9c615a3f…`), assets regenerated by its own
`make-usbroot.sh --family ad102` from pinned public inputs.

## 2–3. Install & use

```bash
cd /tmp && curl -LO https://github.com/physicsdolphin/nv-uefi-unlocker/releases/download/v2.1.5/nv-uefi-unlocker-v2.1.5.zip
unzip -o nv-uefi-unlocker-v2.1.5.zip
./make-usbroot.sh --family ad102 --out /tmp/nvu/usbroot --work /tmp/nvu/inputs
sudo ./linux/install_windows_unlock.sh /tmp/nvu/usbroot
```

Boot entry **Windows 11 (GPU Unlock)**: press Space/Enter within 30 s to run
the transaction (timeout or any other key = zero-write pass-through to
Windows). The `26_unlock_windows` GRUB hook re-validates and self-heals the
ESP payload on every `update-grub` (kernel installs, GRUB upgrades, Windows
Update cleanup) and only emits the entry while a Windows Boot Manager is
detected. Disable Windows "Fast Startup"; keep driver on 610/615/616.
Evidence: `/boot/efi/loader.log` after each run.

## 4–5. Verification (same-machine A/B, identical cubins)

`bench/gpu_unlock_bench_linux` and `bench/GpuUnlockBench.exe` — one C source,
two static single-file builds (driver-API only; they dlopen
`libcuda.so.1`/`nvcuda.dll` and print guided errors when it is absent),
embedding the exact `4fe8459d…`/`7f5aec64…` cubins; each writes
`unlock_bench_<stamp>.txt` with an automatic UNLOCKED/STOCK verdict.
`bench/embed_cubins.py` regenerates the embedded cubins and refuses on hash
drift.

| TF/s | Win stock | Win unlocked | ratio | Linux unlocked | Δ |
|---|---|---|---|---|---|
| fp8/e4m3 | 270.1 | **589.6** | **2.18×** | 589.4 | +0.03% |
| f16/f32 | 148.3 | **296.6** | **2.00×** | 295.2 | +0.5% |
| bf16/f32 | 133.7 | 296.3 | 2.22× | 295.1 | +0.4% |
| tf32 | 73.8 | 135.5 | 1.84× | 135.7 | ±1% |
| s8 / dp4a / ffma (controls) | unchanged | unchanged | ~1× | — | — |
| cell verification | 0 err | 0 err | — | 0 err | — |

## 6. What actually gets faster

**Benefits** (GEMMs on FP32-accumulate/FP8 tensor paths): LLM inference
**prefill/batching** on bf16/fp16 weights (vLLM, TensorRT-LLM, llama.cpp —
near-2× where compute-bound; decode stays bandwidth-bound); **FP8 models and
FP8 KV-cache** serving (compute ceiling doubles); **LoRA/full fine-tuning**
with torch autocast bf16; FP8/bf16 **Flux/SD3.5** pipelines; batched Whisper
or embedding workloads.
**No benefit**: INT8/INT4 inference (never gated, never doubled — matches
upstream's quantized-MoE "no change" case), games/DLSS rendering, pure FP32
HPC (FFMA), NVENC, VRAM capacity, memory-bandwidth-bound kernels.

## 7–8. Risk & removal

No VBIOS/flash/driver patching; worst case is a boot back to the stock entry.
Remove everything hash-checked:

```bash
sudo ./linux/uninstall_windows_unlock.sh
```

Files: `linux/install_windows_unlock.sh`, `linux/uninstall_windows_unlock.sh`,
`26_unlock_windows` (GRUB hook source). Provenance: tool `9c615a3f…`;
bench builds `0142c33d…` (Linux) / `3f43496d…` (exe); payload/asset hashes
in §1 and §4.

## Acknowledgments (EN)

Upstream research, Linux module and pinned AD102 payloads:
[JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada);
pre-OS UEFI transaction engine:
[physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker)
(GPL-2.0, v2.1.5); lineage: impacifist/Windows-GPU-UNLOCK,
matrixxx1/gpuunlock-windows, TOTORONG/AD103_win_unlocker (payload origin),
NVIDIA/open-gpu-kernel-modules (pinned firmware). First desktop `10de:2685`
dual-OS validated record: this repo, 2026-10-29 (`results/evidence/`).
