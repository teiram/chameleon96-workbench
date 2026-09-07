#!/bin/sh
# hdmi_audio.sh - enable the TDA19988 I2S audio input path (validation).
#
# Root cause of "no sound on any core": every config path (workbench hdmi/*.sh,
# Main_MiSTer video.cpp tda_config_init, u-boot tda19988.c) only programs video
# registers. The TDA's audio block is left at power-on reset defaults, which
# route the AP pins as SPDIF (AIP_CLKSEL default 0x00) with the audio ports
# disabled (ENA_AP=0), so the FPGA I2S stream on AP0/AP1 is ignored and no
# Audio InfoFrame is ever sent. This script programs the full audio enable
# sequence, mirroring the Linux tda998x driver (tda998x_configure_audio in
# linux-socfpga/drivers/gpu/drm/i2c/tda998x_drv.c) for a fixed 48 kHz stereo
# I2S input:
#   AP0 = I2S word select (WS, PIN_V9), AP1 = I2S data (PIN_AA11),
#   ACLK = I2S bit clock (PIN_W11).  The 24.576 MHz OSC_IN/AP3 MCLK is NOT
#   used for I2S: on the TDA9983/TDA19988, MCLK is only an S/PDIF reference.
# The FPGA drives bclk = 1.536 MHz = 32 x fs (i2s.v), so bclk ratio = 32 and
# CTS_N = CTS_N_M(3)|CTS_N_K(1) = 0x31.
#
# Usage: ./hdmi_audio.sh [720p|1080p]
#   Run while MiSTer is already outputting video (app runs tda_config_init at
#   boot) and a core is playing audio; then check the HDMI sink for sound.
#   The mode argument only selects AUDIO_DIV (SERCLK_8 for 720p60 @ 74.25MHz,
#   SERCLK_16 for 1080p60 @ 148.5MHz); it must match the current video mode.
#   Key registers are read back and printed so a silent sink is easy to
#   diagnose. Re-running is safe (idempotent).
BUS=2
HDMI=0x73
CEC=0x37
MODE=${1:-720p}

case "$MODE" in
	720p)  ADIV=0x03 ;;  # AUDIO_DIV: SERCLK_8
	1080p) ADIV=0x04 ;;  # AUDIO_DIV: SERCLK_16
	*) echo "usage: $0 [720p|1080p]"; exit 1 ;;
esac

hx() { printf '0x%02x' "$(( $1 ))"; }

wr() { # page reg val
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cset -fy $BUS $HDMI "$(hx $2)" "$(hx $3)"
}
wr8() { # page firstreg bytes...  (write consecutive registers)
	page=$1
	reg=$2
	shift 2
	i=0
	for val in "$@"; do
		i2cset -fy $BUS $HDMI 0xff "$(hx $page)"
		i2cset -fy $BUS $HDMI "$(hx $(( reg + i )))" "$(hx $val)"
		i=$((i + 1))
	done
}
rd() { # page reg -> prints value on stdout
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	i2cget -fy $BUS $HDMI "$(hx $2)"
}
set_bit() { # page reg mask
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	old=$(( $(i2cget -fy $BUS $HDMI "$(hx $2)") ))
	wr $1 $2 $(( (old | $3) & 0xff ))
}
clr_bit() { # page reg mask
	i2cset -fy $BUS $HDMI 0xff "$(hx $1)"
	old=$(( $(i2cget -fy $BUS $HDMI "$(hx $2)") ))
	wr $1 $2 $(( old & ~$3 ))
}

echo "== TDA19988 I2S audio enable ($MODE, AUDIO_DIV=$ADIV) =="

# wake the device and enable the HDMI output path (as the other hdmi scripts)
i2cset -fy $BUS $CEC 0xff 0x06
sleep 0.05
i2cset -fy $BUS $CEC 0x23 0x20

# ---- page 00: audio input routing (Linux tda998x_configure_audio) -----------
wr 0x00 0x16 0x01   # ENA_ACLK = 1 (enable I2S bit clock input)
wr 0x00 0x1e 0x03   # ENA_AP = AP0 (WS) | AP1 (data)
wr 0x00 0x26 0x64   # MUX_AP = MUX_AP_SELECT_I2S
wr 0x00 0xfc 0x00   # I2S_FORMAT = Philips (reg 0xFC is "Not used" on TDA9983/9988)
wr 0x00 0xfd 0x08   # AIP_CLKSEL = AIP_I2S | FS_ACLK (was default SPDIF route!)

# ---- HDMI vs DVI: audio data islands only fly in HDMI mode -------------------
# The app never programs these; the TDA sits in DVI mode by default, which
# transmits no data islands and therefore no audio. Linux sets both when the
# sink supports infoframes (tda998x_drv.c:1670-1671: "turn HDMI HDCP stuff on
# to get audio through"): TX33_HDMI forces HDMI, ENC_CNTRL CTL_CODE(1) enables
# the control periods that carry the audio packets.
set_bit 0x12 0xb8 0x02   # TX33: TX33_HDMI (P12 0xB8 bit 1)
wr 0x11 0x0d 0x04        # ENC_CNTRL: CTL_CODE(1)=HDMI, DC_CTL 00 (Table 98; 0x04, NOT 0x02)
clr_bit 0x00 0xcb 0x40   # TBG_CNTRL_1: clear DWIN_DIS bit 6 (data islands enabled)
set_bit 0x11 0x0e 0x01   # DIP_FLAGS: ACR (insert audio clock regeneration packets)

