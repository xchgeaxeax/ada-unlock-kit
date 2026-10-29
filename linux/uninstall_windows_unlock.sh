#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove the "Windows 11 (GPU Unlock)" integration completely and safely.
# - deletes /etc/grub.d/26_unlock_windows and the master payload stage
# - deletes ESP payload files ONLY when their sha256 matches the stage
#   manifest (foreign files are kept and reported)
# - never touches the normal Windows or Linux boot entries
set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

STAGE=/usr/local/share/nv-uefi-unlocker
GRUBD=/etc/grub.d/26_unlock_windows

ESP=""
for c in /boot/efi /efi; do
  awk -v m="$c" '$2==m && $3=="vfat"{f=1} END{exit !f}' /proc/mounts && ESP=$c && break
done

if [ -n "$ESP" ]; then
  echo "ESP: $ESP"
  if [ -f "$STAGE/SHA256SUMS" ]; then
    while read -r hash path; do
      b=$(basename "$path")
      t="$ESP/$b"
      [ -f "$t" ] || continue
      if [ "$(sha256sum "$t" | cut -d' ' -f1)" = "$hash" ]; then
        rm -f -- "$t" && echo "  removed $t (matches manifest)"
      else
        echo "  KEPT $t (hash differs from manifest - not ours)"
      fi
    done < "$STAGE/SHA256SUMS"
  fi
  # loader.log is written by the tool at runtime; remove only our format.
  if [ -f "$ESP/loader.log" ] && grep -qE '^(NVUNL|TX|CHAIN|CONFIRM|ENUMERATE|SELECTOR|GOP)' "$ESP/loader.log" 2>/dev/null; then
    rm -f "$ESP/loader.log" && echo "  removed $ESP/loader.log"
  fi
fi

rm -f "$GRUBD" && echo "removed $GRUBD"
rm -rf "$STAGE" && echo "removed $STAGE"

if command -v update-grub >/dev/null 2>&1; then
  update-grub >/dev/null && echo "grub.cfg regenerated"
fi
if [ -n "$ESP" ] && ls "$ESP"/BOOTX64.EFI >/dev/null 2>&1; then
  echo "NOTE: $ESP/BOOTX64.EFI was not in the manifest and was kept."
fi
echo "Uninstall complete. Existing Windows/Linux entries are unchanged."
