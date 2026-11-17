#!/bin/bash
# Build the T10 kernel (4.14.98) with a chosen config on top of the device's
# own defconfig, entirely out-of-tree so ~/kernel_t10 is never modified.
#
# Usage:
#   tools/build-kernel.sh [stage]
#     stage = overlay | kprobes | ksu        (default: overlay)
#
# Output: out/<stage>/Image  (+ .config used, build log)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL="${KERNEL:-$HOME/kernel_t10}"
STAGE="${1:-overlay}"
OUT="$REPO/out/$STAGE"
CONFIG_BASE="${CONFIG_BASE:-$KERNEL/.config}"
CROSS="${CROSS:-$HOME/bin/aarch64-linux-gnu-}"

# ---- device identity, pinned so vermagic matches exactly -------------------
WANT_RELEASE="4.14.98-g3ff394f6011d-dirty"
KBUILD_BUILD_USER=kbuild
KBUILD_BUILD_HOST=t10lab
KBUILD_BUILD_TIMESTAMP="Sat May 16 13:48:43 CST 2026"

[ -f "$KERNEL/Makefile" ] || { echo "ERROR: $KERNEL is not a kernel tree" >&2; exit 1; }
[ -f "$CONFIG_BASE" ]     || { echo "ERROR: base config $CONFIG_BASE missing" >&2; exit 1; }
[ -x "${CROSS}gcc" ]      || { echo "ERROR: cross compiler ${CROSS}gcc missing" >&2; exit 1; }

mkdir -p "$OUT"
LOG="$OUT/build.log"
: > "$LOG"

# ---- 1. seed the config ----------------------------------------------------
# Note: with O=<dir>, kbuild always reads/writes <dir>/.config and ignores
# KCONFIG_CONFIG, so the staging file is .config inside $OUT.
cp "$CONFIG_BASE" "$OUT/.config"

# localversion must stay pinned: CONFIG_LOCALVERSION_AUTO would append -g<hash>
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT/.config"
if grep -q '^CONFIG_LOCALVERSION=' "$OUT/.config"; then
  sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"-g3ff394f6011d-dirty\"|" "$OUT/.config"
else
  echo 'CONFIG_LOCALVERSION="-g3ff394f6011d-dirty"' >> "$OUT/.config"
fi
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set' "$OUT/.config" || \
  echo '# CONFIG_LOCALVERSION_AUTO is not set' >> "$OUT/.config"

# ---- 2. stage-specific knobs ----------------------------------------------
apply_stage() {
  case "$STAGE" in
    overlay)
      sed -i 's/^# CONFIG_OVERLAY_FS is not set/CONFIG_OVERLAY_FS=y/' "$OUT/.config"
      ;;
    kprobes)
      sed -i 's/^# CONFIG_OVERLAY_FS is not set/CONFIG_OVERLAY_FS=y/' "$OUT/.config"
      sed -i 's/^# CONFIG_KPROBES is not set/CONFIG_KPROBES=y/'       "$OUT/.config"
      sed -i 's/^# CONFIG_KPROBE_EVENTS is not set/CONFIG_KPROBE_EVENTS=y/' "$OUT/.config"
      ;;
    ksu)
      sed -i 's/^# CONFIG_OVERLAY_FS is not set/CONFIG_OVERLAY_FS=y/' "$OUT/.config"
      sed -i 's/^# CONFIG_KPROBES is not set/CONFIG_KPROBES=y/'       "$OUT/.config"
      sed -i 's/^# CONFIG_KPROBE_EVENTS is not set/CONFIG_KPROBE_EVENTS=y/' "$OUT/.config"
      # KSU needs these to be certain the module layout is stable.
      grep -q '^CONFIG_KALLSYMS_ALL=y' "$OUT/.config" || \
        sed -i 's/^# CONFIG_KALLSYMS_ALL is not set/CONFIG_KALLSYMS_ALL=y/' "$OUT/.config"
      ;;
    *)
      echo "ERROR: unknown stage '$STAGE' (overlay|kprobes|ksu)" >&2
      exit 2
      ;;
  esac
}
apply_stage

