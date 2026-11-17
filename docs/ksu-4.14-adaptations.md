# KSU on 4.14.98 — API adaptation notes

Everything here was read out of `~/kernel_t10_build` (a clean unpack of the vendor
tarball, same tree the device kernel was built from). Line numbers are from that tree.

## Why adaptation is needed

KernelSU's upstream tree targets 5.x+. On 4.14 a handful of the symbols it hooks either do not
exist or have different names. KSU ships a `kernel-4.14` branch for exactly this, but it is
maintained far behind trunk, so the deltas below are what to expect when merging.

## Measured deltas

### 1. execve — compatible, no change

```c
// fs/exec.c:1694
static int do_execveat_common(int fd, struct filename *filename,
                              struct user_arg_ptr argv,
                              struct user_arg_ptr envp,
                              int flags)
```

Callers: `fs/exec.c:1847, 1858, 1874, 1890`. KSU's `ksu_handle_execveat()` signature matches
this shape, so the hook drops in unmodified.

### 2. faccessat — hook the syscall wrapper instead

There is no `do_faccessat()` in 4.14. What exists:

```c
// fs/open.c:362
SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
```

and `sys_faccessat()` at `fs/open.c:442` is used by `sys_access()`.

**Adaptation:** point the KSU hook at `sys_faccessat` rather than `do_faccessat`. The argument
list is `(int dfd, const char __user *filename, int mode)`.

### 3. reboot — hook the syscall wrapper

There is no `__do_sys_reboot()`.

```c
// kernel/reboot.c:280
SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
                void __user *, arg)
```

**Adaptation:** hook `sys_reboot` and reproduce KSU's magic-number gate inline, because the
capability check (`ns_capable(pid_ns->user_ns, CAP_SYS_BOOT)`) sits above the magic check and
KSU's "allow reboot for a specific uid" shortcut has to be inserted before it.

### 4. bprm creds — renamed

| KSU expects | 4.14 has |
|---|---|
| `security_bprm_creds()` | `security_bprm_set_creds()` — `security/security.c:332` |
| — | `security_bprm_committing_creds()` — `security/security.c:347` |

**Adaptation:** rename at the hook site. `committing_creds` exists under both names' semantics,
so KSU's `ksu_handle_bprm_creds` maps onto `security_bprm_set_creds`.

### 5. file read / stat / open — compatible

```c
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)  // fs/read_write.c:432
int vfs_getattr(const struct path *path, struct kstat *stat,
                u32 request_mask, unsigned int query_flags)                        // fs/stat.c:108
static struct file *path_openat(struct nameidata *nd, ...)                         // fs/namei.c:3574
```

All present with 4.14-era signatures. `vfs_getattr` already carries
`request_mask`/`query_flags`, which is the newer form — good, no backport needed there.

### 6. LSM — available

`struct security_hook_heads security_hook_heads` at `security/security.c:38`,
`include/linux/lsm_hooks.h` (89 KB) present. KSU's SELinux handling needs this to iterate the
hook list; it compiles as-is. Note the device runs **Permissive**, so
`ksu_handle_selinux()` is effectively a no-op here.

## Config prerequisites (all measured)

| Config | Baseline | KSU needs | Note |
|---|---|---|---|
| `CONFIG_KPROBES` | **n** | y | framework source already in tree (`kernel/kprobes.c`) |
| `CONFIG_KPROBE_EVENTS` | **n** | y | pulls `KRETPROBES`, `PROBE_EVENTS`, `BPF_EVENTS` |
| `CONFIG_OVERLAY_FS` | **n** | y | `fs/overlayfs` already in tree |
| `CONFIG_KALLSYMS_ALL` | y | y | ok |
| `CONFIG_MODULES` / `MODVERSIONS` | y / y | y | ok, and must stay so existing `.ko` load |
| `CONFIG_MODULE_SIG` | n | — | ok, unsigned modules load |
| `CONFIG_FUNCTION_TRACER` | **n** | optional | **keep off**: turning it on pulls `FTRACE_MCOUNT_RECORD`, which changes `struct module` and breaks every existing `.ko` |

## Module directory split

Magisk owns `/data/adb/modules`. KSU must be built with

```
KSU_MODULE_DIR="/data/adb/ksu/modules"
```

so `privhide-module` and `boot-guard` are not loaded twice (once by each manager's
boot script), which would double-`insmod` `privhide.ko` and race on the syscall table.
