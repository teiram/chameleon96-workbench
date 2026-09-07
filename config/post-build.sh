#!/bin/sh
# Buildroot post-build script.
# Builds Main_MiSTer for the Chameleon96 and installs it, with its runtime
# shared libs, into the target root filesystem ($1).
#
# Self-contained: the Main_MiSTer sources are cloned from GitHub into
# $ROOT/build/Main_MiSTer on the first run, and the binary is built with the
# buildroot host toolchain (arm-ch96-linux-gnueabihf-, already on PATH). To
# reuse a toolchain generated once via `make sdk`, point CROSS_COMPILE at its
# bin prefix, e.g.:
#   CROSS_COMPILE=/path/to/sdk/bin/arm-ch96-linux-gnueabihf
set -e

TARGET_DIR=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MISTER_SRC="$ROOT/build/Main_MiSTer"
MISTER_UPSTREAM="https://github.com/teiram/Main_MiSTer_ch96"

if [ ! -d "$MISTER_SRC/.git" ]; then
    echo "== Cloning Main_MiSTer from $MISTER_UPSTREAM"
    mkdir -p "$(dirname "$MISTER_SRC")"
    git clone --depth 1 "$MISTER_UPSTREAM" "$MISTER_SRC"
fi

# Toolchain selection: buildroot host cross-compiler by default, or a
# user-supplied SDK toolchain when CROSS_COMPILE is defined.
if [ -n "$CROSS_COMPILE" ]; then
    case "$CROSS_COMPILE" in
        *-) PREFIX="$CROSS_COMPILE" ;;
        *)  PREFIX="$CROSS_COMPILE-" ;;
    esac
else
    PREFIX="arm-ch96-linux-gnueabihf"
fi

make -C "$MISTER_SRC" clean
make -C "$MISTER_SRC" CC="$PREFIX-gcc" LD="$PREFIX-ld" STRIP="$PREFIX-strip"

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