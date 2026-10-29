#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# setup_linux_unlock.sh — Linux 侧单独使用（不需要 Windows）：
#   检测发行版与构建环境 -> 提示/安装依赖 -> 克隆上游并 make install ->
#   打印本机卡所需的内核启动参数与验证步骤。
# 交互安全：只读取；所有 sudo 写操作先展示命令并要求确认。
set -u

OS_ID=""; OS_LIKE=""; PRETTY=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"; OS_LIKE="${ID_LIKE:-}"; PRETTY="${PRETTY_NAME:-$OS_ID}"
fi

say()  { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
target_family() {
  case "$1:$OS_LIKE" in
    *ubuntu*|*debian*) echo apt ;;
    *fedora*|*rhel*|*centos*) echo dnf ;;
    *arch*|*manjaro*) echo pacman ;;
    *suse*) echo zypper ;;
    *) echo unknown ;;
  esac
}
FAM=$(target_family "${OS_ID:-}")

KERNEL=$(uname -r)
missing=""
for tool in git curl make gcc python3 zstd sha256sum lspci; do
  have "$tool" || missing="$missing $tool"
done
case "$FAM" in
  apt)
    [ -d "/lib/modules/$KERNEL/build" ] || missing="$missing linux-headers"
    have dkms || missing="$missing dkms"
    PKG_HINT="sudo apt update && sudo apt install -y git build-essential linux-headers-$(uname -r) dkms python3 zstd pciutils curl"
    ;;
  dnf)
    rpm -q "kernel-devel-$KERNEL" >/dev/null 2>&1 || missing="$missing kernel-devel"
    have dkms || missing="$missing dkms"
    PKG_HINT="sudo dnf install -y git gcc make kernel-devel kernel-headers dkms python3 zstd pciutils curl"
    ;;
  pacman)
    [ -d "/lib/modules/$KERNEL/build" ] || missing="$missing linux-headers"
    have dkms || missing="$missing dkms"
    PKG_HINT="sudo pacman -S --needed git base-devel linux-headers dkms python3 zstd pciutils curl"
    ;;
  zypper)
    [ -d "/lib/modules/$KERNEL/build" ] || missing="$missing kernel-devel"
    PKG_HINT="sudo zypper install -y git gcc make kernel-devel kernel-devel-extra dkms python3 zstd pciutils curl"
    ;;
  *)
    PKG_HINT="(未识别的发行版 $PRETTY：请手动准备 git、C 工具链、内核头文件、dkms、python3、zstd)"
    ;;
esac

say "== 发行版: $PRETTY (包管理: $FAM)"
say "== 内核: $KERNEL"

# 目标卡与上游支持检查
GPU_LINE=$(lspci -Dnn 2>/dev/null | grep -i 'nvidia' | grep -iE 'VGA|3D|Display' | head -1)
if [ -z "$GPU_LINE" ]; then
  say "!! 未检测到 NVIDIA 显示设备。若为混合显卡笔记本，请先切换/确认可见的独显。"
else
  say "== 显卡: $GPU_LINE"
  DEV_ID=$(printf '%s' "$GPU_LINE" | sed -n 's/.*\[10de:\([0-9a-fA-F]\{4\}\)\].*/\1/p' | tr 'A-F' 'a-f' | head -1)
  case "$DEV_ID" in
    2684) say "   -> RTX 4090：上游主验证路径，无需实验开关。" ;;
    2685|2689|2702|2704|2705|2709|2757|2782|2783|2786|2803|2805|2882|28a0|28e0|28e1)
        say "   -> 上游实验白名单 ID（${DEV_ID}），需要各自的 opt-in 标志 + 精确 targets；下一步会打印完整参数。" ;;
    *)  say "   !! 10de:${DEV_ID} 不在上游支持表；不要强行解锁（机制按卡家族钉定，跨家族误配会 HALT 且不解锁）。"
        say "      参考上游 README 的实验目标表确认后再运行本脚本。" ;;
  esac
fi

if [ -n "$missing" ]; then
  say ""
  say "!! 缺少构建环境组件:$missing"
  say "建议安装命令："
  say "   $PKG_HINT"
  if [ "${1:-}" = "--install-deps" ]; then
    say ""
    read -r -p "现在执行上述安装？[y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] && eval "$PKG_HINT" || { say "安装失败或取消"; exit 1; }
  else
    say "（加 --install-deps 参数可让本脚本代执行）"
    exit 1
  fi
fi
[ -n "$missing" ] && exit 1

say ""
say "== 环境就绪。开始上游安装（会下载 SHA-256 钉定的 610.43.03 固件输入并本地构建 DKMS 包）"
REPO_DIR="${GPU_UNLOCK_REPO:-$HOME/code/gpu-unlock-ada}"
if [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone https://github.com/JustAResearcher/gpu-unlock-ada.git "$REPO_DIR"
fi
cd "$REPO_DIR"
git pull --ff-only 2>/dev/null || true
say ""
say "即将执行：sudo make install  （自动选择 Arch/Debian/Fedora 打包路径，逐包安装 dkms+固件；"
say "会先构建，可能需要几分钟）"
read -r -p "继续？[y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 0
sudo make install

# 打印本机所需启动参数
BDF=$(printf '%s' "${GPU_LINE:-}" | awk '{print $1}')
say ""
say "== 最后一步：内核启动参数。上游提供打印器："
say "   python3 tools/print_boot_option.py $BDF"
OPT=$(python3 tools/print_boot_option.py "$BDF" 2>/dev/null || true)
[ -n "$OPT" ] && say "   -> $OPT"
say ""
say "按引导器写入（示例，请自行核对再执行）："
say "  GRUB:       编辑 /etc/default/grub 的 GRUB_CMDLINE_LINUX_DEFAULT 追加参数 && sudo update-grub"
say "  systemd-boot: 编辑 /boot/loader/entries/*.conf 的 options 行"
say "  其他 EFI 引导器：参考上游 QUICKSTART.md 'Add the kernel command line'"
say ""
say "重启后验证（缺一不可，模块加载 ≠ 解锁成功）："
say "  1) sudo journalctl -k -b | grep 'gpu_unlock.*unlocked'"
say "  2) nvidia-smi 正常"
say "  3) 空闲 GPU 跑 bench/gpu_unlock_bench_linux：fp8 ≈ s8 即满速（被锁时 fp8 ≈ s8/2）"
