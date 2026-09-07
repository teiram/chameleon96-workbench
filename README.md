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

```sh
git clone https://gitlab.com/buildroot.org/buildroot.git
cd buildroot
git checkout 74e84b5cde   # version the chameleon96 config is tested against
cd ..

./build.sh
```

`build.sh` configures buildroot out-of-tree (output in `build/`), runs the full
build, and prints the resulting artifacts. The `buildroot/` and `build/`
directories are git-ignored.

To clean up: `./clean.sh` removes the generated artifacts but keeps the
download cache, `./distclean.sh` removes both.

## Artifacts

After a successful build, `build/images/` contains:

| File | Purpose | Partition |
|------|---------|-----------|
| `u-boot-with-spl.sfp` | SPL + U-Boot | A2 |
| `zImage` | Linux kernel | FAT |
| `socfpga_cyclone5_chameleon96.dtb` | Device tree | FAT |
| `Menu_MiSTer.rbf` | Boot core (programs the FPGA) | FAT |
| `u-boot.scr` | U-Boot script (loads the RBF, boots the kernel) | FAT |
| `extlinux/extlinux.conf` | U-Boot extlinux boot entry | FAT |
| `rootfs.tar` | Root filesystem with MiSTer + runtime libs | ext4 |

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

Three partitions (the order in the partition table does not matter):

```
Device     Boot  Start    End Sectors  Size Id Type
/dev/sdX1        22529 227329  204801  100M  b W95 FAT32
/dev/sdX2       227330 841730  614401  300M 83 Linux
/dev/sdX3         2048  22528   20481   10M a2 unknown
```

- Write the SPL+U-Boot to the A2 partition:

  ```sh
  dd if=u-boot-with-spl.sfp of=/dev/sdX3
  ```

  (double-check the device name before running this)

- Copy to the FAT partition:
  - `zImage`
  - `socfpga_cyclone5_chameleon96.dtb`
  - `Menu_MiSTer.rbf`
  - `u-boot.scr`
  - `extlinux/extlinux.conf` (as `extlinux/extlinux.conf`)

- Extract `rootfs.tar` to the ext4 partition.

## Booting

- The SPL initializes the HPS and loads U-Boot.
- U-Boot runs `u-boot.scr`, which programs the FPGA with `Menu_MiSTer.rbf`.
- U-Boot boots the kernel via extlinux; the rootfs comes up and starts the
  MiSTer application.
- The menu core drives the LEDs on the Chameleon96 base board; a login prompt
  is available on the serial console (root, no password). HDMI output is
  brought up by `/etc/init.d/S99hdmi` (1280x720@60, matching MiSTer.ini).