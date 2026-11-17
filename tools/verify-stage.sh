#!/bin/bash
# Post-flash verification for a ksu-t10 stage build. READ-ONLY against the device.
#
# Usage: tools/verify-stage.sh [stage]
set -uo pipefail

ADB="${ADB:-D:/Code/XTC-part/XTCTool/platform-tools/adb.exe}"
SERIAL="${SERIAL:?set SERIAL to your device serial}"
STAGE="${1:-overlay}"
PASS=0; FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }

sh_() { "$ADB" -s "$SERIAL" shell "$1" 2>/dev/null | tr -d '\r'; }
su_() { "$ADB" -s "$SERIAL" shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

say "== stage: $STAGE =="
say "== kernel =="
KV=$(sh_ 'cat /proc/version')
say "  $KV"
case "$KV" in
  *4.14.98-g3ff394f6011d-dirty*) ok "kernel release matches 4.14.98-g3ff394f6011d-dirty" ;;
  *) bad "kernel release unexpected: $KV" ;;
esac

say "== magisk =="
MV=$(su_ 'magisk -v; magisk -V')
say "  $MV"
case "$MV" in
  *MAGISK*) ok "magisk responds" ;;
  *) bad "magisk not responding" ;;
esac
MP=$(su_ 'magisk --path')
say "  magisk --path = $MP"
[ "$MP" = "/sbin" ] && ok "magisk still in ramdisk mode (/sbin)" || bad "magisk path changed: $MP"

say "== overlayfs mounted or available =="
OFS=$(sh_ 'grep -c overlay /proc/filesystems')
[ "${OFS:-0}" -ge 1 ] && ok "overlay registered in /proc/filesystems" || bad "overlay not in /proc/filesystems"

say "== kprobes (stage kprobes/ksu only) =="
if [ "$STAGE" != "overlay" ]; then
  KP=$(su_ 'ls /sys/kernel/debug/tracing/kprobe_events 2>/dev/null || ls /sys/kernel/tracing/kprobe_events 2>/dev/null')
  [ -n "$KP" ] && ok "kprobe_events present: $KP" || bad "kprobe_events missing"
fi

say "== lsposed =="
LP=$(su_ 'pidof lspd')
[ -n "$LP" ] && ok "lspd running (pid $LP)" || bad "lspd not running"
ZY=$(su_ 'grep -c lspd /proc/$(pidof zygote64)/maps 2>/dev/null')
[ "${ZY:-0}" -ge 1 ] && ok "zygote64 has lspd mapped ($ZY lines)" || bad "zygote64 missing lspd mapping"

say "== privilege-hiding module =="
OM=$(su_ 'lsmod | grep -c privhide')
[ "${OM:-0}" -ge 1 ] && ok "privhide.ko loaded" || say "  [note] privhide not loaded (may be by design)"
PK=$(sh_ 'pm path com.example.module')
[ -n "$PK" ] && ok "hook module installed: $PK" || bad "module apk missing"

say "== mdm / adb stability =="
AE=$(sh_ 'settings get global adb_enabled')
[ "$AE" = "1" ] && ok "adb_enabled=1" || bad "adb_enabled=$AE"

say
say "== $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
