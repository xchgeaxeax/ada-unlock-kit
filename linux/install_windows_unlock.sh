#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the "Windows 11 (GPU Unlock)" GRUB integration.
# Usage: sudo ./install_windows_unlock.sh <stage-dir>
#   <stage-dir> must contain nv-uefi-unlocker v2.1.5 (BOOTX64.EFI) plus the
#   ad102 asset bundle, e.g. produced by:
#     curl -LO https://github.com/physicsdolphin/nv-uefi-unlocker/releases/download/v2.1.5/nv-uefi-unlocker-v2.1.5.zip
#     unzip nv-uefi-unlocker-v2.1.5.zip && ./make-usbroot.sh --family ad102 --out stage
#   Verify generated assets against firmware/ada-610.43.03.json in this repo
#   (booter_load_ad102.bin, gsp_boot_ad102.bin, gsp_boot_desc_ad102.bin,
#    v67-ad102-four-plm.bin must match the pinned SHA-256 entries).
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 <stage-dir>" >&2; exit 1; }
[ -d /sys/firmware/efi ] || { echo "not a UEFI system" >&2; exit 1; }
STAGE_SRC=${1:-}
[ -n "$STAGE_SRC" ] && [ -f "$STAGE_SRC/BOOTX64.EFI" ] || { echo "stage dir with BOOTX64.EFI required" >&2; exit 1; }
# Infer asset family from the stage: ad102 (Ada) / ga102 (Ampere) / tu10x (Turing)
if   [ -f "$STAGE_SRC/booter_load_ad102.bin" ]; then FAM=ad102
elif [ -f "$STAGE_SRC/booter_load_ga102.bin" ]; then FAM=ga102
elif [ -f "$STAGE_SRC/booter_load_tu10x.bin" ]; then FAM=tu10x
else echo "stage contains no known asset family (booter_load_ad102|ga102|tu10x.bin)" >&2; exit 1; fi
echo "asset family: $FAM"
for f in "booter_load_$FAM.bin" "gsp_boot_$FAM.bin" "gsp_boot_desc_$FAM.bin" "fwimage_$FAM.bin" "fwsignature_$FAM.bin"; do
  [ -f "$STAGE_SRC/$f" ] || { echo "missing asset: $f" >&2; exit 1; }
done
ls "$STAGE_SRC"/scrubber_*.bin >/dev/null 2>&1 || { echo "missing scrubber_*.bin" >&2; exit 1; }
[ "$FAM" != tu10x ] || { [ -f "$STAGE_SRC/sec2_bl_tu10x.bin" ] || { echo "tu10x needs sec2_bl_tu10x.bin" >&2; exit 1; }; }
[ -f "$STAGE_SRC/v67-$FAM-four-plm.bin" ] || echo "WARN: v67 payload absent - tool runs in replay (no-write) mode" >&2

DEST=/usr/local/share/nv-uefi-unlocker
mkdir -p "$DEST"
cp -a "$STAGE_SRC"/. "$DEST"/
( cd "$DEST" && sha256sum $(ls | grep -v SHA256SUMS) > SHA256SUMS )

install -m 0755 "$(dirname "$0")/26_unlock_windows" /etc/grub.d/26_unlock_windows
update-grub
grep -q "Windows 11 (GPU Unlock)" /boot/grub/grub.cfg && echo "entry installed" || { echo "entry NOT generated: no Windows bootmgfw detected" >&2; exit 1; }
echo "Done. Select 'Windows 11 (GPU Unlock)' at boot and press Space within 30 s."
