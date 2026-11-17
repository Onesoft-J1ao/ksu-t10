# ksu-t10

KernelSU on an ARM64 Android 9 tablet (Spreadtrum UD710, Linux 4.14.98), coexisting with the
existing Magisk + LSPosed module stack.

## Hardware / OS facts (measured, not assumed)

| Item | Value | How verified |
|---|---|---|
| Model | UD710 tablet (vendor build `user`, release-keys) | `getprop ro.product.model` |
| Android | 9 (PPR1.180610.011), build type `user`, `release-keys` | `getprop ro.build.*` |
| Kernel | `4.14.98-g3ff394f6011d-dirty`, gcc 4.9.x, SMP PREEMPT | `/proc/version` |
| Boot layout | **AOSP boot header v1**, `page_size=2048` | parsed `boot.img` |
| kernel segment | 18,249,736 B (17.40 MB) | boot header |
| ramdisk segment | 10,602,267 B (10.11 MB) — **exists** | boot header |
| Partitions | A-only: `boot=sda36` (35 MB), `dtbo=sda38`, `vbmeta=sda43`, `system=sda39` | `/dev/block/by-name` |
| Slots | none (`ro.boot.slot_suffix` empty, `ro.build.ab_update` empty) | `getprop` |
| system-as-root | yes, `/dev/root` is sda39, `/init` is the real init | `/proc/mounts`, `ls -l /init` |
| Bootloader | `verifiedbootstate=orange`, `flash.locked=0` | `/proc/cmdline` |
| SELinux | **Permissive** (`enforce=0`) | `getenforce` |

### Magisk injection point — confirmed ramdisk, not vendor_boot

`magiskboot`-style analysis of `boot.img`'s ramdisk shows it has already been patched by Magisk:

```
040000        0  .backup
100000      122  .backup/.magisk          <- Magisk's stock-boot fingerprint
100750   199960  init                     <- replaced by magiskinit
040750        0  overlay.d/sbin
100644     1556  overlay.d/sbin/init-ld.xz
100644   158792  overlay.d/sbin/magisk.xz
100644 10327500  overlay.d/sbin/stub.xz
```

Runtime corroboration: `magisk --path` returns `/sbin`, and `/sbin` is a
`magisk` tmpfs mount. There is **no vendor_boot and no init_boot partition** on this device, so
this is the classic boot.img-ramdisk flavour of Magisk.

Stock boot backup: `../boot-backup/boot.img`, verified against the live partition —
`sda36` full SHA256 = `b41b0d13f53150f64c528bde3ba97db47c8ab1b8b51988512543de4950610745`,
identical to the backup. `image` was 36,700,160 B.

## Why the config work is safe

Existing out-of-tree modules (`../kernel/module/priv_*.ko`) carry
`vermagic: 4.14.98-g3ff394f6011d-dirty SMP preempt mod_unload modversions aarch64`
and a `__versions` section keyed on `module_layout` = `0x9cb4ffaa`.

`module_layout`'s CRC is derived from `struct module` in `include/linux/module.h`. Its
conditional fields are gated on:

`CONFIG_CFI_CLANG`, `CONFIG_SYSFS`, `CONFIG_UNUSED_SYMBOLS`, `CONFIG_MODULE_SIG`,
`CONFIG_GENERIC_BUG`, `CONFIG_KALLSYMS`, `CONFIG_SMP`, `CONFIG_TRACEPOINTS`,
`CONFIG_EVENT_TRACING`, `CONFIG_FTRACE_MCOUNT_RECORD`, `CONFIG_LIVEPATCH`, `CONFIG_MODULE_UNLOAD`.

**`CONFIG_OVERLAY_FS` and `CONFIG_KPROBES` do not appear in that list** — verified by grepping
`struct module` directly. So enabling them cannot change the ABI. Measured config diffs:

* `CONFIG_OVERLAY_FS=y` → adds only `OVERLAY_FS`, `EXPORTFS`, and two `_not set` overlay sub-options.
* `CONFIG_KPROBES=y` + `KPROBE_EVENTS=y` → adds `KPROBES`, `KPROBE_EVENTS`, `KRETPROBES`,
  `PROBE_EVENTS`, `BPF_EVENTS`, `NET_TCPPROBE`.

The one config that *would* break everything is `CONFIG_FUNCTION_TRACER=y`, because it drags in
`CONFIG_FTRACE_MCOUNT_RECORD`, which adds `num_ftrace_callsites` / `ftrace_callsites` to
`struct module`. `tools/build-kernel.sh` hard-fails if that turns up in the resolved config.

## Design: Magisk and KSU coexist by staying in different layers

```
boot.img (sda36)
├── kernel  segment   <- rebuilt: KSU hooks + OVERLAY_FS + KPROBES
└── ramdisk segment   <- untouched, byte-for-byte: magiskinit + overlay.d/sbin/*.xz
```

* Magisk owns the ramdisk. Never regenerate it — `tools/repack-boot.sh` copies the existing
  ramdisk verbatim and only swaps the `kernel` file before `magiskboot repack`.
* KSU owns the kernel. It gets `KSU_MODULE_DIR="/data/adb/ksu/modules"` so it does not fight
  Magisk over `/data/adb/modules`.
* Both need `CONFIG_MODULES` + `CONFIG_MODVERSIONS` (already on) and neither cares about the
  other's module format.

## Staged rollout

Each stage is built, verified on-device, and only then followed by the next. Stock boot.img is
always the rollback.

* **Stage 1 — `overlay`**: add `CONFIG_OVERLAY_FS=y`. Expect: Magisk, LSPosed and the module stack all
  unchanged; `privhide.ko` still `insmod`s.
* **Stage 2 — `kprobes`**: add `CONFIG_KPROBES=y` + `CONFIG_KPROBE_EVENTS=y`. Same expectation.
* **Stage 3 — `ksu`**: merge the KSU 4.14 branch, adapt the three 5.x-only APIs
  (see below), build, flash, install KSU Manager.

### KSU 4.14 API adaptations required

Measured against this tree:

| KSU expects (5.x) | This 4.14 tree actually has | Action |
|---|---|---|
| `do_faccessat()` | `SYSCALL_DEFINE3(faccessat, ...)` @ `fs/open.c:362` | hook `sys_faccessat` |
| `__do_sys_reboot()` | `SYSCALL_DEFINE4(reboot, ...)` @ `kernel/reboot.c:280` | hook `sys_reboot` |
| `security_bprm_creds()` | `security_bprm_set_creds()` @ `security/security.c:332` | rename at hook site |
| `do_execveat_common()` | present @ `fs/exec.c:1694` | unchanged |
| `vfs_read()` / `vfs_getattr()` / `path_openat()` | `fs/read_write.c:432` / `fs/stat.c:108` / `fs/namei.c:3574` | unchanged |
| `security_hook_heads` | `security/security.c:38`, `include/linux/lsm_hooks.h` | unchanged |

kprobe framework sources (`kernel/kprobes.c`, `include/linux/kprobes.h`) are present in-tree;
only the config switch was off.

## Usage

```bash
# Stage 1 build (out-of-tree; ~/kernel_t10 is never written to)
tools/build-kernel.sh overlay

# Repack, keeping the Magisk ramdisk verbatim
tools/repack-boot.sh ../boot-backup/boot.img out/overlay/arch/arm64/boot/Image out/boot-overlay.img
```

Then flash `out/boot-overlay.img` to `boot` (sda36) and verify Magisk / LSPosed / the module stack.

## Layout

```
configs/t10-device.config   device /proc/config.gz mirror (baseline, unmodified)
tools/build-kernel.sh       out-of-tree kernel build, staged configs
tools/repack-boot.sh        swap kernel segment, preserve ramdisk
out/<stage>/                Image, .config, build.log
docs/                       notes and verification records
```
