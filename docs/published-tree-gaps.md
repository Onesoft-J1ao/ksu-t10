# Gaps in the published kernel tree

Measured by diffing the device's live `/proc/config.gz` (121,189 kallsyms entries) against
`iflytek/Kernel_OpenSource` @ `android_9_kernel_UD710_T10` (`04c31197`).

The device kernel is `4.14.98-g3ff394f6011d-dirty` and the published tree is the same commit
without the `-dirty` local changes. Those uncommitted changes carry vendor code the public
branch never received.

## Four config symbols are set on the device but declared nowhere in the tree

| Symbol | Device | Kconfig definition in tree | Verdict |
|---|---|---|---|
| `CONFIG_IFLYTEK_CHARGER_MANAGER` | `=y` | 0 | **fixable** — driver source present, only the declaration is missing |
| `CONFIG_IFLYTEK_HARDWARE_CHECK` | `=y` | 0 | harmless to drop — only sets flags like `g_lcd_hardware_check_flag` |
| `CONFIG_TOUCHSCREEN_ADAPTIVE` | `=y` | 0 | **blocking** — driver source absent |
| `CONFIG_TOUCHSCREEN_ADAPTIVE_VENDOR_FOCALTECH` | `=y` | 0 | **blocking** — driver source absent |

### Evidence for the charger one

`sc2703-charger.c` calls `cm_notify_event()`; that symbol is `EXPORT_SYMBOL_GPL` from
`charger-manager.c`, which is gated on `CONFIG_CHARGER_MANAGER`.

With the vendor symbol dropped by `olddefconfig`:

```
CONFIG_CHARGER_SC2703=y            <- still builds sc2703-charger.o
# CONFIG_CHARGER_MANAGER is not set <- charger-manager.o never built
```

→ link error `undefined reference to cm_notify_event`. `patches/0001-*` fixes this.

The device's own kallsyms confirms the vendor kernel *did* compile it:

```
cm_batt_works  cm_list  cm_manager_adjust_current  cm_monitor  cm_notify_event
cm_suspend_complete  cm_suspend_noirq  cm_suspend_prepare  cm_timer  cm_wq
```

### Evidence for the touchscreen ones

The device kernel exports a full FocalTech + Goodix stack:

```
focaltech_match  focaltech_fetch  focaltech_upgrade_firmware  focaltech_handle_event
goodix_i2c_probe  goodix_i2c_read  goodix_i2c_write  goodix_bus_init  ...
```

The published tree contains **none** of it — `drivers/input/touchscreen/` only has
`edt-ft5x06.c` and the standard upstream drivers. Declaring the Kconfig symbol would not
produce the driver.

## Consequence

**A self-built full kernel image from the public tree is not viable.** It would boot with no
touch input. Anyone who flashes it must accept a dead touchscreen, and there is no A/B slot to
fall back to — only the `boot` partition image in `../boot-backup/`.

That is why the project pivoted to the **LKM route**: build `kernelsu.ko` against the device's
own kernel ABI and `insmod` it, leaving the kernel image untouched.
