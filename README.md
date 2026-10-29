# RTX 4090 D 双系统解锁套件（Linux + Windows）

一台机器、一块被"半速"的 4090 D，两个系统都要满速。Linux 侧用上游
[gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) 的内核模块早就跑通了；
这个仓库解决的是另一半：让 Windows 从 GRUB 的"解锁启动"条目进去时，同样拿到满速张量核。
启动项能自愈（内核升级、grub 重刷、甚至 Windows Update 清掉 ESP 文件都能恢复），一键卸载。

> 🇬🇧 English version: [jump down ↓](#english-version)

**先说结论**：fp8/e4m3 从 270 跑到 **589.6 TF/s（×2.18）**，f16/f32 从 148 到 **296.6（×2.00）**，
Linux 和 Windows 解锁态的数字对到了小数点后一位。游戏、INT8 量化推理不受益（见下文）。
**目前只有 `10de:2685`（4090D）完整实测过**，机制上适用于整个 Ada 家族，其他型号算"待验证"。

![license](https://img.shields.io/badge/license-GPL--2.0--only-blue) ![platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-informational) ![tested](https://img.shields.io/badge/tested-RTX%204090D%20(10de%3A2685)%20%C3%974%20boots-green)

## 为什么做这个

我的主力推理环境在 Linux（strata/LLM 服务常驻 45G 显存），解锁是今年早些时候的事。
切回 Windows 才发现什么都没变：卡还是半速。上游有 Windows 的思路——任何驱动加载**之前**
跑一次 pre-OS 的 UEFI 固件事务，但桌面 4090D 没人做过完整记录。于是把社区工具
[nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker) 接进 GRUB，
核对了它用的 AD102 载荷和上游内核模块是同一份字节，然后做了四次开机 A/B：
Linux 原生内核、Linux 换 XanMod、Windows 原版、Windows 解锁。本仓库就是这套产物：
安装/卸载脚本、GRUB 持久化钩子、双平台单文件自测程序，加上原始日志。

## 锁是怎么回事

NVIDIA 在 Ada 消费卡的 GSP-RM 固件里留了一组 feature 选择器（PLM / SS0 / SS1，
Linux 侧能观测到位名 `fmla32`），把张量核里**累加器是 FP32** 的矩阵乘压到半速：

| 通路 | 出厂状态 | 解锁后（本机实测） |
|---|---|---|
| FP16×FP16→**FP32** mma | 半速 | 148.3 → 296.6 TF/s |
| BF16→**FP32** mma | 半速 | 133.7 → 296.3 |
| TF32 mma | 半速 | 73.8 → 135.5 |
| **FP8 (e4m3)** mma | 半速 | 270.1 → 589.6 |
| FP16→FP16、INT8、dp4a、标量 FFMA | 本来就没压 | 不变 |

解锁不是刷 VBIOS、不是改驱动、也不是超频，而是一笔冷启动固件事务，跟 Linux 内核模块
（`unlock_610.c`）完全同族、同一份 AD102 四写载荷：

```
UEFI DXE 时窗（此时还没有任何 OS/驱动）
  SEC2 scrubber 停机 → FWSEC (FRTS) 拉起签名 Booter → 装载 GSP-RM
  → V67 四写 (WPR_CFG=0xfffff0ff，其余三个 =0xffffffff)
  → mailbox marker 0x67b00001 → 读回权限位和 SEC2-HALT → 一次 PCIe FLR
  → 全部验证通过才交链：加载 bootmgfw.efi 进 Windows
```

三个性质值得单独说，因为它们决定了风险和用法：

- **易失**。写在 GPU 寄存器里，断电就没了，所以每次开机都要重跑——这正是做成 GRUB 条目的原因。
- **跟 OS 和驱动版本无关**。事务在 boot services 阶段完成，后面装什么系统、驱动多新都不关心。
  证据：Windows 侧驱动是比 Linux 更新的分支（CUDA API 13.5 对 615.71.09/13.4），
  fp8 数字只差 0.03%。
- **失败就零写入**。载荷哈希、ROM/FWSEC 几何、控制台和 DMA 的 owner 图全部钉死才允许动卡；
  任何一步对不上，直接放弃写入链回正常 Windows。休眠/热恢复被 `tx-require-d0.txt` 挡住；
  已经开着 PLM 再跑一次返回 EALREADY 跳过，不会乱 FLR 打断已生效的状态。

供应链上我做了交叉验证：工具自带的 AD102 资产由 `make-usbroot.sh --family ad102` 从钉定的
公共输入离线再生，四个关键文件与上游仓库 `firmware/ada-610.43.03.json` 清单逐字节相同——
也就是说，Windows 写进卡里的，和 Linux 内核模块每天开机写的，是同一份东西。

| 资产 | SHA-256 | 对上上游清单 |
|---|---|---|
| `v67-ad102-four-plm.bin`（四写载荷） | `44c36b2d…` | ✅ |
| `booter_load_ad102.bin` | `6ee05b20…` | ✅ |
| `gsp_boot_ad102.bin` / `_desc_` | `45d6335a…` / `83f8f3f1…` | ✅ |
| `BOOTX64.EFI`（nv-uefi-unlocker v2.1.5） | `9c615a3f…` | — |

## 安装

```bash
# 1) 拉工具并离线生成资产（脚本自带钉定哈希校验，约 100MB 输入）
cd /tmp && curl -LO https://github.com/physicsdolphin/nv-uefi-unlocker/releases/download/v2.1.5/nv-uefi-unlocker-v2.1.5.zip
unzip -o nv-uefi-unlocker-v2.1.5.zip
./make-usbroot.sh --family ad102 --out /tmp/nvu/usbroot --work /tmp/nvu/inputs

# 2) 装进系统：母本进 /usr/local/share，载荷进 ESP，钩子进 /etc/grub.d/26
sudo ./linux/install_windows_unlock.sh /tmp/nvu/usbroot
```

安装后多出来的启动项叫 **Windows 11 (GPU Unlock)**，原来 os-prober 生成的普通
Windows 条目原封不动——两条路径互不影响，这也是故意留的回退。

钩子 `26_unlock_windows` 会在每次 `update-grub`（装内核自动触发）时做三件事：
先探测这台机器现在还有没有 Windows（没有就不生成条目，不会留死项）；再拿
`/usr/local/share/nv-uefi-unlocker` 母本对 ESP 上每个文件比哈希、缺了补；最后把当前
ESP 的 UUID 动态写进 `search --fs-uuid`。所以内核升级、grub 重刷、甚至 Windows
自己清理 ESP 之后，下次 `update-grub` 全部自动修复。如果 `/usr/local` 母本哪天也没了，
`linux/restore_master_from_esp.sh` 能从完好的 ESP 载荷反向重建（逐文件验哈希）。

ESP 根目录的文件一览（工具按自己所在卷的根路径读取）：

| 文件 | 作用 |
|---|---|
| `BOOTX64.EFI` | 事务执行体（v2.1.5） |
| `booter_load/gsp_boot(_desc)/fwimage/fwsignature/scrubber_*.bin` | 固件输入，共 ~85MB |
| `v67-ad102-four-plm.bin` | 它的存在本身就是开关：删掉退化成只读复演模式 |
| `tx-select-bdf.txt` | 钉 `0000:01:00.0`，多卡机器防写错对象 |
| `tx-require-d0.txt` | 非 D0 态（休眠恢复等）直接中止 |
| `chain-target.txt` | 钉死链回 `\EFI\Microsoft\Boot\bootmgfw.efi` |
| `loader.log` | 每次运行的完整证据日志，Linux 下随时能看 |
| `i_know_what_i_am_doing.txt` | 可选：armed 模式，5 秒倒计时自动跑 |

## 日常怎么跑

1. GRUB 选 **Windows 11 (GPU Unlock)**；
2. 屏显横幅后 **30 秒内按空格/回车才真正执行**——超时或按别的键就是普通进 Windows，零写入。
   （嫌每次按键麻烦就放 armed 文件改成 5 秒自动。）
3. 按下去之后**屏幕会黑一阵，这是正常的**：事务按设计要剥离这张卡的控制台拥有者。
   别慌也别断电，日志一直在写，写完自动进 Windows；
4. 回 Linux 验收：`cat /boot/efi/loader.log`，找 `SELECTOR RESULT: transaction complete`、
   四写读回和 `CHAIN` 行。

Windows 前置只有一条硬要求：**关掉快速启动**（混合关机后卡不在 D0，工具会按设计中止）。
驱动 610/615/616 分支都行。从已解锁的 Linux 热重启过去也没关系，PLM 已开就走 EALREADY 跳过。

## 自测工具（bench/）

Windows 和 Linux 用**同一份 C 源码**编译的两个二进制，内嵌与 Linux 上游完全相同的
两个 cubin（`4fe8459d…` / `7f5aec64…`）：7 个 mma 模式测发射率，另 3 个模式把
270,336 个输出单元全部读回比对，最后自动给 UNLOCKED / STOCK / INDETERMINATE 判定。
运行时只动态加载 `nvcuda.dll` / `libcuda.so.1`，没有 CUDA Toolkit、没有任何附带文件；
缺驱动、驱动太旧、cubin 损坏都会打人话报错，不会闷头退出。

| 文件 | 哈希前缀 | 备注 |
|---|---|---|
| `bench/gpu_unlock_bench_linux` | `0142c33d…` | 依赖只有 libc |
| `bench/GpuUnlockBench.exe` | `3f43496d…` | 静态 PE，任意目录双击，结果写同目录 txt |
| `bench/embed_cubins.py` | — | 从上游 .cu 重新生成内嵌头，哈希漂移直接报错 |

`linux/unlock_probe.sh` 是带完整环境记录的 shell 版（模块参数、内核日志、SM 频率和
节流采样一起存档），适合建正式基线；日常抽查用 bench 就行。

## 实测数字

机器：4090 D 48G 改版（`10de:2685`），ROG X670E，96G 内存。
Linux `7.3.0-x64v3-xanmod1` / NVIDIA `615.71.09`；Windows CUDA API 13.5。
同 cubin、同 iters/reps，空闲卡测试，四次开机原始记录在 `results/evidence/`。

| TF/s | Win 原版 | Win 解锁 | 倍率 | Linux 解锁 | Win vs Linux |
|---|---|---|---|---|---|
| fp8/e4m3 | 270.1 | **589.6** | **2.18×** | 589.4 | +0.03% |
| f16/f32 | 148.3 | **296.6** | **2.00×** | 295.2 | +0.5% |
| bf16/f32 | 133.7 | 296.3 | 2.22× | 295.1 | +0.4% |
| tf32 | 73.8 | 135.5 | 1.84× | 135.7 | ±1% |
| s8 / dp4a / ffma（对照） | 基本不动 | 基本不动 | ~1× | — | 一致 |
| 单元校验 | 0 错 | 0 错 | — | 0 错 | — |

形状和上游 4090 的报告吻合（FE 实测 165.6→331.6 精确 2.00×）；fp8 的 2.18× 对应
"半速→满速"。对照列没动说明测的不是整体频率红利，就是解锁本身。顺带一提，
Ubuntu 内核和 XanMod 内核下 Linux 数字也在噪声内（fp8 完全相同），换内核不影响。

## 什么卡能用（以及值不值得期待）

机制层：事务和固件资产是整个 Ada 家族共用的（AD102/103/103M/104/106/107，桌面+移动，
外加部分工作站 L 级——nv-uefi-unlocker 放行 `0x2600..0x28ff` 整段）；它的 `ga102`/`tu10x`
资产族把 RTX 30 全系、RTX 20/16（Turing，要 GSP 模式且 FLR 行为不同）也带上了。
Linux 上游则是逐 ID 白名单（16 个 Ada ID，见上游 README 矩阵）。专业 Ada、
数据卡（L4/L40）、Blackwell（RTX 50）两边都不收。

但注意，**这个仓库完整双端实测过的只有 `10de:2685`**。其他型号是"机制支持、
本套件未验证"。掏卡之前先花一分钟判断有没有油水：空闲状态跑一下 bench，
**fp8 是不是 s8 的一半**——是，说明这张卡被锁了，解锁预期 ~2×；
fp8 和 s8 差不多，说明这个 SKU 压根没被减半（真实例子：某 Clevo 模具的 4090 Laptop，
事务成功但吞吐一点没变），别浪费时间。笔记本额外两个坑：混显下先开独显直连
（控制台 owner 图不一样），Windows 里关掉 dGPU 的 RTD3（空闲进 D3cold 会把解锁抹掉）。

## 到底什么时候更快

这是**给 AI 数学库用的解锁**，跟图形性能无关。受益的是 cuBLAS/CUTLASS 里
`16F*16F+32F`、`BF16+32F`、`E4M3` 这几条 GEMM：

- 本地大模型推理的 **prefill / 批处理**（bf16/fp16 权重，vLLM、TensorRT-LLM、llama.cpp）：
  算力受限段最高接近 2×；decode 阶段吃的是显存带宽，提升有限。
- **FP8 模型和 FP8 KV cache**：Ada 特色，计算上限直接翻倍，长上下文和批量服务受益明显。
- **LoRA / 全参微调**（torch autocast bf16 的 matmul 就是 FP32 累加路径）。
- **Flux / SD3.5 这类 bf16/FP8 生图管线**里 GEMM 占比高的部分。
- Whisper 批处理、Embedding 大堆计算这类 GEMM-bound 杂活。

不受益，说死：**INT8/INT4 量化推理**（从没被锁也从没翻倍，上游量化 MoE 负载"无变化"
的记录就是这个原因）、**游戏和 DLSS**（FP16→FP16 和光栅单元不归它管）、
纯 FP32 科学计算（FFMA）、NVENC 视频编码、以及一切显存带宽瓶颈的负载。

## 风险

不写 VBIOS、不刷固件、不打补丁，解锁断电即失，事务失败路径全部是零写入退回正常启动。
最坏情况就是卡在工具横幅上，重启走原来的 Windows 条目即可。换卡或刷 VBIOS 后
ROM/FWSEC 钉定资产要重新生成（上游 testing.md 有流程）。整体是实验性方案，
生产机请挑能停机的时候验证。

## 卸载

```bash
sudo ./linux/uninstall_windows_unlock.sh
```

只删和母本清单哈希一致的文件（不一致的会保留并报告，防止误删别人的东西），
然后移除钩子和母本、重刷 grub.cfg。正常的 Windows/Linux 启动项全程没有碰过。

## 致谢

- [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)：
  上游研究，Linux 模块、探针工具和钉定固件清单都是它出的。本项目的 v67 载荷与它逐字节一致。
- [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker)：
  pre-OS UEFI 事务引擎（GPL-2.0, v2.1.5），关于 RTD3/GSP/Turing 的文档救了我不少时间。
- [impacifist/Windows-GPU-UNLOCK](https://github.com/impacifist/Windows-GPU-UNLOCK) 和
  [matrixxx1/gpuunlock-windows](https://github.com/matrixxx1/gpuunlock-windows)：
  Windows/UEFI 路线的先驱和 4090 Laptop 专案，交互与验证的范式学自这里。
- TOTORONG/AD103_win_unlocker：四写载荷的指令级来源（经上游致谢链）。
- [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)：钉定固件的出处。
- 上游各 issue/PR 的实测人（4090D 八卡的 #7、VFIO 的 #15、各 matched 报告）。

**AI 辅助声明**：本仓库的方案调研、代码、文档和测试执行由本地 AI 完成
（引擎 [Strata](https://github.com/Niko1221/Strata) 0.1.53，模型
[Qwen3.8-Flash-Next](https://github.com/QwenLM)，
[Unsloth](https://huggingface.co/unsloth) 的 UD Q4_K_XL 量化），全程离线推理；
机器所有者负责监督、复核与最终验证。所有数字来自本机实开实测，可复现
（`BUILD.txt` + 钉定哈希）。AI 会犯错，脚本先读再用。

## 关键词

RTX 4090D 解锁, RTX 4090 D unlock, 4080 SUPER unlock, Ada tensor core unlock,
FP32 accumulate 2x, FP8 e4m3, TF32, GSP-RM, PLM, fmla32, SEC2 scrubber, WPR2,
nv-uefi-unlocker, gpu-unlock-ada, Windows GPU unlock, UEFI pre-driver, GRUB
chainload, dual boot, 10de:2685, GpuUnlockBench, AD102, 4070 Ti SUPER, 4060 laptop

---

# English version

One machine, one RTX 4090 D, two OSes — both at full tensor speed. Upstream
[gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) unlocks the card under
Linux with a kernel module; this kit brings the same unlock to Windows via a pre-OS UEFI
transaction that runs from a self-healing GRUB entry before `bootmgfw.efi`. Verified numbers:
**fp8 270 → 589.6 TF/s (×2.18), f16/f32 148 → 296.6 (×2.00)**, and the Windows and Linux
unlocked results agree to within 0.5%.

## What the lock is

Ada GeForce parts ship with the FP32-accumulate tensor paths (FP16→FP32, BF16→FP32, TF32)
and FP8(e4m3) capped at half issue rate by GSP-RM feature selectors (PLM/SS0/SS1,
`fmla32`). FP16→FP16, INT8, dp4a and scalar FFMA were never capped and never change.
Unlock = a cold-boot firmware transaction (SEC2 scrub → FWSEC → signed Booter → GSP-RM load
→ four PLM writes → readback → one PCIe FLR → chainload). No VBIOS, no driver patching.
It is **volatile** (power-off resets it, so it runs at every boot) and **OS-independent**
(our Windows driver is a newer branch than Linux's; numbers match anyway).
The payload written on Windows is the exact same AD102 four-write blob the Linux module
uses — hash-checked against upstream's `firmware/ada-610.43.03.json`
(`v67-ad102-four-plm.bin` = `44c36b2d…`).

## Installing

```bash
cd /tmp && curl -LO https://github.com/physicsdolphin/nv-uefi-unlocker/releases/download/v2.1.5/nv-uefi-unlocker-v2.1.5.zip
unzip -o nv-uefi-unlocker-v2.1.5.zip
./make-usbroot.sh --family ad102 --out /tmp/nvu/usbroot --work /tmp/nvu/inputs
sudo ./linux/install_windows_unlock.sh /tmp/nvu/usbroot
```

A new **Windows 11 (GPU Unlock)** entry appears; your existing boot entries are untouched.
The GRUB hook re-checks Windows presence, re-verifies and restores the ESP payload by hash
on every `update-grub`, and reads the ESP UUID dynamically — kernel upgrades, GRUB updates
and Windows Update all survive. Disable Windows Fast Startup; drivers 610/615/616 are fine.

Usage: pick the entry, press Space/Enter within 30 s (otherwise it boots Windows with zero
writes). The screen goes dark during the transaction — that is the design releasing console
owners; let it finish. Evidence lands in `/boot/efi/loader.log`.

## Benchmark

`bench/gpu_unlock_bench_linux` and `bench/GpuUnlockBench.exe`: one C source, two static
single-file builds, same embedded cubins as the Linux reference tools (`4fe8459d…`/`7f5aec64…`),
driver-API only (dlopen; friendly errors if the driver is missing/old), 270,336-cell output
verification, automatic UNLOCKED/STOCK verdict in `unlock_bench_*.txt`.

## Results (RTX 4090 D, X670E, Linux xanmod 7.3.0-x64v3 / 615.71.09, Windows CUDA API 13.5)

| TF/s | Win stock | Win unlocked | ratio | Linux unlocked |
|---|---|---|---|---|
| fp8/e4m3 | 270.1 | 589.6 | 2.18× | 589.4 |
| f16/f32 | 148.3 | 296.6 | 2.00× | 295.2 |
| bf16/f32 | 133.7 | 296.3 | 2.22× | 295.1 |
| tf32 | 73.8 | 135.5 | 1.84× | 135.7 |
| controls (s8/dp4a/ffma) | unchanged | unchanged | ~1× | — |

## Supported devices

By design: the tool admits the whole `0x2600..0x28ff` window (all Ada desktop/mobile, plus
L-class), and `ga102`/`tu10x` asset families cover RTX 30 and RTX 20/16 (Turing needs GSP
mode; FLR behaves differently). **Verified here: only `10de:2685`** (four boots in
`results/evidence/`). Before trying a card, run the bench idle: fp8 ≈ s8/2 means the card
is throttled and unlock should ~2× it; fp8 ≈ s8 means the SKU was never halved and you
gain nothing (a real Clevo 4090-Laptop case showed exactly that). Laptops: use dGPU-direct,
and turn off RTD3 — D3cold erases the volatile unlock. Professional Ada, datacenter parts
and Blackwell are out of scope.

## What actually gets faster

Anything whose GEMMs run FP32-accumulate or FP8 on tensor cores: LLM **prefill/batching**
(vLLM, TensorRT-LLM, llama.cpp), **FP8 models and KV cache**, **LoRA/bf16 fine-tuning**,
bf16/FP8 image pipelines (Flux, SD3.5), batched Whisper/embeddings. Not faster: INT8/INT4
inference (never gated), games/DLSS, FFMA-bound HPC, NVENC, bandwidth-bound work.

## Risk & removal

No firmware or driver modification; failed paths write nothing and boot Windows normally;
worst case, reboot into your untouched Windows entry. Remove everything:

```bash
sudo ./linux/uninstall_windows_unlock.sh
```

(Hash-checked: files that don't match the manifest are kept and reported.)

## Acknowledgments & AI-assistance disclosure

Same list as above: gpu-unlock-ada (upstream research/module/payloads),
nv-uefi-unlocker v2.1.5 (the transaction engine), impacifist/Windows-GPU-UNLOCK and
matrixxx1/gpuunlock-windows (pioneers), TOTORONG (payload origin),
NVIDIA/open-gpu-kernel-modules (firmware source), upstream testers.

This repository was produced with a fully **local** AI stack (engine:
[Strata](https://github.com/Niko1221/Strata) 0.1.53; model:
[Qwen3.8-Flash-Next](https://github.com/QwenLM),
[Unsloth](https://huggingface.co/unsloth) UD Q4_K_XL quant), supervised and verified on-device
by the owner. Numbers are reproducible (`BUILD.txt`, pinned hashes); AI output can be wrong,
so read the scripts before running them.
