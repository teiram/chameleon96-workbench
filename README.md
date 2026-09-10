# Chameleon96 workbench

Build a complete MiSTer-on-Chameleon96 SD card image in one shot:

- **SPL + U-Boot** (`u-boot-with-spl.sfp`) -> A2 partition
- **Linux kernel + DTB** (`zImage`, `socfpga_cyclone5_chameleon96.dtb`) -> FAT partition
- **Menu_MiSTer.rbf** (boot core) -> FAT partition, fetched from the
  [Menu_MiSTer_ch96](https://github.com/teiram/Menu_MiSTer_ch96) `releases/` dir
- **rootfs.tar** (ext4) with the **MiSTer** binary built from source and its
  runtime libs, plus init/HDMI scripts and the OSD scripts from
  `config/rootfs-overlay/`

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

### Rebuilding after a config change

Loading a defconfig does not make buildroot rebuild the packages whose options
changed: each package records that it is configured with a stamp file, and
that stamp is never compared against `.config`. Enabling a sub-option of a
package that is already built therefore produces a clean, successful build
that simply does not contain the new feature, and nothing says so.

`build.sh` handles this, so an incremental rebuild after editing
`config/chameleon96_config` is enough:

- it loads the defconfig **first** — which is also what puts
  `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` in place, so a `linux-reconfigure`
  run before that point would merge the kernel `.config` without the fragment;
- it warns about symbols kconfig dropped for unmet dependencies, instead of
  letting them go missing quietly;
- it compares the new `.config` against the one the previous build used and
  runs `<package>-reconfigure` for each package whose options moved (`linux`
  and `uboot` included);
- it removes files from `build/target/media/fat/Scripts/` that are no longer
  in the overlay — buildroot copies the overlay over `build/target/` and never
  prunes it, so a renamed script would otherwise stay in the MiSTer menu.

None of that costs anything when nothing changed.

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

## Resizing the SD image

By default the rootfs (ext4) partition is 300M. `sdcard.img` can be
re-assembled for a smaller/larger card and/or with an extra tree merged into
the rootfs without a full rebuild:

```sh
./sd-resize.sh 8G                        # fit the rootfs on a 8G card
./sd-resize.sh 1G --merge extra/         # also merge extra/ into the rootfs
./sd-resize.sh 1G --merge extra/ --overwrite   # same, replacing existing files
./sd-resize.sh default                   # restore the default 300M rootfs
```

`<sd-size>` is the full card size, or `default` to restore the build's default
rootfs. The a2 and boot partitions occupy the first 112M, so the rootfs is
sized `<sd-size> - 112M` (the card must be larger than 112M). `--merge`
adds new files only; `--overwrite` also replaces existing ones.

## Growing the rootfs from the board

`sdcard.img` is built for a fixed 300M rootfs, which is what fits any card.
The rest of whatever card the board actually boots from can be claimed on the
board itself, from the MiSTer OSD — no PC, no card reader, no re-flash:

**OSD → Scripts → `expand_rootfs`**

It grows the MBR entry of the Linux partition to the end of the medium, makes
the running kernel re-read the table (`partx`, which uses the BLKPG ioctl and
so works on a mounted disk), and then grows the ext4 inside it. The resize is
online: the filesystem stays mounted as `/` throughout and no reboot is
needed. Running it again on an already-expanded card reports that there is
nothing to do.

**OSD → Scripts → `sdcard_info`**

Read-only companion: the card's real size and CID, the partition table as
written on the card *and* as the kernel currently sees it, and the size of the
root filesystem. It is what tells you whether a resize that ended somewhere
unexpected was the card, the partition table or the filesystem disagreeing.

Both write a log next to themselves in `/media/fat/Scripts/`, and copy it onto
the FAT boot partition so it can be read from a PC.

Both live in `config/rootfs-overlay/media/fat/Scripts/` and can be run from a
shell too; `expand_rootfs.sh --report` reports without changing anything.

### The console those scripts run on

`MiSTer.ini` sets `fb_terminal=1`, so Main_MiSTer runs an OSD script on a real
80-column framebuffer console rather than in the 32-column OSD window. It does
that by switching to tty2 and exec'ing a login program there:

```c
execl("/sbin/agetty", "/sbin/agetty", "-a", "root", "-l", "/tmp/script",
      "--nohostname", "-L", "tty2", "linux", NULL);
```

on a wrapper whose shebang is hard-coded to `#!/bin/bash`. Three things follow,
and all three are silent when missing:

- the rootfs needs **bash** (`BR2_PACKAGE_BASH`, which needs
  `BR2_PACKAGE_BUSYBOX_SHOW_OTHERS`) and **agetty**
  (`BR2_PACKAGE_UTIL_LINUX_AGETTY`). `config/post-build.sh` also makes sure
  `/sbin/agetty` resolves, since util-linux installs it under `/usr/sbin` on a
  rootfs without merged `/usr`;
- **tty1..tty6 must be free of any getty**, or init and MiSTer take turns
  owning the terminal. `config/rootfs-overlay/etc/inittab` leaves only the
  serial console line active, which is what a stock MiSTer does too;
- the wrapper does `export LC_ALL=en_US.UTF-8`, so that locale has to exist or
  bash prints a `setlocale` warning over every script's output — hence
  `BR2_GENERATE_LOCALE="en_US.UTF-8"`.

Set `fb_terminal=0` in `MiSTer.ini` to fall back to the OSD window, which
needs none of them. The scripts detect which one they are on and adjust their
output width.

## Networking

A USB Ethernet adapter with a Realtek **RTL8152 / RTL8153** chipset works out
of the box: plug it in, boot, and the OSD Information panel shows the address.
`config/linux.fragment` builds `r8152` as a module and
`BR2_PACKAGE_LINUX_FIRMWARE_RTL_815X` supplies the `rtl_nic` blobs.

Two small files in the overlay do the rest, and neither is optional:

- `etc/modules-load.d/ch96-net.conf` — the rootfs uses devtmpfs with neither
  mdev nor eudev, so there is **no uevent helper**: device nodes appear but
  nothing ever calls `modprobe`. `/etc/init.d/S11modules` reading this file is
  the only thing that loads the driver. Without it the adapter enumerates on
  USB and no driver ever claims it.
- `etc/network/interfaces` — buildroot generates this file from
  `BR2_SYSTEM_DHCP`, which is empty, so its version has the loopback stanza
  and nothing else. Without an `eth0` stanza the interface comes up with no
  address, and `getNet()` in Main_MiSTer counts only an interface named
  `eth0` (or `wlan*`) that carries a non-link-local IPv4 address — so the OSD
  reports "No network" with the driver working perfectly.

Two OSD entries:

**Scripts → `net_info`** — read-only. Reports the interfaces, the USB devices
and which driver claimed them, whether `r8152` is built and loaded, and
whether anything is set up to ask for an address; then names which of the four
possible causes applies: the module was never built, built but not loaded,
loaded but not bound, or bound with no IPv4.

**Scripts → `net_up`** — does what the boot cannot: brings up an adapter
plugged in with the board already running. The driver is resident so `eth0`
appears by itself, but with no uevent helper nothing asks for a lease. It
loads the module if needed, waits for the interface, runs DHCP and polls for
the address — `ifup` returns before the lease arrives, because buildroot
builds busybox with `udhcpc -t1 ... -b`.

`build.sh` checks after every build that each `CONFIG_` line in
`config/linux.fragment` really reached the kernel `.config`, and says which
ones did not. Buildroot merges a fragment once and guards that with a stamp
file, so a fragment that failed to take produces a perfectly successful build
with the driver simply absent.

The **on-board WiFi** (Sterling LWB 450-0152 R2, BCM4343W) is not supported,
and cannot be without more than a driver: it is an SDIO part, the Cyclone V
HPS has exactly one SD/MMC controller and the device tree gives it to the
microSD slot. `config/linux.fragment` explains what enabling it would actually
require. A USB WiFi dongle needs none of that.

## SSH

Once the board has an address it accepts SSH the way a stock MiSTer does:

```sh
ssh root@<board ip>      # password: 1
```

`scp` and SFTP (WinSCP, FileZilla) work over the same connection. The daemon
is buildroot's openssh with its own `S50sshd` — which is exactly what a MiSTer
runs; their `security_fixes.sh` disables SSH by renaming that same file, and
looks for that same password to warn that it is still the installer default.

Two details decide whether this works at all, and both fail without a word in
any log:

- `BR2_PACKAGE_OPENSSH_KEY_UTILS`. `S50sshd` opens with
  `[ -f /usr/bin/ssh-keygen ] || exit 0`, so without `ssh-keygen` the daemon
  exits with status 0 at every boot and nothing is logged anywhere.
- `PermitRootLogin yes` in `config/rootfs-overlay/etc/ssh/sshd_config`. The
  openssh package only ever rewrites `UsePAM` in the config it installs;
  upstream ships `PermitRootLogin` commented out, and OpenSSH's compiled-in
  default has been `prohibit-password` since 7.0 — which refuses precisely a
  root login with a password.

That config also turns off reverse DNS lookups, which otherwise cost about ten
seconds of apparent hang per login on a LAN with no reverse zone, and serves
SFTP through `internal-sftp`, so there is no `/usr/libexec` path to get wrong.
`PermitEmptyPasswords no` is deliberate rather than redundant: if the root
password ever ended up empty, that line is what stops the board becoming an
open shell on the LAN.

The password comes from `BR2_TARGET_GENERIC_ROOT_PASSWD="1"`. Unlike most
things here it needs no package rebuild: buildroot applies it from a
`TARGET_FINALIZE_HOOK`, which runs on every build.

Host keys are generated on the board at first boot by `ssh-keygen -A`, so each
board gets its own — a MiSTer instead ships them inside the SD-Installer
image, which is why every MiSTer in the world shares the same set.

**Scripts → `ssh_status`** checks the six things that all have to hold —
binaries, host keys, daemon listening, config, root password, `/dev/pts` — and
names the one that does not. The password check is real rather than assumed:
the stored hash carries its own salt, so it re-hashes `1` with that salt and
compares. The hash itself is never printed.

`build.sh` also checks after every build that the symbols which are set really
produced something in `rootfs.tar` — `ssh-keygen` and `sshd` among them — and
that root ends up with a usable password. Buildroot does not reconfigure an
already-built package when one of its sub-options changes, so a missing binary
is otherwise a completely successful build that simply does not work on the
board.

`root` / `1` is the best-known password in the retro-hardware world. It is
fine on a development LAN; run `passwd` before that board sees a network you
do not control.

## Booting

- The SPL initializes the HPS and loads U-Boot.
- U-Boot reads `u-boot.scr` from the FAT partition, which programs the FPGA
  with `Menu_MiSTer.rbf`.
- U-Boot boots the kernel via extlinux (`extlinux/extlinux.conf`); the rootfs
  comes up and starts the MiSTer application.
- The menu core drives the LEDs on the Chameleon96 base board; a shell is
  available on the serial console (root, no password). The framebuffer
  consoles are left to MiSTer — see *The console those scripts run on* above.
  HDMI output is brought up by `/etc/init.d/S99hdmi` (1280x720@60, matching
  MiSTer.ini).