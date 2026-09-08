#!/bin/sh
# Resize / re-assemble the SD card image (build/images/sdcard.img) produced
# by build.sh.
#
#   ./sd-resize.sh <sd-size> [--merge <dir>] [--overwrite]
#
# <sd-size> is the full size of the target SD card (binary units, e.g. 512M,
# 1G, case-insensitive), or the keyword 'default' to restore the canonical
# size (the BR2_TARGET_ROOTFS_EXT2_SIZE rootfs plus the a2/boot partitions).
# The a2 (10M at 1M) and boot (100M at 12M) partitions occupy the first 112M
# of the card, so the rootfs (ext4) partition is sized as <sd-size> - 112M.
# The card must be larger than 112M.
#
# Options:
#   --merge <dir>   merge the given tree into the rootfs before assembling
#   --overwrite     with --merge, replace existing rootfs files (by default
#                   only new files are added)
#
# Requires a prior ./build.sh (uses its host tools: genimage, resize2fs,
# e2fsck). Rootfs is the last partition, so growing/shrinking it does not
# shift the other partitions.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="$ROOT/build/images"
TARGET="$ROOT/build/target"
GENIMAGE="$ROOT/build/host/bin/genimage"
RESIZE2FS="$ROOT/build/host/sbin/resize2fs"
E2FSCK="$ROOT/build/host/sbin/e2fsck"
DL_DIR="${BR2_DL_DIR:-$ROOT/buildroot/dl}"

usage() {
    echo "Usage: $0 <sd-size> [--merge <dir>] [--overwrite]" >&2
    echo "  <sd-size>   full SD card size (binary units, e.g. 512M, 1G)" >&2
    echo "  <sd-size>   or 'default' to restore the canonical size" >&2
    echo "  --merge     merge a tree into the rootfs before assembling" >&2
    echo "  --overwrite replace existing rootfs files when merging" >&2
    exit 1
}

[ "$#" -ge 1 ] || usage

SIZE_ARG=$1
shift
MERGE_DIR=
OVERWRITE=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --merge)
            [ "$#" -ge 2 ] || usage
            MERGE_DIR=$2
            shift 2
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        *)
            echo "$0: unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [ "$SIZE_ARG" = "default" ]; then
    # Canonical card size: the configured rootfs size plus the 112M taken by
    # the a2 and boot partitions.
    DEFAULT_ROOTFS=$(sed -n 's/^BR2_TARGET_ROOTFS_EXT2_SIZE="\([0-9][0-9]*\)M"$/\1/p' \
        "$ROOT/config/chameleon96_config")
    if [ -z "$DEFAULT_ROOTFS" ]; then
        echo "Error: cannot read BR2_TARGET_ROOTFS_EXT2_SIZE from config/chameleon96_config." >&2
        exit 1
    fi
    TOTAL_MIB=$(( DEFAULT_ROOTFS + 112 ))
    SIZE_ARG="${TOTAL_MIB}M"
else
    if ! printf '%s' "$SIZE_ARG" | grep -qE '^[0-9]+[kKmMgG]$'; then
        echo "$0: invalid size: $SIZE_ARG" >&2
        usage
    fi

    SIZE_VAL=$(printf '%s' "${SIZE_ARG%?}")
    SIZE_UNIT=$(printf '%s' "${SIZE_ARG##*[0-9]}")
    case "$SIZE_UNIT" in
        k|K) TOTAL_MIB=$(( SIZE_VAL / 1024 )) ;;
        m|M) TOTAL_MIB=$SIZE_VAL ;;
        g|G) TOTAL_MIB=$(( SIZE_VAL * 1024 )) ;;
    esac
fi

# The a2 (10M at 1M) and boot (100M at 12M) partitions take the first 112M.
if [ "$TOTAL_MIB" -le 112 ]; then
    echo "Error: SD card size must be larger than 112M (got $SIZE_ARG)." >&2
    echo "The a2 and boot partitions occupy the first 112M of the card," >&2
    echo "leaving <sd-size> - 112M for the rootfs." >&2
    exit 1
fi
ROOTFS_MIB=$(( TOTAL_MIB - 112 ))
ROOTFS_SIZE="${ROOTFS_MIB}M"

if [ ! -f "$BIN/rootfs.ext4" ] || [ ! -x "$GENIMAGE" ] \
    || [ ! -x "$RESIZE2FS" ] || [ ! -x "$E2FSCK" ]; then
    echo "Error: run ./build.sh first (missing build artifacts or host tools)." >&2
    exit 1
fi

if [ -n "$MERGE_DIR" ]; then
    if [ ! -d "$MERGE_DIR" ]; then
        echo "Error: merge directory not found: $MERGE_DIR" >&2
        exit 1
    fi
    echo "== Merging $MERGE_DIR into the rootfs"
    if [ -n "$OVERWRITE" ]; then
        cp -a "$MERGE_DIR"/. "$TARGET"/
    else
        cp -a -n "$MERGE_DIR"/. "$TARGET"/
    fi
    echo "== Regenerating the rootfs images"
    make -C "$ROOT/buildroot" O="$ROOT/build" BR2_DL_DIR="$DL_DIR" rootfs-ext2
fi

# Resize the rootfs filesystem image to its new partition size.
ROOTFS_FILE=$(readlink -f "$BIN/rootfs.ext4")
echo "== Resizing rootfs to $ROOTFS_SIZE"
"$E2FSCK" -fy "$ROOTFS_FILE" >/dev/null
"$RESIZE2FS" "$ROOTFS_FILE" "$ROOTFS_SIZE" >/dev/null

# Re-assemble sdcard.img with the resized rootfs partition. Only the size of
# the rootfs partition changes; the a2/boot offsets stay put.
TMPCFG="$ROOT/build/sd-resize.cfg"
mkdir -p "$ROOT/build/genimage.tmp"
ROOTPATH_TMP=$(mktemp -d)
trap 'rm -rf "$TMPCFG" "$ROOT/build/genimage.tmp" "$ROOTPATH_TMP"' EXIT

awk -v new_size="$ROOTFS_SIZE" '
    in_block == "" && $1 == "partition" && $2 == "rootfs" { in_block = 1 }
    in_block && $1 == "}" { in_block = "" }
    in_block && $1 == "size" {
        print "\tsize = " new_size
        next
    }
    { print }
' "$ROOT/config/genimage.cfg" > "$TMPCFG"

echo "== Assembling sdcard.img"
# --rootpath must be an empty dir (genimage copies it into its tmp work dir).
"$GENIMAGE" --rootpath "$ROOTPATH_TMP" \
    --config "$TMPCFG" \
    --inputpath "$BIN" --outputpath "$BIN" --tmppath "$ROOT/build/genimage.tmp"

echo
echo "== sdcard.img"
ls -la "$BIN/sdcard.img"
if command -v fdisk >/dev/null 2>&1; then
    echo "== Partitions"
    fdisk -l "$BIN/sdcard.img"
fi