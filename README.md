# chiron-bakasu-kernel

Xiaomi MIX 2 (chiron / msm8998) kernel **4.4.267-perf** with **BakaSU (ReSukiSU) v4.2.0-rc3** built-in, compiled **on the phone itself** (Alpine Linux chroot, clang 19.1.4, 8×Kryo).

## Releases / Downloads

Latest: **[v1.0-vibfix](https://github.com/vtnxpkv5t4-ctrl/chiron-bakasu-kernel/releases/tag/v1.0-vibfix)** — root works AND vibration works. Flash this one.

| Asset | Notes |
|---|---|
| `BakaSU-chiron-v2-vibfix.zip` | AnyKernel3 flashable zip — **tested on device**: boots, root works, vibration works |
| `manager.apk` | ReSukiSU v4.2.0-rc3 manager (versionCode 35171), matches the in-kernel version |

SHA256:

```
f260937eec2bde07332889ae6e062766eb82c192913d6095bf80b9224dfc0d45  BakaSU-chiron-v2-vibfix.zip
```

`Image.gz-dtb` inside the zip: sha256 `61a07930c3986e1bb1dddd5ccee4c4cd662baa713559ed02be9acbee1256a002`.

The earlier `BakaSU-chiron-4.4.267-AnyKernel3.zip` (first build) works for root but **breaks vibration** on MIUI — see below for why. Superseded by v2-vibfix.

## Kernel source

- Base: [sticpaper/chiron_kernel-11](https://github.com/sticpaper/chiron_kernel-11) branch `11` (LineageOS 18.1 / Android 11 base, kernel 4.4.267) — matches the on-device running kernel `4.4.253-gf895a32` lineage.
- KSU: [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) tag `v4.2.0-rc3`, commit `239e1e88`, version code `35171` (`30000 + 4471 + 700`), full name `v4.2.0-rc3-239e1e88@ReSukiSU`.

## Vibration fix (v2-vibfix) — the interesting part

First build booted fine and root worked, but **all vibration was dead** (no incoming-call vib, no haptics, no keyboard vib).

Root cause: chiron's vibrator is driven by the PMI8998 haptics driver `drivers/leds/leds-qpnp-haptics.c` (`CONFIG_LEDS_QPNP_HAPTICS=y`), which exposes a **led class device** `/sys/class/leds/vibrator/`. Stock MIUI 11 on msm8998 ships a **legacy `timed_output` vibrator HAL** — the Android VibratorService on this ROM only knows the old interface `/sys/devices/virtual/timed_output/vibrator/enable` and never touches the LED class device. So the hardware was fine; the interface the HAL expects was missing.

Fix: in `drivers/leds/leds-qpnp-haptics.c`, register a `timed_output_dev` named `vibrator` alongside the led class device, driving the same chip play path (`chip->play_time_ms` + `chip->state` + `schedule_work(&chip->haptics_work)`). Guarded with `IS_ENABLED(CONFIG_ANDROID_TIMED_OUTPUT)` (no-op stubs when off), plus proper `remove()` cleanup. Result: the legacy HAL finds `/sys/devices/virtual/timed_output/vibrator/` and vibration works — verified on device.

This mirrors what the stock MIUI 4.4 msm8998 kernel provides out of the box.

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
git apply vib-timed-output.patch   # vibration fix (see section above)
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
# 5. patches
git apply ksu-manual-hook.patch
git apply vib-timed-output.patch
# 6. build (see build.sh)
PATH=/usr/local/bin:$PATH make O=out ARCH=arm64 CC=clang \
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-alpine-linux-musl- \
  KCFLAGS="-Wno-error -Wno-unused-command-line-argument" -j8 Image.gz-dtb
```

`git config --system --add safe.directory '*'` is required — the BakaSU Kbuild shells out to `git` in a stripped env and dies on dubious-ownership otherwise.

Pack AnyKernel3: put `Image.gz-dtb` into an [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) tree with `anykernel.sh` (in this repo) — `BLOCK=/dev/block/bootdevice/by-name/boot`, `device.name1=chiron` — then `zip -r9`.

## Gotchas hit along the way

1. `COMPAT_VDSO` in defconfig demands `CROSS_COMPILE_ARM32`; stock kernel ships without it → disabled.
2. clang-19 `-Werror=strict-prototypes` on a 2016-era tree → `CONFIG_CC_WERROR` off + `KCFLAGS=-Wno-error`.
3. Two real prototype fixes needed: `usbhs_deinit()` (sound/soc/codecs/usb-headset.c) and `diag_ws_release()` (drivers/char/diag/diagchar_core.c) — applied in-tree, not in the patch (diag one only bites when DIAG is enabled).
4. BakaSU Kbuild refuses non-git trees ("You should use ReSukiSU as a git submodule") → tarball won't work, must clone.
5. First build attempt silently kept a stale `auto.conf` with `COMPAT_VDSO=y` → `rm -rf out` before rebuild.
6. **Vibration dead after first flash** — not a hardware fault: led-class `vibrator` exists but the MIUI HAL wants `timed_output` → `vib-timed-output.patch`. Symptom: no `/sys/devices/virtual/timed_output/vibrator` node after boot.

## Flash & rollback

1. **Back up boot in TWRP first.**
2. Flash `BakaSU-chiron-v2-vibfix.zip`.
3. Reboot, install `manager.apk` — root should show immediately.
4. Check vibration: incoming call / keyboard haptic (v2-vibfix: works).
5. Bootloop? Restore the boot backup in TWRP, done.

## Test status (on-device, 2026-11-06)

| Build | Boot | Root | Vibration |
|---|---|---|---|
| v1 `BakaSU-chiron-4.4.267-AnyKernel3.zip` | ✅ | ✅ | ❌ |
| v2 `BakaSU-chiron-v2-vibfix.zip` | ✅ | ✅ | ✅ |
