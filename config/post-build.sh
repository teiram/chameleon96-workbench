#!/bin/sh
# Buildroot post-build script.
# Builds Main_MiSTer for the Chameleon96 and installs it, with its runtime
# shared libs, into the target root filesystem ($1).
#
# Self-contained: the Main_MiSTer sources are cloned from GitHub into
# $ROOT/build/Main_MiSTer on the first run, so no local checkout is needed.
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