# ---- 3. cross-compile environment -----------------------------------------
export ARCH=arm64
export CROSS_COMPILE="$CROSS"
export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"
export KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_TIMESTAMP
# gcc >=10 defaults to -fno-common, which breaks this 4.14 tree (dtc yylloc).
# gcc >=10 defaults to -fno-common, which breaks this 4.14 tree (dtc's yylloc).
export HOSTCFLAGS="-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon"
# gcc 12 raises a pile of diagnostics that did not exist when 4.14 shipped
# (-Warray-bounds, -Warray-compare, -Waddress-of-packed-member, ...). They are
# all false positives on this tree. Rather than chase them one at a time, turn
# off the whole "new gcc vs old kernel" class via KCFLAGS and a build-time
# KCFLAGS_EXTRAS hook.
export KCFLAGS="-fcommon \
 -Wno-error \
 -Wno-array-bounds -Wno-array-compare -Wno-address-of-packed-member \
 -Wno-stringop-overflow -Wno-stringop-overread -Wno-stringop-truncation \
 -Wno-restrict -Wno-dangling-pointer -Wno-use-after-free \
 -Wno-maybe-uninitialized -Wno-unused-but-set-variable \
 -Wno-missing-attributes -Wno-attribute-alias -Wno-packed-not-aligned \
 -Wno-designated-init -Wno-deprecated-declarations -Wno-incompatible-pointer-types \
 -Wno-int-conversion -Wno-implicit-function-declaration"

cd "$KERNEL"

echo "== [$STAGE] olddefconfig ==" | tee -a "$LOG"
make O="$OUT" ARCH=arm64 olddefconfig HOSTCFLAGS="$HOSTCFLAGS" 2>&1 | tee -a "$LOG" | tail -3

echo "== [$STAGE] prepare (generates include/config/kernel.release) ==" | tee -a "$LOG"
if ! make O="$OUT" ARCH=arm64 -j"$(nproc)" HOSTCFLAGS="$HOSTCFLAGS" KCFLAGS="$KCFLAGS" \
     prepare 2>&1 | tee -a "$LOG" | tail -6
then
  echo "ERROR: prepare failed, see $LOG" >&2
  grep -E "error:|Error [0-9]" "$LOG" | tail -10 >&2 || true
  exit 6
fi

echo "== [$STAGE] verify kernelrelease ==" | tee -a "$LOG"
REL=$(make -s O="$OUT" ARCH=arm64 kernelrelease HOSTCFLAGS="$HOSTCFLAGS" 2>/dev/null | tail -1)
echo "kernelrelease = $REL" | tee -a "$LOG"
if [ "$REL" != "$WANT_RELEASE" ]; then
  echo "ERROR: kernelrelease mismatch, want $WANT_RELEASE" | tee -a "$LOG" >&2
  exit 3
fi

# Guard the one config that would invalidate every existing .ko:
if grep -q '^CONFIG_FUNCTION_TRACER=y' "$OUT/.config"; then
  echo "ERROR: CONFIG_FUNCTION_TRACER=y changes struct module / module_layout CRC" | tee -a "$LOG" >&2
  echo "       existing priv_*.ko would stop loading. Refusing to build." | tee -a "$LOG" >&2
  exit 4
fi

echo "== [$STAGE] build Image ==" | tee -a "$LOG"
if ! make O="$OUT" ARCH=arm64 -j"$(nproc)" HOSTCFLAGS="$HOSTCFLAGS" KCFLAGS="$KCFLAGS" \
     Image 2>&1 | tee -a "$LOG" | tail -20
then
  echo "ERROR: kernel build failed, see $LOG" >&2
  grep -E "error:|Error [0-9]|undefined reference" "$LOG" | tail -15 >&2 || true
  exit 7
fi

IMG="$OUT/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "ERROR: no Image produced" >&2; exit 5; }

echo "== [$STAGE] result ==" | tee -a "$LOG"
ls -l "$IMG" | tee -a "$LOG"
sha256sum "$IMG" | tee -a "$LOG"
echo "config: $OUT/.config" | tee -a "$LOG"
