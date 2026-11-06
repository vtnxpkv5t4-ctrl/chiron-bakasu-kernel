#!/bin/sh
export PATH=/usr/local/bin:$PATH
cd /root/kernel_src
make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-alpine-linux-musl- KCFLAGS="-Wno-error -Wno-unused-command-line-argument" -j8 Image.gz-dtb > /root/build.log 2>&1
echo BUILD_EXIT=$? >> /root/build.log
