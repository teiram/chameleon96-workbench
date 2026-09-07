#!/bin/sh
# Buildroot post-build script.
# Builds Main_MiSTer for the Chameleon96 and installs it, with its runtime
# shared libs, into the target root filesystem ($1).
#
# Uses the proven gcc-arm-10.2 hard-float toolchain (arm-none-linux-gnueabihf)
# rather than the buildroot SDK one - it already produces a working MiSTer
# binary and links against the hard-float glibc of this rootfs.
set -e

TARGET_DIR=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MISTER_SRC="$ROOT/Main_MiSTer"
TOOLCHAIN_BIN="$ROOT/toolchains/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin"

export PATH="$TOOLCHAIN_BIN:$PATH"

make -C "$MISTER_SRC" clean
make -C "$MISTER_SRC"

mkdir -p "$TARGET_DIR/media/fat"
install -D -m 755 "$MISTER_SRC/bin/MiSTer" "$TARGET_DIR/media/fat/MiSTer"

mkdir -p "$TARGET_DIR/usr/lib"
for lib in lib/imlib2/libImlib2.so \
           lib/imlib2/libfreetype.so \
           lib/imlib2/libpng16.so \
           lib/imlib2/libz.so \
           lib/imlib2/libbz2.so \
           lib/bluetooth/libbluetooth.so; do
    install -m 755 "$MISTER_SRC/$lib" "$TARGET_DIR/usr/lib/"
done
