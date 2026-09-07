#!/bin/sh
# mode720_full.sh - TDA19988 fully-programmed timing for 1280x720@60.
#
# The minimal mode720.sh leaves the TDA's timing generator (REFPIX/NPIX/NLINE,
# HS/VS positions, DE_START/DE_STOP) at power-on reset defaults while the TBG
# regenerates the output sync from the passed-through DE. When those defaults
# don't match the input format the output sync is phase-offset from DE, which
# shows as a fixed horizontal shift (left edge cut off on the display).
#
# This script programs the full per-mode timing, mirroring the board's own
# u-boot driver (u-boot-socfpga/drivers/video/tda19988.c, tda19988_enable) and
# the Linux tda998x driver (tda998x_drv.c, tda998x_set_video_mode). Run it while
# MiSTer is already outputting 720p60 (video_mode=16) and confirm the image
# re-centers. Values are computed from MiSTer's vmodes[0]: hact=1280 hfp=110
# hs=40 hbp=220 / vact=720 vfp=5 vs=5 vbp=20 (active-low HS/VS).
#
# Usage: ./mode720_full.sh [hs|de]
#   hs (default) - SYNC_HS like u-boot/Linux (VIDFORMAT=0x00, timing regs drive
#                  output DE/sync). Correct per the reference drivers.
#   de           - keep the board-validated SYNC_DE + RGB565 double-clock
#                  (VIDFORMAT=0x02) and only add the sync-phase timing regs.
# To revert to the original app config: run mode720.sh
BUS=2
HDMI=0x73
CEC=0x37
SYNC=${1:-hs}

set_reg() { # page reg val
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cset -fy $BUS $HDMI "$(hx $2)" "$(hx $3)"
}
set_reg16() { # page msbreg val16
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cset -fy $BUS $HDMI "$(hx $2)" "$(hx $(( ($3 >> 8) & 0xff )))"
	i2cset -fy $BUS $HDMI "$(hx $(($2 + 1)))" "$(hx $(( $3 & 0xff )))"
}
set_bit() { # page reg mask : set the masked bits (read-modify-write)
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	oldstr=$(i2cget -fy $BUS $HDMI "$(hx $2)")
	old=$((oldstr))
	new=$(( (old | $3) & 0xff ))
	i2cset -fy $BUS $HDMI "$(hx $2)" "$(hx $new)"
}
hx() { printf '0x%02x' "$(( $1 ))"; }

# wake the device and enable the HDMI output path
i2cset -fy $BUS $CEC 0xff 0x06
sleep 0.05
i2cset -fy $BUS $CEC 0x23 0x20

# ---- page 00: common control ------------------------------------------------
set_reg 0x00 0x0b 0x00   # DDC_DISABLE = 0
set_reg 0x00 0x27 0x24   # MUX_VP_VIP_OUT

# ---- page 02: serializer PLL common config (u-boot/Linux probe) -------------
set_reg 0x02 0x00 0x00   # PLL_SERIAL_1
set_reg 0x02 0x01 0x01   # PLL_SERIAL_2: SRL_NOSC(1) | SRL_PR(0)  (74.25MHz TMDS)
set_reg 0x02 0x02 0x00   # PLL_SERIAL_3
set_reg 0x02 0x03 0x00   # SERIALIZER
set_reg 0x02 0x04 0x00   # BUFFER_OUT
set_reg 0x02 0x05 0x00   # PLL_SCG1
set_reg 0x02 0x06 0x10   # PLL_SCG2
set_reg 0x02 0x07 0xfa   # PLL_SCGN1
set_reg 0x02 0x08 0x00   # PLL_SCGN2
set_reg 0x02 0x09 0x5b   # PLL_SCGR1
set_reg 0x02 0x0a 0x00   # PLL_SCGR2
set_reg 0x02 0x0e 0x03   # AUDIO_DIV: SERCLK_8
set_reg 0x02 0x11 0x09   # SEL_CLK: SEL_CLK1 | ENA_SC_CLK
set_reg 0x02 0x12 0x09   # ANA_GENERAL: TMDS bias

# ---- page 00: video input pins (keep the board-validated mapping) -----------
set_reg 0x00 0x18 0xff   # ENA_VP_0
set_reg 0x00 0x19 0xff   # ENA_VP_1
set_reg 0x00 0x1a 0xff   # ENA_VP_2
set_reg 0x00 0x20 0x45   # VIP_CNTRL_0: SWAP_A(4) | SWAP_B(5)
set_reg 0x00 0x21 0x23   # VIP_CNTRL_1: SWAP_C(2) | SWAP_D(3)
set_reg 0x00 0x22 0x01   # VIP_CNTRL_2: SWAP_E(0) | SWAP_F(1)

