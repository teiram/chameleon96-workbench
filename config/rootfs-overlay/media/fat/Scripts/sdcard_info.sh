#!/bin/sh
# ---------------------------------------------------------------------------
# sdcard_info.sh -- print what the board actually believes about the SD card:
# its real size, who made it, how it is partitioned, and how big the root
# filesystem is.
#
# Run it from the MiSTer OSD (Scripts -> sdcard_info) or from a shell. It is
# the companion of expand_rootfs.sh: when a resize does not end where you
# expected, this says whether the card, the partition table or the filesystem
# is the one disagreeing -- without needing a serial console or a network.
#
# Reads only. Changes nothing.
#
# Same OSD rules as expand_rootfs.sh: stdout only (popen captures nothing
# else), 32 characters per line, and the number that matters printed LAST,
# because only the final 14 lines stay on screen.
# ---------------------------------------------------------------------------
exec 2>&1

# Parse tool output in the C locale; see the same note in expand_rootfs.sh.
LC_ALL=C
export LC_ALL

LOGDIR=/media/fat/Scripts
LOG="$LOGDIR/sdcard_info.log"
[ -d "$LOGDIR" ] || LOG=/tmp/sdcard_info.log
: > "$LOG" 2>/dev/null || LOG=/dev/null

# Where is the output going? The two OSD modes are told apart by one test:
#
#   fb_terminal=0 -> stdout is a PIPE. 32 columns, 14 visible lines, and the
#                    detail stays in the log.
#   fb_terminal=1 -> stdout is a TTY with a real console behind it. There is
#                    room for the whole story, so the detail goes to the screen.
COLS=32
WIDE=0
if [ -t 1 ]; then
    WIDE=1
    COLS=80
    _sz=$(stty size 2>/dev/null)
    if [ -n "$_sz" ]; then
        _c=${_sz##* }
        case "$_c" in ''|*[!0-9]*) ;; *) [ "$_c" -ge 20 ] && COLS=$_c ;; esac
    fi
    [ "$COLS" -lt 60 ] && WIDE=0
fi
RULE=$(awk -v n="$COLS" 'BEGIN { n = (n > 78 ? 78 : n); s = ""; while (length(s) < n) s = s "-"; print s }')

say()  { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG" 2>/dev/null; }
logo() { [ "$WIDE" -eq 1 ] && printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG" 2>/dev/null; return 0; }
hs() {
    awk -v s="$1" 'BEGIN {
        b = s * 512
        if (b >= 1073741824)   printf "%.2f GiB", b / 1073741824
        else if (b >= 1048576) printf "%.1f MiB", b / 1048576
        else                   printf "%.0f KiB", b / 1024
    }'
}
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "?"; }

say "Chameleon96 SD card info"
say "$RULE"

