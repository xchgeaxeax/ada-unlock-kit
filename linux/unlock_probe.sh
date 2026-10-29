#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# 算力解锁实测（RTX 4090 D / NVIDIA 615.x，可扩展到其他 Ada/Ampere 卡）
# 使用 gpu-unlock-ada 项目自带探针：tensor_modes_driver_runner (mma 发射率+全单元校验) + mma_bench (fp8 及各模式)
# 用法：先关闭 strata 等一切占用 GPU 的进程，然后运行本脚本。
#   可覆盖环境变量：GPU_UNLOCK_REPO(上游仓库路径) PROBE_UUID PROBE_POWER OUT_DIR
set -euo pipefail
REPO="${GPU_UNLOCK_REPO:-$HOME/code/gpu-unlock-ada}"
[ -f "$REPO/diagnostics/bench/tensor_modes_issue.cu" ] || {
  echo "找不到 $REPO/diagnostics/bench —— 请先 clone https://github.com/JustAResearcher/gpu-unlock-ada 或设 GPU_UNLOCK_REPO" >&2; exit 1; }

UUID="${PROBE_UUID:-GPU-53cfaf81-4cc6-272d-b827-ed6fd527711f}"
POWER="${PROBE_POWER:-425}"   # 本机 power.limit；nvidia-smi --query-gpu=power.limit 核对
OUT="${OUT_DIR:-.}/probe-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "== 结果目录: $OUT"

echo "== [1/6] 构建探针 (nvcc $(nvcc --version | grep -o 'release [0-9.]*' | cut -d' ' -f2))"
nvcc -ptx -arch=sm_89 -O3 -std=c++17 \
  -o "$OUT/tensor_modes_issue_sm89.ptx" "$REPO/diagnostics/bench/tensor_modes_issue.cu"
ptxas -arch=sm_89 -O3 -o "$OUT/tensor_modes_issue_sm89.cubin" "$OUT/tensor_modes_issue_sm89.ptx"
SHA=$(sha256sum "$OUT/tensor_modes_issue_sm89.cubin" | cut -d' ' -f1)
nvcc -O3 -arch=sm_89 -std=c++17 -o "$OUT/mma_bench" "$REPO/diagnostics/bench/mma_bench.cu"
echo "   cubin sha256: $SHA"

echo "== [2/6] 检查 GPU 是否空闲 (连续两次采样 利用率=0 且 显存<2000MiB)"
for try in 1 2; do
  line=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits)
  util=${line%%,*}; mem=${line##*,}
  if [ "$try" = 1 ]; then sleep 3; continue; fi
  if [ "${util// /}" -ne 0 ] || [ "${mem// /}" -gt 2000 ]; then
    echo "   忙: util=${util}% mem=${mem}MiB —— 请先关闭 strata 或其他 GPU 进程后重试。"
    rm -rf "$OUT"
    exit 1
  fi
done
echo "   GPU 空闲，开始。"

echo "== [3/6] 记录环境与模块状态"
{
  nvidia-smi --query-gpu=name,driver_version,vbios_version,clocks.max.sm,temperature.gpu,power.draw \
    --format=csv
  echo "params.targets=$(cat /sys/module/gpu_unlock/parameters/targets 2>/dev/null)"
  echo "params.rtx4090d_experimental=$(cat /sys/module/gpu_unlock/parameters/rtx4090d_experimental 2>/dev/null)"
  journalctl -k -b --no-pager 2>/dev/null | grep -i gpu_unlock || true
} > "$OUT/env.txt"
cat "$OUT/env.txt"

echo "== [4/6] 记录核心频率采样 (后台)"
nvidia-smi --query-gpu=clocks.sm,temperature.gpu,power.draw,clocks_event_reasons.active \
  --format=csv,noheader -lms 500 > "$OUT/clocks.txt" 2>/dev/null &
CLOCKPID=$!
trap 'kill $CLOCKPID 2>/dev/null || true' EXIT

echo "== [5/6] 运行探针"
python3 "$REPO/diagnostics/bench/tensor_modes_driver_runner.py" \
  "$OUT/tensor_modes_issue_sm89.cubin" \
  --sha256 "$SHA" \
  --expect-uuid "$UUID" \
  --expect-power-limit "$POWER" > "$OUT/tensor_modes.json" 2>&1
echo "   runner 完成 (校验失败会非零退出且不生成 PASS)"
"$OUT/mma_bench" 20000 3 | tee "$OUT/mma_bench.txt"
kill $CLOCKPID 2>/dev/null; trap - EXIT

echo "== [6/6] 判定"
python3 - "$OUT/tensor_modes.json" "$OUT/mma_bench.txt" <<'PY'
import json, re, sys
tj = json.load(open(sys.argv[1]))
mb = open(sys.argv[2]).read()
g = lambda label: tj["modes"][label]["best_Top_per_s"]
def mbv(mode):
    m = re.search(rf"^{mode}\s+([0-9.]+)", mb, re.M)
    return float(m.group(1)) if m else None

# 参照 4090 FE (2640MHz) 报告值按 4090D 典型 ~2520MHz 缩放 (x0.955)
# 未解锁(FE: f16/f32 165.6, fp8 ~301) / 已解锁(FE: f16/f32 331.6, fp8 603.1)
F16_FULL_MIN, F16_HALF_MAX = 290, 210
FP8_FULL_MIN, FP8_HALF_MAX = 500, 380
checks = {
  "f16/f32 (runner,发射率,含全单元校验)": g("f16_f32"),
  "bf16/f32 (mma_bench)":                 mbv("bf16/f32"),
  "fp8/e4m3 (mma_bench)":                 mbv("fp8/e4m3"),
  "ffma 标量FP32 (对照组,应~75-85)":       mbv("ffma"),
  "dp4a (对照组,应不变)":                  mbv("dp4a"),
  "s8/s32 (对照组,应不变)":                mbv("s8/s32"),
}
for k, v in checks.items():
    print(f"  {k:45s} = {v:.1f} TF/s" if v else f"  {k:45s} = 缺失")

f16, fp8 = g("f16_f32"), mbv("fp8/e4m3")
if f16 >= F16_FULL_MIN and fp8 >= FP8_FULL_MIN:
    print("\n  结论: 615.71.09 上解锁已生效 — f16/f32 与 fp8 均为满速 (2x 半速上界)。")
elif f16 <= F16_HALF_MAX or fp8 <= FP8_HALF_MAX:
    print("\n  结论: 615.71.09 上解锁未生效 — 测得半速，模块在新驱动上没有打开 PLM。")
else:
    print("\n  结论: 介于两带之间 — 检查降频 (clocks.txt 节流原因) 或功耗墙后重跑。")
PY
echo "== 完成。结果已保存在 $OUT/，可以重新打开 strata 了。"
