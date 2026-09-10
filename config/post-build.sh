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

# Menu (boot) core for the rootfs, fetched from the release directory of the
# Menu_MiSTer_ch96 GitHub repo. The newest menu_ch96_<YYYYMMDD>.rbf is picked
# automatically; override the URL with MENU_RBF_URL if needed.
: "${MENU_RBF_URL:=$(curl -fsSL \
    "https://api.github.com/repos/teiram/Menu_MiSTer_ch96/contents/releases" \
    | sed -n 's/.*"download_url": "\(.*menu_ch96_[0-9]\{8\}\.rbf\)".*/\1/p' \
    | tail -1)}"
[ -n "$MENU_RBF_URL" ] || { echo "ERROR: could not locate Menu_MiSTer RBF" >&2; exit 1; }
echo "== Fetching Menu_MiSTer RBF: $MENU_RBF_URL"
curl -fsSL "$MENU_RBF_URL" -o "$TARGET_DIR/media/fat/menu.rbf"

# Main_MiSTer runs OSD scripts on a framebuffer console (fb_terminal=1) by
# fork/exec'ing a login program with an absolute path:
#
#   execl("/sbin/agetty", "/sbin/agetty", "-a", "root", "-l", "/tmp/script",
#         "--nohostname", "-L", "tty2", "linux", NULL);
#
# buildroot's util-linux installs agetty under $exec_prefix, which is
# /usr/sbin on a rootfs without merged /usr -- so the path MiSTer asks for may
# not exist, and the failure is silent: the console comes up empty and the
# script never runs. Make sure the name resolves, wherever agetty landed.
if [ ! -e "$TARGET_DIR/sbin/agetty" ] && [ -e "$TARGET_DIR/usr/sbin/agetty" ]; then
    echo "== Linking /sbin/agetty -> ../usr/sbin/agetty (Main_MiSTer execl's that path)"
    mkdir -p "$TARGET_DIR/sbin"
    ln -sf ../usr/sbin/agetty "$TARGET_DIR/sbin/agetty"
fi

mkdir -p "$TARGET_DIR/usr/lib"
for lib in lib/imlib2/libImlib2.so \
           lib/imlib2/libfreetype.so \
           lib/imlib2/libpng16.so \
           lib/imlib2/libz.so \
           lib/imlib2/libbz2.so \
           lib/bluetooth/libbluetooth.so; do
    install -m 755 "$MISTER_SRC/$lib" "$TARGET_DIR/usr/lib/"
done