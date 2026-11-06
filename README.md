# chiron-bakasu-kernel

Xiaomi MIX 2 (chiron / msm8998) kernel **4.4.267-perf** with **BakaSU (ReSukiSU) v4.2.0-rc3** built-in, compiled **on the phone itself** (Alpine Linux chroot, clang 19.1.4, 8×Kryo).

## Artifacts (built 2026-11-06)

| File | Notes |
|---|---|
| `Image.gz-dtb` | 13.7 MB, sha256 `4bdf1f07844ae4d2748e73525c6b640fb6260e70fd6916a7fa115896adf99d83`, md5 `c6672b6df7affba7cea4ddd215dc5c6e` |
| `BakaSU-chiron-4.4.267-AnyKernel3.zip` | flash in TWRP, writes to `/dev/block/bootdevice/by-name/boot` |
| `ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk` | manager, matches in-kernel version code 35171 |

Binaries are kept in the phone storage (`/sdcard/BakaSU_build/`) — GitHub contents API can't carry 16 MB binaries in one JSON PUT.

## Kernel source

- Base: [sticpaper/chiron_kernel-11](https://github.com/sticpaper/chiron_kernel-11) branch `11` (LineageOS 18.1 / Android 11 base, kernel 4.4.267) — matches the on-device running kernel `4.4.253-gf895a32` lineage.
- KSU: [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) tag `v4.2.0-rc3`, commit `239e1e88`, version code `35171` (`30000 + 4471 + 700`), full name `v4.2.0-rc3-239e1e88@ReSukiSU`.

## Hook mode: MANUAL (the only correct one for 4.4 non-GKI)

BakaSU v4.2 supports three hook modes; `tracepoint` is GKI-2.0-only, `susfs inline` needs susfs, so **manual hook** it is. `CONFIG_KSU_MANUAL_HOOK_AUTO_*` are left on (4.4 < 6.8, so LSM auto-hooks for setuid/initrc/input are allowed), which means only 4 source files need stubs:

| File | Hook |
|---|---|
| `fs/exec.c` | `ksu_handle_execveat()` at `do_execveat_common()` entry |
| `fs/open.c` | `ksu_handle_faccessat()` at `SYSCALL_DEFINE3(faccessat)` entry |
| `fs/stat.c` | `ksu_handle_stat()` in `newfstatat` + `_ret` hooks in `newfstat` / `fstat64` |
| `kernel/reboot.c` | `ksu_handle_sys_reboot()` — short-circuits when magic1 == 0xDEADBEEF |

All stubs are declared in `include/linux/ksu_hook.h` (inline no-ops when `CONFIG_KSU=n`), so the diff is self-contained and safe.

Apply with:

```sh
cd chiron_kernel-11
git apply ksu-manual-hook.patch
```

## Reproduce the build

```sh
# 1. kernel source
curl -L -o k.tar.gz https://codeload.github.com/sticpaper/chiron_kernel-11/tar.gz/refs/heads/11
tar xzf k.tar.gz && mv chiron_kernel-11-11 kernel_src
# 2. BakaSU must be a git clone (its Kbuild reads git metadata for versioning)
git clone --filter=blob:none --branch v4.2.0-rc3 --single-branch https://github.com/Baka-SU/BakaSU bakasu
ln -s ../../bakasu/kernel kernel_src/drivers/kernelsu
# 3. wire into drivers tree
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> kernel_src/drivers/Makefile
sed -i 's/endmenu/source "drivers\/kernelsu\/Kconfig"\nendmenu/' kernel_src/drivers/Kconfig
# 4. config
make O=out ARCH=arm64 chiron_defconfig
cat ksu.fragment >> out/.config
make O=out ARCH=arm64 olddefconfig
# 5. build (see build.sh)
PATH=/usr/local/bin:$PATH make O=out ARCH=arm64 CC=clang \
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-alpine-linux-musl- \
  KCFLAGS="-Wno-error -Wno-unused-command-line-argument" -j8 Image.gz-dtb
```

`git config --system --add safe.directory '*'` is required — the BakaSU Kbuild shells out to `git` in a stripped env and dies on dubious-ownership otherwise.

## Gotchas hit along the way

1. `COMPAT_VDSO` in defconfig demands `CROSS_COMPILE_ARM32`; stock kernel ships without it → disabled.
2. clang-19 `-Werror=strict-prototypes` on a 2016-era tree → `CONFIG_CC_WERROR` off + `KCFLAGS=-Wno-error`.
3. Two real prototype fixes needed: `usbhs_deinit()` (sound/soc/codecs/usb-headset.c) and `diag_ws_release()` (drivers/char/diag/diagchar_core.c) — applied in-tree, not in the patch (diag one only bites when DIAG is enabled).
4. BakaSU Kbuild refuses non-git trees ("You should use ReSukiSU as a git submodule") → tarball won't work, must clone.
5. First build attempt silently kept a stale `auto.conf` with `COMPAT_VDSO=y` → `rm -rf out` before rebuild.

## Flash & rollback

1. **Back up boot in TWRP first.**
2. Flash the AnyKernel3 zip.
3. Reboot, install the manager APK — root should show immediately.
4. Bootloop? Restore the boot backup in TWRP, done.

Status: kernel built and boot-tested (see below). Nothing else changed vs the running stock-equivalent kernel except KSU + the two prototype fixes.
