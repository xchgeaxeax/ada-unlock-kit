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
for f in booter_load_ad102.bin gsp_boot_ad102.bin gsp_boot_desc_ad102.bin fwimage_ad102.bin fwsignature_ad102.bin scrubber_ad10x.bin; do
  [ -f "$STAGE_SRC/$f" ] || { echo "missing asset: $f" >&2; exit 1; }
done
[ -f "$STAGE_SRC/v67-ad102-four-plm.bin" ] || echo "WARN: v67 payload absent - tool runs in replay (no-write) mode" >&2

DEST=/usr/local/share/nv-uefi-unlocker
mkdir -p "$DEST"
cp -a "$STAGE_SRC"/. "$DEST"/
( cd "$DEST" && sha256sum $(ls | grep -v SHA256SUMS) > SHA256SUMS )

install -m 0755 "$(dirname "$0")/26_unlock_windows" /etc/grub.d/26_unlock_windows
update-grub
grep -q "Windows 11 (GPU Unlock)" /boot/grub/grub.cfg && echo "entry installed" || { echo "entry NOT generated: no Windows bootmgfw detected" >&2; exit 1; }
echo "Done. Select 'Windows 11 (GPU Unlock)' at boot and press Space within 30 s."
