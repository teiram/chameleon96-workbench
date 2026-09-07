#!/bin/sh
# Build all Chameleon96/MiSTer artifacts with buildroot:
#   - SPL + U-Boot:   build/images/u-boot-with-spl.sfp  (A2 partition)
#   - kernel:         build/images/zImage + socfpga_cyclone5_chameleon96.dtb
#   - boot set (FAT): build/images/{u-boot.scr,Menu_MiSTer.rbf,extlinux/...}
#   - rootfs:         build/images/rootfs.tar (with Main_MiSTer + minimal RBFs)
#
# The kernel/u-boot sources are cloned from GitHub by buildroot.
# The Main_MiSTer binary is built by the buildroot host toolchain
# (or a user-supplied CROSS_COMPILE toolchain).
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)

# Download cache. Override with BR2_DL_DIR=/some/path to reuse a cache.
DL_DIR="${BR2_DL_DIR:-$ROOT/buildroot/dl}"

echo "== Buildroot config (O=$ROOT/build, dl=$DL_DIR)"
make -C "$ROOT/buildroot" O="$ROOT/build" defconfig \
    BR2_DEFCONFIG="$ROOT/config/chameleon96_config" \
    BR2_DL_DIR="$DL_DIR"

echo "== Buildroot build"
make -C "$ROOT/buildroot" O="$ROOT/build" BR2_DL_DIR="$DL_DIR"

echo
echo "== Artifacts in $ROOT/build/images"
ls -la "$ROOT/build/images"
