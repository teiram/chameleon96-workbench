# Same toolchain + linking as Main_MiSTer (mister/Main_MiSTer/Makefile BASE):
# arm-none-linux-gnueabihf (Linaro GCC 10.2), dynamic glibc, non-PIE, stripped.
# Add the toolchain bin dir to PATH, e.g.:
#   export PATH=$HOME/src/chameleon96/cleanup/mister/toolchains/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH
BASE    = arm-none-linux-gnueabihf

CC      = $(BASE)-gcc
STRIP   = $(BASE)-strip
CFLAGS  = -O2 -Wall -Wextra

ddrbench: hps_ddr_bench.c
	$(CC) $(CFLAGS) -o ddrbench hps_ddr_bench.c
	$(STRIP) ddrbench

# Fully static build: works even on boards without the armhf glibc.
ddrbench-static: hps_ddr_bench.c
	$(CC) $(CFLAGS) -static -o ddrbench-static hps_ddr_bench.c
	$(STRIP) ddrbench-static

clean:
	rm -rf ddrbench ddrbench-static

.PHONY: clean