# ------------------------------------------------------------- the root disk
# ---------------------------------------------------------------------------
# find_root_dev -- which partition is "/" on?
#
# The obvious answer, /proc/mounts, is the WRONG place to look first on this
# board. With no initramfs the kernel mounts the root itself and reports it as
# "/dev/root", a name that usually has no device node at all, so a naive
# /dev/* test matches it and then fails on [ -b ]. In order:
#   1. /proc/cmdline root=/dev/...   -- authoritative: extlinux.conf sets
#                                       root=/dev/mmcblk0p2
#   2. /proc/mounts, SKIPPING the literal /dev/root
#   3. the device number of "/" resolved through /sys/dev/block
# ---------------------------------------------------------------------------
find_root_dev() {
    for _w in $(cat /proc/cmdline 2>/dev/null); do
        case "$_w" in root=/dev/*) echo "${_w#root=}"; return 0 ;; esac
    done
    _d=$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null)
    case "$_d" in
        /dev/root) : ;;
        /dev/*)    echo "$_d"; return 0 ;;
    esac
    _n=$(stat -c '%d' / 2>/dev/null) || _n=""
    if [ -n "$_n" ]; then
        _l=$(readlink -f "/sys/dev/block/$((_n / 256)):$((_n % 256))" 2>/dev/null) || _l=""
        [ -n "$_l" ] && { echo "/dev/$(basename "$_l")"; return 0; }
    fi
    return 1
}

ROOTDEV=$(find_root_dev) || ROOTDEV=""
PARTNAME=${ROOTDEV#/dev/}
SYSP=/sys/class/block/$PARTNAME
DISKNAME=$(basename "$(dirname "$(readlink -f "$SYSP" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)
[ -n "$DISKNAME" ] && [ -d "/sys/class/block/$DISKNAME" ] || DISKNAME=${PARTNAME%p*}
SYSD=/sys/class/block/$DISKNAME

DSIZE=$(rd "$SYSD/size")
say "Card  /dev/$DISKNAME"
say "Sect  $DSIZE"
[ "$DSIZE" != "?" ] && say "Size  $(hs "$DSIZE")"

# ---------------------------------------------------- who the card says it is
# The CID identifies the card. A card whose flash is smaller than its label
# usually still ADVERTISES the big size, so a name/size mismatch here is worth
# seeing; so is a size that is simply not what is written on the card.
DEV="$SYSD/device"
if [ -d "$DEV" ]; then
    NAME=$(rd "$DEV/name"); MANF=$(rd "$DEV/manfid"); OEM=$(rd "$DEV/oemid")
    say "Name  $NAME"
    say "Mfg   $MANF/$OEM"
    say "Date  $(rd "$DEV/date")"
    logo "  cid    : $(rd "$DEV/cid")"
    logo "  csd    : $(rd "$DEV/csd")"
    logo "  serial : $(rd "$DEV/serial")"
    logo "  type   : $(rd "$DEV/type")"
    logo "  scr    : $(rd "$DEV/scr")"
    logo "  erase  : $(rd "$DEV/preferred_erase_size")"
else
    logo "  no mmc device node"
fi
say "$RULE"

# ----------------------------------------------------------- partition table
DISKDEV=/dev/$DISKNAME
MBR=/tmp/.ch96ci.$$
trap 'rm -f "$MBR"' EXIT INT TERM
if dd if="$DISKDEV" bs=512 count=1 of="$MBR" 2>/dev/null; then
    le32() {
        _o=$1
        set -- $(dd if="$MBR" bs=1 skip="$_o" count=4 2>/dev/null | od -An -tu1)
        [ $# -eq 4 ] || { echo 0; return 0; }
        echo $(( $4 * 16777216 + $3 * 65536 + $2 * 256 + $1 ))
    }
    u8() { _v=$(dd if="$MBR" bs=1 skip="$1" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n'); echo "${_v:-0}"; }
    for n in 1 2 3 4; do
        b=$(( 446 + 16 * (n - 1) ))
        t=$(u8 $(( b + 4 ))); s=$(le32 $(( b + 8 ))); c=$(le32 $(( b + 12 )))
        [ "$t" -eq 0 ] && [ "$c" -eq 0 ] && continue
        say "p$n t=$(printf '%02x' "$t") s=$s n=$c"
    done
fi
# What the kernel thinks, which can differ from the MBR above until something
# (a reboot, or partx -u) makes it re-read the table.
for p in "$SYSD"/"$DISKNAME"p*; do
    [ -d "$p" ] || continue
    logo "  kernel $(basename "$p"): start=$(rd "$p/start") size=$(rd "$p/size")"
done
say "$RULE"

# ------------------------------------------------------------- the filesystem
if command -v dumpe2fs >/dev/null 2>&1 && [ -b "$ROOTDEV" ]; then
    dumpe2fs -h "$ROOTDEV" 2>/dev/null >> "$LOG"
    eval "$(dumpe2fs -h "$ROOTDEV" 2>/dev/null | awk -F: '
        /^Block count:/        { gsub(/ /,"",$2); print "BC="  $2 }
        /^Block size:/         { gsub(/ /,"",$2); print "BS="  $2 }
        /^Reserved GDT blocks:/{ gsub(/ /,"",$2); print "RG="  $2 }
        /^Blocks per group:/   { gsub(/ /,"",$2); print "BPG=" $2 }')"
    if [ "${BC:-0}" -gt 0 ]; then
        say "FS    $BC blk x $BS"
        say "      = $(hs $(( BC * (BS / 512) )))"
        # The ext4 online-resize ceiling goes to the log only. It is a property
        # of how the filesystem was created, not of the card in the slot, so on
        # an 8 GB card it reads "64 GiB" and looks like a promise. What belongs
        # on screen is this card's own size.
        if [ "${RG:-0}" -gt 0 ] && [ "${BPG:-0}" -gt 0 ]; then
            logo "$(awk -v r="$RG" -v bs="$BS" -v bc="$BC" -v bpg="$BPG" 'BEGIN {
                dpb = bs / 32
                curg = int((int((bc + bpg - 1) / bpg) + dpb - 1) / dpb)
                printf "  online resize ceiling: %.0f GiB (reserved GDT %d)", (curg + r) * dpb * bpg * bs / 1073741824, r
            }')"
        fi
    fi
fi
FREE=$(df -h "$ROOTDEV" 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$FREE" ] && say "Free  $FREE on /"

# Only the last 14 lines stay on screen, so the number this whole script exists
# to show is repeated here, where it cannot scroll away.
say "$RULE"
say "CARD SIZE: $(hs "$DSIZE")"

logo "  --- /proc/partitions ---"
cat /proc/partitions >> "$LOG" 2>/dev/null
logo "  --- dmesg, mmc lines ---"
dmesg 2>/dev/null | grep -i 'mmc\|mmcblk' >> "$LOG" 2>/dev/null

# Put the log where a PC can read it: /media/fat is inside the ext4 on this
# port, so the FAT boot partition has to be mounted by hand. Never fatal.
FATP=/dev/${DISKNAME}p1
if [ -b "$FATP" ] && [ "$LOG" != /dev/null ]; then
    MP=/tmp/.ch96cifat.$$
    mkdir -p "$MP" 2>/dev/null
    if mount -t vfat -o rw "$FATP" "$MP" 2>/dev/null; then
        cp "$LOG" "$MP/sdcard_info.log" 2>/dev/null && say "Log on the boot partition"
        sync; umount "$MP" 2>/dev/null
    fi
    rmdir "$MP" 2>/dev/null
fi
exit 0
