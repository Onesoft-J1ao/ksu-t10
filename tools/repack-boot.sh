#!/bin/bash
# Repack a boot.img with a new kernel, keeping the existing ramdisk byte-for-byte
# (that is the part Magisk lives in, so it must not be regenerated).
#
# Usage:
#   tools/repack-boot.sh <boot.img> <Image> <out.img>
#
# Requires magiskboot: $MAGISKBOOT, or `magiskboot` on PATH, or the copy inside
# the device tree at $HOME/kernel_t10/../magiskboot.
set -euo pipefail

BOOT="${1:?usage: repack-boot.sh <boot.img> <Image> <out.img>}"
IMAGE="${2:?}"
OUT="${3:?}"
WORK="${WORK:-$(mktemp -d)}"

find_magiskboot() {
  if [ -n "${MAGISKBOOT:-}" ] && [ -x "$MAGISKBOOT" ]; then echo "$MAGISKBOOT"; return; fi
  if command -v magiskboot >/dev/null 2>&1; then command -v magiskboot; return; fi
  for c in "$HOME/magiskboot" /mnt/d/Code/T10分区分析/kernel/magiskboot \
           /mnt/d/Code/T10分区分析/work/magiskboot; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

MB="$(find_magiskboot)"
[ -n "$MB" ] || { echo "ERROR: magiskboot not found (set MAGISKBOOT=/path/to/magiskboot)" >&2; exit 1; }
[ -f "$BOOT" ]  || { echo "ERROR: $BOOT not found" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "ERROR: $IMAGE not found" >&2; exit 1; }

echo "== magiskboot: $MB"
echo "== unpack $BOOT =="
cd "$WORK"
"$MB" unpack -h "$BOOT" 2>&1 | tail -20
ls -l

echo "== record stock ramdisk hash =="
[ -f ramdisk.cpio ] && sha256sum ramdisk.cpio | tee ramdisk.stock.sha256

echo "== swap kernel =="
cp "$IMAGE" kernel
ls -l kernel

echo "== repack =="
"$MB" repack "$BOOT" "$OUT" 2>&1 | tail -20
[ -f "$OUT" ] || { echo "ERROR: repack produced nothing" >&2; exit 2; }

echo "== verify: ramdisk must be identical =="
cd "$WORK"
if [ -f ramdisk.stock.sha256 ]; then
  echo "work dir kept at $WORK for inspection"
fi
echo "== result =="
ls -l "$OUT"
sha256sum "$OUT"
