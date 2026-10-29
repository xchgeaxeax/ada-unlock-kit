#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Restore the /usr/local/share/nv-uefi-unlocker master copy from an intact
# ESP payload, verifying every file against the pinned provenance hashes
# (cross-checked with gpu-unlock-ada firmware/ada-610.43.03.json).
set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
ESP=$(awk '$3=="vfat" && ($2=="/boot/efi"||$2=="/efi"){print $2; exit}' /proc/mounts)
[ -n "$ESP" ] || { echo "no mounted ESP (vfat at /boot/efi or /efi)" >&2; exit 1; }
DEST=/usr/local/share/nv-uefi-unlocker

declare -A SHA=(
  [BOOTX64.EFI]=9c615a3f5f16dfbe4800a5c46251cdb20f2886bbb4bec70fecab3400a3c2f7c9
  [booter_load_ad102.bin]=6ee05b20e1dc244c08c052f36ef28469b8d09f4955d1fe33e48a179e11a7fd49
  [gsp_boot_ad102.bin]=45d6335a8185d6ff13e8d1484cea73f68d3d13aa1c19dc080ed1c3482dd5bac0
  [gsp_boot_desc_ad102.bin]=83f8f3f1f5f9496e0ea8fc7103c2beb64d0b6de2f5ffe725f13514de5a95fa42
  [v67-ad102-four-plm.bin]=44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb
  [fwimage_ad102.bin]=004394a6b5a217ef2445631f1e59fbca448d3d8aaa07e001898bf7569b98eec4
  [fwsignature_ad102.bin]=394612a0279ef8f8b457f91bfa35860e086d195d079975efa07b9f0938e019e7
  [scrubber_ad10x.bin]=1cfc78136a4dff4993b7e5a1a09345f6a67d0762555e5bd9660e406831379348
)
FILES=(BOOTX64.EFI booter_load_ad102.bin gsp_boot_ad102.bin gsp_boot_desc_ad102.bin \
       v67-ad102-four-plm.bin fwimage_ad102.bin fwsignature_ad102.bin scrubber_ad10x.bin)

fail=""
for f in "${FILES[@]}"; do
  got=$(sha256sum "$ESP/$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "${SHA[$f]}" ]; then echo "MISMATCH $f (ESP copy corrupted or foreign)"; fail=1; fi
done
[ -z "$fail" ] || { echo "refusing to stage bad payload - regenerate with nv-uefi-unlocker make-usbroot.sh"; exit 1; }

mkdir -p "$DEST"
for f in "${FILES[@]}"; do cp -f "$ESP/$f" "$DEST/$f"; done
for t in chain-target.txt tx-select-bdf.txt tx-require-d0.txt; do
  [ -f "$ESP/$t" ] && cp -f "$ESP/$t" "$DEST/$t"
done
( cd "$DEST" && sha256sum $(ls | grep -v '^SHA256SUMS$') > SHA256SUMS )
echo "master restored to $DEST"
if [ ! -x /etc/grub.d/26_unlock_windows ]; then
  echo "NOTE: install the GRUB hook too:"
  echo "  sudo install -m 0755 \"\$(dirname "$0")/26_unlock_windows\" /etc/grub.d/26_unlock_windows && sudo update-grub"
fi
update-grub >/dev/null && grep -q "Windows 11 (GPU Unlock)" /boot/grub/grub.cfg \
  && echo "GRUB entry present" || echo "WARN: entry not generated (Windows not detected?)"
