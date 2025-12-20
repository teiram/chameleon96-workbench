## Creating a working SD card for the Chameleon96

In this chapter we will create an SD card containing:
 - A U-Boot SPL able to initialize the HPS hardware
 - A U-Boot able to launch the linux kernel
 - A U-Boot script able to program the FPGA before starging the linux kernel
 - A root filesystem the Linux kernel can mount and use to bring us to the login prompt.

### Preparing the SD Card
There are plenty of tutorials around on how to do this for different boards based on the Cyclone V socfpga and the Chameleon96 is not different. The ROM in the Cyclone V HPS side is able to boot from the SD Card and this is the method we will follow. For it to work it needs a partition with type A2. This partition will hold the SPL code (4 copies of it, 64Kbytes each) and the U-Boot image right after. 

We will also need a FAT32 partition (type 0b) where the files to be accessed by U-Boot as part of the initialization process shall be placed. These are:
 - The kernel zImage
 - The device dtb (more on this later)
 - The u-boot script
 - The FPGA initialization code (rbf).

Finally we need a root filesystem for Linux to boot from. We will create an ext4 partition for that, but probably other type of partition could be chosen.

Partitions are normally created in a non-natural order:
 - Partition A2 goes first in the drive, but it's the third partition in the partition table (for instance /dev/sda3).
 - Partition 0B goes second in the drive but it's created as the first partition (like /dev/sda1).
 - Partition for the root fs goes third in the drive, and it's created as the second partition (like /dev/sda2).

Whether this is really needed or enforced by the hardware was not checked so far. Let's just say that this works and a different organization serves no purpose.

So, go get your favourite partition editor (like fdisk or parted) and create your partitions so that your drive looks like this:

```
Device     Boot  Start    End Sectors  Size Id Type
/dev/sda1        22529 227329  204801  100M  b W95 FAT32
/dev/sda2       227330 841730  614401  300M 83 Linux
/dev/sda3         2048  22528   20481   10M a2 unknown
```

Sizes for the partitions are not enforced. Normally a partition of 2MB should suffice for A2, and for 0B (FAT32) you would need at least around 20MB, but you can make it bigger. Use the rest of the SD Card capacity for the rootfs partition.


### Building the artifacts to populate the SD card

For this we will make use of [buildroot](https://buildroot.org/) with a custom configuration that will allow us to build all the artifacts.

- Clone buildroot into the root directory

	`git clone https://gitlab.com/buildroot.org/buildroot.git

- Create a build directory in the root folder of this project.

	`mkdir build

- Go into the buildroot directory and run:
	`make defconfig BR2_DEFCONFIG=../config/chameleon96_config O=../build

- Now buildroot is configured in the build directory to perform a build customized for the chameleon96 board. It will also take care of creating a toolchain that we can later use to compile software to be run on the Cyclone V HPS. Just go into build and run:

	`make

 
- The following artifacts should be available once the build is done:
	- U-Boot with SPL in: build/uboot-chameleon96/u-boot-with-spl.sfp
	- Linux kernel in: images/zImage
	- Tar of the root filesystem in: images/rootfs.tar
	- Binary Device Tree of the Chameleon in: build/u-boot-chameleon96/src/arm/dts/socfpga_cyclone5_chameleon96.dtb

- We need also the U-Boot script, there is a source file and makefile in the u-boot-scr folder that can be used to generate an u-boot.scr image after the u-boot.script we need for this purpose. Just cd into that folder and run

	`make


### Creating the SD Card

- Transfer the u-boot-with-spl.sfp to the beginning of the A2 partition. On Linux this can be done with the dd tool, just something like:

	` dd if=u-boot-with-spl.sfp of=/dev/<disk>3 

where <disk> is the name of the SD Card device (for instance sda). To keep the tradition I will warn you of biblic disasters if you happen to use a wrong partition. Consider yourself warned.

- Copy the following files to the VFAT partition of the SD Card:
	- zImage
	- socfpga_cyclone5_chameleon96.dtb
	- u-boot.scr
	- hps-ch96.rbf (see the [related project](https://github.com/teiram/hps-ch96))
	- An extlinux/extlinux.conf file with the following content:

```
LABEL Linux Chameleon96
	KERNEL ../zImage
	FDT ../socfpga_cyclone5_chameleon96.dtb
	APPEND root=/dev/mmcblk0p2 rw rootwait earlyprintk console=ttyS0,115200n8
```

### Give it a try

You should rather connect the serial port of the chameleon96 to your computer in order to have access to the serial port. The following things should happen:
- The SPL initializes the HPS hardware and loads U-Boot
- U-Boot gives you the change to stop the progress to change the configuration (2 seconds)
- U-Boot runs the u-boot script and loads hps-ch96.rbf into the FPGA. User LEDs should start blinking.
- U-Boot loads the DTB and the linux kernel and boots it.
- The linux kernel mounts the root fs and eventually starts a getty to allow login.
- You can login with the root user (no password is set).

### Extra steps

#### SDK
You can create a toolchain tarball running the sdk make target in the build directory:

`make sdk

that will tar the toolchain as: images/arm-ch96-linux-gnueabi_sdk-buildroot.tar.gz

You can use this toolchain to build extra software for the Chameleon96 ARM processors.

#### Controlling the RF LEDs

In this reference implementation the RF LEDs are forwarded from the FPGA fabric to the HPS by means of an AXI lightweight MM bridge. Therefore they are available on the linux side as memory mapped GPIOs.

In the folder hps_led there is a simple program to exercise the leds. The program takes an integer argument, from where the two less significant bits are taken to decide the status of the LEDs.