if [ "$SYNC" = de ]; then
	# keep the app's validated RGB565 double-clock DE-passthrough mode,
	# add only the sync-phase timing (HS/VS/VWIN), leave DE untouched
	set_reg 0x00 0x23 0x14   # VIP_CNTRL_3: SYNC_DE | V_TGL (app value)
	set_reg 0x00 0xa0 0x02   # VIDFORMAT: RGB565 double-clock
else
	# SYNC_HS mode exactly as u-boot/Linux drive it
	set_reg 0x00 0x23 0x26   # VIP_CNTRL_3: SYNC_HS | H_TGL | V_TGL (low-active)
	set_reg 0x00 0xa0 0x00   # VIDFORMAT: 24-bit, TBG drives output timing
fi

# ---- page 00: full timing for 1280x720@60 -----------------------------------
set_reg16 0x00 0xa1 113  # REFPIX   = 3 + hfp = 113
set_reg16 0x00 0xa3 6    # REFLINE  = 1 + vfp = 6
set_reg16 0x00 0xa5 1650 # NPIX     = htotal = 1650
set_reg16 0x00 0xa7 750  # NLINE    = vtotal = 750
set_reg16 0x00 0xa9 5    # VS_LINE_STRT_1 = vfp = 5
set_reg16 0x00 0xab 110  # VS_PIX_STRT_1  = hfp = 110
set_reg16 0x00 0xad 10   # VS_LINE_END_1  = vfp + vs = 10
set_reg16 0x00 0xaf 110  # VS_PIX_END_1   = hfp = 110
set_reg16 0x00 0xb1 0    # VS_LINE_STRT_2
set_reg16 0x00 0xb3 0    # VS_PIX_STRT_2
set_reg16 0x00 0xb5 0    # VS_LINE_END_2
set_reg16 0x00 0xb7 0    # VS_PIX_END_2
set_reg16 0x00 0xb9 110  # HS_PIX_START = hfp = 110
set_reg16 0x00 0xbb 150  # HS_PIX_STOP  = hfp + hs = 150
set_reg16 0x00 0xbd 29   # VWIN_START_1 = vtotal - vact - 1 = 29
set_reg16 0x00 0xbf 749  # VWIN_END_1   = vtotal - 1 = 749
set_reg16 0x00 0xc1 0    # VWIN_START_2
set_reg16 0x00 0xc3 0    # VWIN_END_2
if [ "$SYNC" = de ]; then
	: # keep input DE passthrough; do not program DE_START/STOP
else
	set_reg16 0x00 0xc5 370  # DE_START = htotal - hact = 370
	set_reg16 0x00 0xc7 1650 # DE_STOP  = htotal = 1650
fi

set_reg 0x00 0xd6 0x00   # ENABLE_SPACE = 0 (fill active space, TDA19988)
set_reg 0x00 0xf0 0x00   # RPT_CNTRL = no pixel repetition

# ---- color / processing (u-boot/Linux) --------------------------------------
set_reg 0x00 0x80 0x03   # MAT_CONTRL: bypass | SC(1)
set_bit 0x00 0x0e 0x03   # FEAT_POWERDOWN: PREFILT | CSC (set, keep other bits)
set_reg 0x00 0xe4 0x00   # HVF_CNTRL_0
set_reg 0x00 0xe5 0x00   # HVF_CNTRL_1
set_reg 0x00 0x24 0x00   # VIP_CNTRL_4
set_reg 0x00 0x25 0x00   # VIP_CNTRL_5

# TBG_CNTRL_1 must come before TBG_CNTRL_0 (TBG_CNTRL_0 is the "last register")
set_reg 0x00 0xcb 0x47   # TBG_CNTRL_1: DWIN_DIS | TGL_EN | H_TGL | V_TGL
set_reg 0x00 0xca 0x00   # TBG_CNTRL_0: sync method = auto, trigger on sync

# ---- page 11/12: encoder + HDCP ----------------------------------------------
set_reg 0x11 0x00 0x00   # AIP_CNTRL_0: audio off
set_reg 0x11 0x0d 0x00   # ENC_CNTRL: CTL_CODE(0)
set_bit 0x12 0xb8 0x02   # TX33: set TX33_HDMI (keep HDCP bit state)

echo "TDA19988 full 720p60 config applied (SYNC=$SYNC)."
