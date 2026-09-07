#!/bin/sh
# edid_probe.sh - on-board diagnostic for the TDA19988 DDC EDID read timeout.
#
# Reproduces the u-boot/Linux DDC sequence step by step and prints the state of
# every register that decides whether the block read completes, so a failing
# read can be classified without reflashing:
#   - CEC RXSHPDLEV (0xfe): is the sink present? (bit1 HPD, bit0 RXSENS)
#   - TX4 (P12 0x9b): is the EDID RAM power-down bit clear during the read?
#   - INT_FLAGS_2 (P0 0x11): does EDID_BLK_RD (bit 1) ever latch?
#   - page 09h 0x00-0x0f: first EDID bytes once the block read completes.
#
# All values are hex: this board's i2cset/i2cget is busybox, which parses
# numeric arguments as base 16 (see mode720_full.sh).
#
# Usage: ./edid_probe.sh [ddc_clk]   (run while the display is connected and powered)
#   ddc_clk - optional DDC channel clock value (page 12h 0x9a, default 39 = u-boot/
#             Linux reference). Try a higher value (e.g. 78, 156) if the bus is
#             marginal with your particular sink and the read times out.
BUS=2
HDMI=0x73
CEC=0x37
DDC_CLK=${1:-39}

hx() { printf '0x%02x' "$(( $1 ))"; }

rd() { # page reg -> prints value on stdout
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cget -fy $BUS $HDMI "$(hx $2)"
}
wr() { # page reg val
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cset -fy $BUS $HDMI "$(hx $2)" "$(hx $3)"
}

echo "== TDA19988 DDC EDID probe =="

# wake the device and enable the HDMI output path (as tda_config_init)
i2cset -fy $BUS $CEC 0xff 0x06
sleep 0.05
i2cset -fy $BUS $CEC 0x23 0x20

# CEC FRO / I2C-master clock control: GHOST_DIS|IMCLK_SEL (0x82). Both reference
# drivers write this at probe (u-boot tda19988.c:630, Linux tda998x_drv.c:1895);
# IMCLK_SEL clocks the DDC I2C master from the always-on internal FRO. Without it
# the EDID block read may never run. Also ensure HPD interrupts are disabled/clear
# (REG_CEC_RXSHPDINTENA=0xfc=0, clear REG_CEC_RXSHPDINT=0xfd).
i2cset -fy $BUS $CEC 0xfb 0x82
i2cset -fy $BUS $CEC 0xfc 0x00
i2cget -fy $BUS $CEC 0xfd >/dev/null

# sink presence / HPD level (CEC core 0xfe: bit1 HPD, bit0 RXSENS)
hpd=$(i2cget -fy $BUS $CEC 0xfe)
echo "CEC RXSHPDLEV (0xfe) = $hpd   (bit1 HPD, bit0 RXSENS)"
case "$hpd" in
	0x03|0x02|0x01) echo "  -> sink detected on DDC: OK" ;;
	*) echo "  -> WARNING: no HPD/RXSENS. Sink DDC may be powered off." ;;
esac

# DDC enable + clock (page 00 0x0b=0, page 12 0x9a=DDC_CLK)
wr 0x00 0x0b 0x00
wr 0x12 0x9a $DDC_CLK
echo "DDC clock (P12 0x9a) = $DDC_CLK"

# clear stale interrupt flags, then enable EDID_BLK_RD (P0 0x11 bit 1)
rd 0x00 0x0f >/dev/null
rd 0x00 0x10 >/dev/null
rd 0x00 0x11 >/dev/null
wr 0x00 0x11 0x02
arm=$(rd 0x00 0x11)
armv=$((arm))
echo "P0 0x11 read-back right after arm write = $arm"
if [ $(( armv & 0x02 )) -ne 0 ]; then
	echo "  -> note: EDID_BLK_RD already set (stale flag or read completed)."
fi
echo "  (flag registers read back 0 after arming; the write arms the latch, the"
echo "   bit only shows when the DDC block read completes - the poll below is the test.)"
echo "INT_FLAGS_0/1 (P0 0x0f/0x10) before read = $(rd 0x00 0x0f) / $(rd 0x00 0x10)"

# TX4: EDID RAM power-down state
tx4=$(rd 0x12 0x9b)
tx4v=$((tx4))
echo "TX4 (P12 0x9b) = $tx4   (bit1 TX4_PD_RAM)"
wr 0x12 0x9b $(( tx4v & ~0x02 ))
tx4c=$(rd 0x12 0x9b)
echo "TX4 after PD_RAM clear = $tx4c"

sleep 0.1

# DDC block read setup (mirrors u-boot/Linux)
wr 0x09 0xfb 0xa0   # DDC_ADDR
wr 0x09 0xfc 0x00   # DDC_OFFS
wr 0x09 0xfd 0x60   # DDC_SEGM_ADDR
wr 0x09 0xfe 0x00   # DDC_SEGM

wr 0x09 0xfa 0x01   # EDID_CTRL: enable block read
wr 0x09 0xfa 0x00   # EDID_CTRL: clear (flag cleared by sw)

# poll EDID_BLK_RD (P0 0x11 bit 1): fast 2s, then slow 5s (slow-bus check)
i=0
done=0
while [ "$i" -lt 40 ]; do
	v=$(rd 0x00 0x11)
	val=$((v))
	if [ $(( val & 0x02 )) -ne 0 ]; then done=1; break; fi
	sleep 0.05
	i=$((i + 1))
done
if [ "$done" -ne 1 ]; then
	echo "  fast poll (2s) timed out; trying 5s slow poll..."
	i=0
	while [ "$i" -lt 100 ]; do
		v=$(rd 0x00 0x11)
		val=$((v))
		if [ $(( val & 0x02 )) -ne 0 ]; then done=1; break; fi
		sleep 0.05
		i=$((i + 1))
	done
fi

echo "INT_FLAGS_0/1/2 (P0 0x0f/0x10/0x11) after poll = $(rd 0x00 0x0f) / $(rd 0x00 0x10) / $(rd 0x00 0x11)"
if [ "$done" -ne 1 ]; then
	echo "RESULT: EDID_BLK_RD never latched - DDC block read did not complete."
	echo "        If HPD was present, the arm read-back / TX4 state above are the"
	echo "        suspects. Restoring TX4 and exiting."
	wr 0x12 0x9b $tx4v
	exit 1
fi
echo "RESULT: EDID_BLK_RD latched (after $i polls)."

# read the first 16 EDID bytes from page 09h
wr 0x00 0x11 0x02
i2cset -fy $BUS $HDMI 0xff 0x09
echo -n "EDID[0x00..0x0f]: "
i=0
while [ "$i" -lt 16 ]; do
	i2cset -fy $BUS $HDMI 0xff 0x09
	printf "%s " "$(i2cget -fy $BUS $HDMI $(hx $i))"
	i=$((i + 1))
done
echo
echo "Expected header: 0x00 0xff 0xff 0xff 0xff 0xff 0xff 0x00 ..."

# restore TX4_PD_RAM
wr 0x12 0x9b $tx4v
echo "TX4 restored to $tx4v"
exit 0