# ---- page 11: AIP control, CTS/N, channel status ----------------------------
clr_bit 0x11 0x00 0x24   # AIP_CNTRL_0: clear LAYOUT|ACR_MAN -> auto CTS
wr 0x11 0x0c 0x31        # CTS_N = CTS_N_M(3) | CTS_N_K(1)  (bclk ratio 32)
wr 0x02 0x0e $ADIV       # AUDIO_DIV (page 02, serializer block)

# ACR CTS/N for 48 kHz non-coherent clocks: CTS=0x014244, N=6144 (0x1800)
wr 0x11 0x05 0x44        # ACR_CTS_0
wr 0x11 0x06 0x42        # ACR_CTS_1
wr 0x11 0x07 0x01        # ACR_CTS_2
wr 0x11 0x08 0x00        # ACR_N_0 = N & 0xff       (0x00)
wr 0x11 0x09 0x18        # ACR_N_1 = (N >> 8) & 0xff (0x18)
wr 0x11 0x0a 0x00        # ACR_N_2 = (N >> 16) & 0xff (0x00)

set_bit 0x11 0x00 0x40   # AIP_CNTRL_0: set RST_CTS (reset CTS generator)
clr_bit 0x11 0x00 0x40   # AIP_CNTRL_0: clear RST_CTS

# channel status (REG_CH_STAT_B skips the IEC958 AES2 byte)
wr 0x11 0x14 0x00        # CH_STAT_B0: PCM, consumer
wr 0x11 0x15 0x00        # CH_STAT_B1: no emphasis / original
wr 0x11 0x16 0x02        # CH_STAT_B3: AES3 = 48 kHz
wr 0x11 0x17 0x00        # CH_STAT_B4

# ---- unmute the audio FIFO (mute toggle like tda998x_audio_mute) -------------
set_bit 0x00 0x0a 0x01   # SOFTRESET: SOFTRESET_AUDIO set
clr_bit 0x00 0x0a 0x01   # SOFTRESET: SOFTRESET_AUDIO clear
set_bit 0x11 0x00 0x01   # AIP_CNTRL_0: RST_FIFO set (mute)
sleep 0.02
clr_bit 0x11 0x00 0x01   # AIP_CNTRL_0: RST_FIFO clear (unmute)

# ---- Audio InfoFrame (IF4): tells the sink to decode PCM 2ch 48kHz -----------
# packed by hdmi_audio_infoframe_pack (drivers/video/hdmi.c:402-404): header
# {0x84,0x01,0x0a,0x53}, payload DB1=0x11 (LPCM<<4 | 2ch-1), DB2=0x0d (48kHz, 16-bit)
clr_bit 0x11 0x0f 0x10   # DIP_IF_FLAGS: clear IF4
wr8 0x10 0x80 0x84 0x01 0x0a 0x53 0x11 0x0d 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
set_bit 0x11 0x0f 0x10   # DIP_IF_FLAGS: set IF4 (transmit)

# ---- AVI InfoFrame (IF2): some sinks refuse audio without a valid AVI ---------
# packed by hdmi_avi_infoframe_pack for 720p60 RGB full range (Linux
# tda998x_write_avi): header {0x82,0x02,0x0d,0x43}, DB2=0x20 (16:9),
# DB3=0x08 (full range RGB), DB4=0x04 (VIC 4 = 720p60), rest 0
clr_bit 0x11 0x0f 0x04   # DIP_IF_FLAGS: clear IF2
wr8 0x10 0x40 0x82 0x02 0x0d 0x43 0x00 0x20 0x08 0x04 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
set_bit 0x11 0x0f 0x04   # DIP_IF_FLAGS: set IF2 (transmit)

# ---- read-back diagnostics ----------------------------------------------------
echo "read-back (expect):"
echo "  ENA_ACLK   P00 0x16 = $(rd 0x00 0x16)   (0x01)"
echo "  ENA_AP     P00 0x1e = $(rd 0x00 0x1e)   (0x03)"
echo "  MUX_AP     P00 0x26 = $(rd 0x00 0x26)   (0x64)"
echo "  AIP_CLKSEL P00 0xfd = $(rd 0x00 0xfd)   (0x08 - I2S route)"
echo "  TX33       P12 0xb8 = $(rd 0x12 0xb8)   (bit1 TX33_HDMI set)"
echo "  ENC_CNTRL  P11 0x0d = $(rd 0x11 0x0d)   (0x04 CTL_CODE 1 - HDMI)"
echo "  TBG_CNTRL1 P00 0xcb = $(rd 0x00 0xcb)   (bit6 DWIN_DIS CLEARED)"
echo "  DIP_FLAGS  P11 0x0e = $(rd 0x11 0x0e)   (bit0 ACR set)"
echo "  AIP_CNTRL0 P11 0x00 = $(rd 0x11 0x00)   (RST_FIFO/RST_CTS clear)"
echo "  DIP_IF_FLG P11 0x0f = $(rd 0x11 0x0f)   (bit2 IF2 + bit4 IF4 set)"
echo "  AUDIO_DIV  P02 0x0e = $(rd 0x02 0x0e)   ($ADIV)"

# ---- Audio InfoFrame buffer check ---------------------------------------------
echo "AIF buffer P10 0x80..0x85 = $(rd 0x10 0x80) $(rd 0x10 0x81) $(rd 0x10 0x82) $(rd 0x10 0x83) $(rd 0x10 0x84) $(rd 0x10 0x85) (expect 84 01 0a 53 11 0d)"

# Note: ACR_CTS_0/1/2 (P11 05-07h) read-back is NOT a lock indicator on this
# chip: those registers only hold CTS for manual mode (datasheet Table 94). In
# auto-CTS mode (ACR_MAN=0) the measured value goes into the ACR packet, not
# back into the registers, so they keep whatever was written.
echo "TDA19988 I2S audio enabled ($MODE)."
