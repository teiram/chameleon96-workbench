# Chameleon96 workbench

Build a complete MiSTer-on-Chameleon96 SD card image in one shot:

- **SPL + U-Boot** (`u-boot-with-spl.sfp`) -> A2 partition
- **Linux kernel + DTB** (`zImage`, `socfpga_cyclone5_chameleon96.dtb`) -> FAT partition
- **Menu_MiSTer.rbf** (boot core) -> FAT partition, fetched from the
  [Menu_MiSTer_ch96](https://github.com/teiram/Menu_MiSTer_ch96) `releases/` dir
- **rootfs.tar** (ext4) with the **MiSTer** binary built from source and its
  runtime libs, plus init/HDMI scripts from `config/rootfs-overlay/`

Everything is self-contained: buildroot fetches the kernel from
[teiram/linux-socfpga](https://github.com/teiram/linux-socfpga) (`chameleon96`
branch), U-Boot from [teiram/u-boot-socfpga](https://github.com/teiram/u-boot-socfpga)
(`chameleon96` branch) and Main_MiSTer from
[teiram/Main_MiSTer_ch96](https://github.com/teiram/Main_MiSTer_ch96). The
cross toolchain is built by buildroot itself.

## Requirements

- A Linux host with the usual build tools (gcc, make, ...) and git.
- Internet access (buildroot downloads package sources, kernel, u-boot,
  Main_MiSTer and the menu RBF).

## Building

From the working directory:

```sh
git clone <this repository>
cd chameleon96-workbench
git clone https://gitlab.com/buildroot.org/buildroot.git
./build.sh
```

`build.sh` expects the buildroot clone next to it as `buildroot/` (run the
clone *inside* the workbench directory, not outside of it). It configures
buildroot out-of-tree (output in `build/`), runs the full build, and prints
the resulting artifacts. The `buildroot/` and `build/` directories are
git-ignored.

To clean up: `./clean.sh` removes the generated artifacts but keeps the
download cache, `./distclean.sh` removes both.

## Artifacts

After a successful build, `build/images/` contains:

| File | Purpose | Partition |
|------|---------|-----------|
| **`sdcard.img`** | Complete bootable SD card image | whole card |
| `u-boot-with-spl.sfp` | SPL + U-Boot | A2 |
| `zImage` | Linux kernel | FAT |
| `socfpga_cyclone5_chameleon96.dtb` | Device tree | FAT |
| `Menu_MiSTer.rbf` | Boot core (programs the FPGA) | FAT |
| `u-boot.scr` | U-Boot script (loads the RBF, boots the kernel) | FAT |
| `extlinux/extlinux.conf` | U-Boot extlinux boot entry | FAT |
| `rootfs.tar` / `rootfs.ext4` | Root filesystem with MiSTer + runtime libs | ext4 |

`sdcard.img` is assembled by [genimage](config/genimage.cfg) in the
post-image step: it recreates the layout below, so there is no need to
partition or copy anything by hand.

Main_MiSTer is cloned into `build/Main_MiSTer` on the first run and compiled
with the buildroot host toolchain; its shared libs (imlib2, freetype, png, z,
bz2, bluetooth) are installed into the rootfs.

## Toolchain override

By default everything is compiled with the buildroot-generated
`arm-ch96-linux-gnueabihf-` toolchain. To reuse a toolchain generated a single
time instead of rebuilding it on every clean build:

```sh
cd build
make sdk                                   # -> images/arm-ch96-linux-gnueabihf_sdk-buildroot.tar.gz
tar xf images/arm-ch96-linux-gnueabihf_sdk-buildroot.tar.gz   # extract somewhere
cd ..
```

then pass its bin prefix to the build:

```sh
CROSS_COMPILE=/path/to/arm-ch96-linux-gnueabihf_sdk-buildroot/bin/arm-ch96-linux-gnueabihf ./build.sh
```

Other optional overrides:

- `BR2_DL_DIR=/path/to/dl` — reuse a buildroot download cache.
- `MENU_RBF_URL=<url>` — pin a specific Menu_MiSTer RBF instead of the newest
  one found in the `releases/` directory.

## Creating the SD card

The build produces a complete bootable `build/images/sdcard.img`, assembled by
genimage (`config/genimage.cfg`) into the same layout:

| # | Partition | Contents |
|---|-----------|----------|
| 1 | FAT (100M, bootable) | `zImage`, DTB, `Menu_MiSTer.rbf`, `u-boot.scr`, `extlinux/extlinux.conf` |
| 2 | ext4 (300M) | rootfs with the MiSTer binary and its runtime libs |
| 3 | A2 (10M) | `u-boot-with-spl.sfp` (SPL + U-Boot, read by the HPS boot ROM at 1M) |

Write it to the SD card with:

```sh
dd if=build/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

(double-check the device name before running this)

## Booting

- The SPL initializes the HPS and loads U-Boot.
- U-Boot reads `u-boot.scr` from the FAT partition, which programs the FPGA
  with `Menu_MiSTer.rbf`.
- U-Boot boots the kernel via extlinux (`extlinux/extlinux.conf`); the rootfs
  comes up and starts the MiSTer application.
- The menu core drives the LEDs on the Chameleon96 base board; a login prompt
  is available on the serial console (root, no password). HDMI output is
  brought up by `/etc/init.d/S99hdmi` (1280x720@60, matching MiSTer.ini).