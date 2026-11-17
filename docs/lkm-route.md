# LKM route: the only zero-risk path

## Why not a full kernel image

`docs/published-tree-gaps.md` shows the published tree is missing the vendor FocalTech/Goodix
touchscreen drivers and `CONFIG_IFLYTEK_HARDWARE_CHECK`. A full image built from it would boot
with a dead touchscreen and there is no A/B slot to fall back to.

## What the LKM route does

Build `kernelsu.ko` against the device's own kernel ABI and `insmod` it. The kernel image is
never touched, so touch, charging and hardware checks keep working regardless.

Required properties, all already true on this device:

| Need | Device | Note |
|---|---|---|
| `CONFIG_MODULES` | y | out-of-tree modules already work (`privhide.ko`) |
| `CONFIG_MODVERSIONS` | y | `Module.symvers` must match the device ABI |
| `CONFIG_MODULE_SIG` | n | unsigned modules load |
| `CONFIG_KALLSYMS_ALL` | y | symbol resolution at runtime |
| `kallsyms_lookup_name` | exported | confirmed present in device kallsyms |
| `sys_call_table` | present | `R sys_call_table` in device kallsyms |
| `CONFIG_KPROBES` | **n** | not needed — we use the syscall-table path |

## KernelSU branch choice

`backslashxx/KernelSU` master (`KSU_VERSION=32731`) is the non-GKI line:

- `kernel/Kconfig` states *"Verified on 3.10 ~ 7.1. Recommended for 4.14+."*
- `obj-$(CONFIG_KSU) := kernelsu.o` — builds as a module (`CONFIG_KSU=m`)
- `KSU_TAMPER_SYSCALL_TABLE` replaces `sys_reboot`, `sys_execve`, `sys_newfstatat`,
  `sys_faccessat` without needing kprobes
- `kernel/downstream/arm64_syscall_table_mirror.h` takes a *mirror* approach: it copies
  `sys_call_table` into a module-owned page and patches the `adrp` instructions at the call
  sites, so it does not need `set_memory_rw()` on the real `.rodata` table

That last point matters: the private `onesoft_hide.ko` already proved `__change_memory_common`
works on this kernel, but the mirror approach avoids that entirely and is less fragile.

## Build notes (4.14 tree quirks hit along the way)

1. `HOSTCFLAGS` is overwritten with `:=` inside kbuild, so `-fcommon` **must** be on the make
   command line or `scripts/dtc` fails with `multiple definition of 'yylloc'`.
2. This vendor Makefile has **no rule for `include/generated/compile.h`** — only a comment
   referencing it. `modules_prepare` therefore never creates it, while KernelSU's
   `kernel_includes.h:39` includes it unconditionally. Generate it by hand:
   ```sh
   sh scripts/mkcompile_h include/generated/compile.h arm64 1 1 "$CROSS_COMPILE"gcc
   ```
   The arguments are positional: `TARGET ARCH SMP PREEMPT CC`.
3. `Module.symvers` comes only from a `vmlinux` link, not from `modules_prepare`. Without it
   kbuild warns *"Symbol version dump ./Module.symvers is missing; modules will have no
   dependencies and modversions"* and the resulting `.ko` has an empty `__versions` — which
   happens to still load on this device (verified before with `privhide.ko`), but a correct
   `__versions` is preferable.
