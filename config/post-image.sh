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

# SPL + U-Boot. Modern buildroot names the custom-source build dir
# "uboot-<git version>" (e.g. uboot-chameleon96), not the old uboot-custom.
install -m 644 "$BASE_DIR/build"/uboot-*/u-boot-with-spl.sfp \
    "$BINARIES_DIR/u-boot-with-spl.sfp"

# Boot core (menu) for the FAT partition. It was already fetched into the
# rootfs by the post-build script (target/media/fat/menu.rbf); reuse it.
install -m 644 "$BASE_DIR/target/media/fat/menu.rbf" \
    "$BINARIES_DIR/Menu_MiSTer.rbf"

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

# Assemble the complete SD card image (sdcard.img) with genimage.
# Uses buildroot's genimage.sh wrapper (needs BUILD_DIR/BINARIES_DIR/BR2_CONFIG,
# all exported by buildroot).
"$ROOT/buildroot/support/scripts/genimage.sh" -c "$ROOT/config/genimage.cfg"