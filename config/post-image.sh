#!/bin/sh
# Buildroot post-image script.
# Stages every SD-card artifact into the binaries dir ($1 = images/):
#   - u-boot-with-spl.sfp            -> A2 partition (SPL + U-Boot)
#   - zImage, dtb, Menu_MiSTer.rbf,
#     u-boot.scr, extlinux/extlinux.conf -> FAT partition
# The root filesystem (rootfs.tar) already carries Main_MiSTer via the
# post-build script.
set -e

BINARIES_DIR=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOST_DIR/bin:$PATH"

# SPL + U-Boot (legacy buildroot u-boot build dir; package name is "custom")
install -m 644 "$BASE_DIR/build/uboot-custom/u-boot-with-spl.sfp" \
    "$BINARIES_DIR/u-boot-with-spl.sfp"

# Boot core (menu) for the FAT partition, fetched from the release directory
# of the Menu_MiSTer_ch96 GitHub repo. The newest menu_ch96_<date>.rbf is
# picked automatically; override the URL with MENU_RBF_URL if needed.
if [ -z "$MENU_RBF_URL" ]; then
    MENU_RBF_URL=$(curl -fsSL \
        "https://api.github.com/repos/teiram/Menu_MiSTer_ch96/contents/releases" \
        | sed -n 's/.*"download_url": "\(.*\.rbf\)".*/\1/p' | tail -1)
fi
[ -n "$MENU_RBF_URL" ] || { echo "ERROR: could not locate Menu_MiSTer RBF" >&2; exit 1; }
echo "== Fetching Menu_MiSTer RBF: $MENU_RBF_URL"
curl -fsSL "$MENU_RBF_URL" -o "$BINARIES_DIR/Menu_MiSTer.rbf"

# Boot script (programs the FPGA before booting the kernel)
mkimage -T script -n "Bootscript" -C none \
    -d "$ROOT/u-boot-scr/u-boot.script" \
    "$BINARIES_DIR/u-boot.scr"

# extlinux boot entry
mkdir -p "$BINARIES_DIR/extlinux"
cat > "$BINARIES_DIR/extlinux/extlinux.conf" <<'EOF'
LABEL Linux Chameleon96 (MiSTer)
	KERNEL ../zImage
	FDT ../socfpga_cyclone5_chameleon96.dtb
	APPEND root=/dev/mmcblk0p2 rw rootwait earlycon=uart8250,mmio32,0xffc02000 console=ttyS0,115200n8
EOF