#!/bin/sh
# ---------------------------------------------------------------------------
# expand_rootfs.sh -- grow the Linux (ext4) partition of the running card to
# the whole medium, then grow the filesystem inside it.
#
# Online: no reboot, no unmount, nothing to do on a PC. Run it from the MiSTer
# OSD (Scripts -> expand_rootfs), or from a shell with:
#
#     /media/fat/Scripts/expand_rootfs.sh            report, then do it
#     /media/fat/Scripts/expand_rootfs.sh --report   report only, changes nothing
#
# The image built by genimage gives the rootfs a fixed 300M partition, which is
# what fits every card. This is what claims the rest of whatever card the board
# is actually running from.
#
# ---------------------------------------------------------------------------
# WRITTEN FOR THE MiSTer OSD. The rules below come from reading
# Main_MiSTer_ch96/menu.cpp, not from guesswork:
#
#   * With fb_terminal=0, MENU_SCRIPTS runs the script through popen(path, "r"),
#     so ONLY STDOUT is captured. Anything on stderr is thrown away -- hence the
#     "exec 2>&1" below. Without it a failure would show as an empty window.
#
#   * Each line read with fgets() is drawn with OsdWrite(). OSDLINELEN is 256
#     pixels and the font is 8 pixels wide, so a line is 32 CHARACTERS. Longer
#     lines are simply cut off. Every line this script prints is <= 32.
#
#   * Only the last OsdGetSize()-2 lines stay on screen (14 with the usual
#     OsdSetSize(16)); earlier ones scroll away. So the summary goes LAST.
#
#   * There is no stdin, so the script cannot ask anything. It does not need
#     to: the OSD already asks for confirmation before running any script.
#
#   * With fb_terminal=1, MiSTer instead forks
#         /sbin/agetty -a root -l /tmp/script --nohostname -L tty2 linux
#     on a wrapper whose shebang is hard-coded to #!/bin/bash. That path needs
#     /bin/bash and /sbin/agetty in the rootfs and tty2 free of any getty --
#     see config/rootfs-overlay/etc/inittab. It gives a real 80-column console,
#     which is why this script prints more when stdout is a tty.
#
# ---------------------------------------------------------------------------
# 32-BIT ARITHMETIC. BusyBox ash on 32-bit ARM is not guaranteed 64-bit in
# $(( )). A 32 GB card is 62,333,952 sectors (fine, fits in 31 bits) but
# 31,914,983,424 BYTES (does not). So every calculation here stays in SECTORS,
# and byte/GiB formatting is handed to awk, which uses doubles.
# ---------------------------------------------------------------------------

# MiSTer's popen() captures stdout only. Send everything there.
exec 2>&1

# Parse numbers and tool output in the C locale. MiSTer's fb_terminal wrapper
# exports LC_ALL=en_US.UTF-8, under which awk and friends may format decimals
# with a comma; every figure below is produced by awk and compared as a number,
# so the locale is pinned rather than inherited.
LC_ALL=C
export LC_ALL

MODE=apply
case "$1" in
    --report|-n)  MODE=report ;;
    --apply|"")   MODE=apply ;;
    -h|--help)    echo "usage: expand_rootfs.sh [--report]"; exit 0 ;;
    *)            echo "unknown option: $1"; exit 2 ;;
esac

LOGDIR=/media/fat/Scripts
LOG="$LOGDIR/expand_rootfs.log"
[ -d "$LOGDIR" ] || LOG=/tmp/expand_rootfs.log
: > "$LOG" 2>/dev/null || LOG=/dev/null

# Where is the output going? The two OSD modes are told apart by one test:
#
#   fb_terminal=0 -> stdout is a PIPE. 32 columns, 14 visible lines, and the
#                    detail stays in the log.
#   fb_terminal=1 -> stdout is a TTY with a real console behind it. There is
#                    room for the whole story, so the detail goes to the screen.
#
# Everything still works if the detection fails: the fallback is the narrow
# layout, which is readable either way.
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

# say():  screen + log. Kept <= 32 chars so it fits the OSD window too.
# logo(): log always; screen as well when there is a wide console to hold it.
say()  { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG" 2>/dev/null; }
logo() { [ "$WIDE" -eq 1 ] && printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG" 2>/dev/null; return 0; }

# sectors -> human, in awk so we never overflow the shell's integers
hs() {
    awk -v s="$1" 'BEGIN {
        b = s * 512
        if (b >= 1073741824)   printf "%.2f GiB", b / 1073741824
        else if (b >= 1048576) printf "%.1f MiB", b / 1048576
        else                   printf "%.0f KiB", b / 1024
    }'
}

die() { say "$RULE"; say "FAILED: $1"; say "Nothing has been changed."; exit 1; }

say "Chameleon96 rootfs expand"
say "$RULE"

# ------------------------------------------------------------ 1. find the card
# ---------------------------------------------------------------------------
# find_root_dev -- which partition is "/" on?
#
# The obvious answer, /proc/mounts, is the WRONG place to look first on this
# board. With no initramfs the kernel mounts the root itself and reports it as
# "/dev/root", a name that usually has no device node at all -- so a check like
#     case "$ROOTDEV" in /dev/*) ;; *) fall back ;; esac
# matches "/dev/root", never falls back, and then dies on [ -b ].
#
# So, in order:
#   1. /proc/cmdline root=/dev/...   -- authoritative here: extlinux.conf sets
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

ROOTDEV=$(find_root_dev) || die "cannot work out which partition the root is"
[ -b "$ROOTDEV" ] || die "$ROOTDEV is not a block device"

PARTNAME=${ROOTDEV#/dev/}
SYSP=/sys/class/block/$PARTNAME
[ -d "$SYSP" ] || die "no sysfs entry for $PARTNAME"

# Ask sysfs which disk this partition belongs to, and which slot it is, instead
# of taking the name apart with sed. /sys/class/block/<part> is a symlink into
# the disk's own directory, so the parent is the disk -- true for mmcblk0p2,
# sda2, loop0p2 and anything else, with no naming rules to get wrong.
DISKNAME=""
if command -v readlink >/dev/null 2>&1; then
    DISKNAME=$(basename "$(dirname "$(readlink -f "$SYSP" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)
fi
[ -n "$DISKNAME" ] && [ -d "/sys/class/block/$DISKNAME" ] || case "$PARTNAME" in
    *p[0-9]*) DISKNAME=${PARTNAME%p*} ;;
    *)        DISKNAME=$(printf '%s' "$PARTNAME" | sed 's/[0-9]*$//') ;;
esac

PARTNUM=$(cat "$SYSP/partition" 2>/dev/null)
[ -n "$PARTNUM" ] || PARTNUM=$(printf '%s' "$PARTNAME" | sed 's/.*[^0-9]//')

DISKDEV=/dev/$DISKNAME
[ -b "$DISKDEV" ] || die "no disk device $DISKDEV"

SYSD=/sys/class/block/$DISKNAME
[ -r "$SYSP/start" ] && [ -r "$SYSD/size" ] || die "sysfs has no size info"

PSTART=$(cat "$SYSP/start")
PSIZE=$(cat "$SYSP/size")
DSIZE=$(cat "$SYSD/size")

say "Card   $DISKDEV"
say "Size   $(hs "$DSIZE")"
logo "  root device  : $ROOTDEV"
logo "  disk sectors : $DSIZE"
logo "  part start   : $PSTART"
logo "  part sectors : $PSIZE"

# ------------------------------------------------------- 2. read the raw MBR
MBR=/tmp/.ch96mbr.$$
trap 'rm -f "$MBR" "$MBR.new"' EXIT INT TERM
dd if="$DISKDEV" bs=512 count=1 of="$MBR" 2>/dev/null || die "cannot read the MBR"

le32() {   # le32 <byte offset in $MBR>
    _o=$1
    set -- $(dd if="$MBR" bs=1 skip="$_o" count=4 2>/dev/null | od -An -tu1)
    [ $# -eq 4 ] || { echo 0; return 0; }
    echo $(( $4 * 16777216 + $3 * 65536 + $2 * 256 + $1 ))
}
u8() {
    _v=$(dd if="$MBR" bs=1 skip="$1" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
    echo "${_v:-0}"
}

SIG=$(( $(u8 511) * 256 + $(u8 510) ))
[ "$SIG" -eq 43605 ] || die "no MBR signature on the card"

# Entry N is at 446 + 16*(N-1): +4 type, +8 start LBA, +12 sector count.
SLOT=0
logo "  --- MBR ---"
for n in 1 2 3 4; do
    base=$(( 446 + 16 * (n - 1) ))
    t=$(u8 $(( base + 4 )))
    s=$(le32 $(( base + 8 )))
    c=$(le32 $(( base + 12 )))
    eval "T$n=$t; S$n=$s; C$n=$c; E$n=$(( s + c ))"
    logo "  p$n type=$t start=$s count=$c"
    [ "$t" -ne 0 ] && [ "$c" -ne 0 ] && [ "$s" -eq "$PSTART" ] && SLOT=$n
done

# The MBR slot is found by matching the START SECTOR against sysfs, never by
# trusting the partition number. genimage declares the partitions out of
# physical order (a2 is slot 3 but sits first on the card), so "the last entry"
# and "the highest slot" are both the wrong thing to grow.
[ "$SLOT" -ne 0 ] || die "root not found in the MBR"
if [ "$SLOT" -ne "$PARTNUM" ]; then
    say "$RULE"
    say "MBR slot $SLOT != device p$PARTNUM"
    die "partition table looks renumbered"
fi
logo "  mbr slot     : $SLOT (start $PSTART)"

# --------------------------------------------- 3. is there room, and is it free?
BEHIND=""
for n in 1 2 3 4; do
    [ "$n" -eq "$SLOT" ] && continue
    eval "t=\$T$n; c=\$C$n; s=\$S$n"
    [ "$t" -eq 0 ] && [ "$c" -eq 0 ] && continue
    eval "e=\$E$SLOT"
    [ "$s" -ge "$e" ] && BEHIND="$BEHIND p$n"
done
[ -z "$BEHIND" ] || { say "Partition behind root:$BEHIND"; die "cannot grow in place"; }

NEWSIZE=$(( DSIZE - PSTART ))
GAIN=$(( NEWSIZE - PSIZE ))

say "Root   $ROOTDEV slot $SLOT"
say "Part   $(hs "$PSIZE")"

# --------------------------------------------------- 4. the filesystem itself
FSBLK=0; FSBS=0; FSSECT=0
if command -v dumpe2fs >/dev/null 2>&1; then
    eval "$(dumpe2fs -h "$ROOTDEV" 2>/dev/null | awk -F: '
        /^Block count:/       { gsub(/ /,"",$2); print "FSBLK="  $2 }
        /^Block size:/        { gsub(/ /,"",$2); print "FSBS="   $2 }
        /^Reserved GDT blocks:/{gsub(/ /,"",$2); print "FSRGDT=" $2 }')"
fi
if [ "${FSBLK:-0}" -gt 0 ] && [ "${FSBS:-0}" -gt 0 ]; then
    FSSECT=$(( FSBLK * (FSBS / 512) ))
    say "FS     $(hs "$FSSECT")"
fi
say "Unused $(hs "$GAIN")"

# How far an ONLINE resize can go is fixed by the reserved GDT blocks written
# at mke2fs time. Worked out here but deliberately NOT printed on its own: it
# describes how the filesystem was created, not the card in the slot, so on an
# 8 GB card it reads "64 GiB" and looks like a promise the card cannot keep.
# It is only ever mentioned below, and only if it would actually get in the way.
# Done in awk because the block counts overflow 32-bit shell arithmetic.
CEIL_SECT=0
if [ "${FSRGDT:-0}" -gt 0 ] && [ "${FSBS:-0}" -gt 0 ] && [ "${FSBLK:-0}" -gt 0 ]; then
    CEIL_SECT=$(awk -v r="$FSRGDT" -v bs="$FSBS" -v bc="$FSBLK" 'BEGIN {
        bpg  = bs * 8                      # blocks per group
        dpb  = bs / 32                     # group descriptors per block
        cur  = int((bc + bpg - 1) / bpg)   # groups now
        curg = int((cur + dpb - 1) / dpb)  # GDT blocks now
        printf "%.0f", (curg + r) * dpb * bpg * (bs / 512)
    }')
    logo "  online ceiling sectors: $CEIL_SECT"
fi

# ------------------------------------------------------------- 5. the verdict
#
# TWO INDEPENDENT QUESTIONS, and they must be asked separately:
#
#   a) can the PARTITION grow?    disk end   vs  partition end
#   b) can the FILESYSTEM grow?   partition  vs  filesystem
#
# Asking only (a) is a bug: if a previous run grew the partition but the
# resize2fs step then failed, (a) is already satisfied while the filesystem is
# still small. Judging by (a) alone would answer "already using the whole card"
# and leave the card half-done for good.
TARGET=$PSIZE
[ "$GAIN" -gt 2048 ] && TARGET=$NEWSIZE

FSGAIN=0
[ "$FSSECT" -gt 0 ] && FSGAIN=$(( TARGET - FSSECT ))

if [ "$GAIN" -le 2048 ] && [ "$FSGAIN" -le 2048 ]; then
    say "$RULE"
    say "Already using the whole card"
    say "Nothing to do."
    exit 0
fi

# Mentioned only when it would actually bite. Reported, not enforced: the
# figure is derived, and refusing to try on the strength of a derivation would
# be worse than letting resize2fs give its own verdict.
if [ "$CEIL_SECT" -gt 0 ] && [ "$TARGET" -gt "$CEIL_SECT" ]; then
    say "$RULE"
    say "Note: this filesystem can only"
    say "grow online to $(hs "$CEIL_SECT")."
    say "The rest of the partition would"
    say "stay unused."
fi

if [ "$MODE" = report ]; then
    say "$RULE"
    if [ "$GAIN" -gt 2048 ]; then
        say "CAN GROW to $(hs "$NEWSIZE")"
    else
        say "Partition already full, but"
        say "the FS is $(hs "$FSGAIN") short."
    fi
    say "Report only: nothing changed."
    exit 0
fi

# ============================== APPLY =====================================
say "$RULE"

if [ "$GAIN" -le 2048 ]; then
    # Partition is already right; only the filesystem is behind. Skip straight
    # to the resize instead of rewriting an MBR entry that is already correct.
    say "Partition already full"
    REBOOT=no
    SKIP_MBR=yes
else
    SKIP_MBR=no
fi

if [ "$SKIP_MBR" = no ]; then
say "Step 1: rewriting the MBR"

OFF=$(( 446 + 16 * (SLOT - 1) + 12 ))
b0=$((  NEWSIZE        % 256 ))
b1=$(( (NEWSIZE / 256) % 256 ))
b2=$(( (NEWSIZE / 65536) % 256 ))
b3=$(( (NEWSIZE / 16777216) % 256 ))
logo "  writing $NEWSIZE at byte $OFF ($b0 $b1 $b2 $b3)"

printf "$(printf '\\%03o\\%03o\\%03o\\%03o' "$b0" "$b1" "$b2" "$b3")" \
    | dd of="$DISKDEV" bs=1 seek="$OFF" count=4 conv=notrunc 2>/dev/null \
    || die "could not write the MBR"
sync

# Read it back. If it did not land, put the old value back and stop.
dd if="$DISKDEV" bs=512 count=1 of="$MBR" 2>/dev/null
CHECK=$(le32 $(( 446 + 16 * (SLOT - 1) + 12 )))
if [ "$CHECK" -ne "$NEWSIZE" ]; then
    o0=$((  PSIZE        % 256 )); o1=$(( (PSIZE / 256) % 256 ))
    o2=$(( (PSIZE / 65536) % 256 )); o3=$(( (PSIZE / 16777216) % 256 ))
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' "$o0" "$o1" "$o2" "$o3")" \
        | dd of="$DISKDEV" bs=1 seek="$OFF" count=4 conv=notrunc 2>/dev/null
    sync
    die "MBR write did not stick"
fi
say "      new size $NEWSIZE sec"

# ------------------------------------------------- 6. tell the running kernel
say "Step 2: telling the kernel"
REBOOT=no
if command -v partx >/dev/null 2>&1; then
    partx -u "$DISKDEV" >/dev/null 2>&1 || true
else
    logo "  partx missing"
fi

# partx uses the BLKPG ioctl, which works while the partition is mounted.
# Give sysfs a moment to catch up before believing it failed.
i=0
while [ "$i" -lt 20 ]; do
    NOW=$(cat "$SYSP/size" 2>/dev/null || echo 0)
    [ "$NOW" = "$NEWSIZE" ] && break
    i=$(( i + 1 ))
    sleep 1
done
NOW=$(cat "$SYSP/size" 2>/dev/null || echo 0)
if [ "$NOW" = "$NEWSIZE" ]; then
    say "      kernel updated"
else
    say "      kernel still sees old size"
    REBOOT=yes
fi

fi   # end of SKIP_MBR = no

# ------------------------------------------------------ 7. grow the filesystem
if [ "$REBOOT" = yes ]; then
    say "Step 3: skipped, needs reboot"

    say "$RULE"
    say "Partition grown, FS not yet."
    say "Before $(hs "$PSIZE")"
    say "Part   $(hs "$NEWSIZE")"
    say ""
    say "*** REBOOT REQUIRED ***"
    say "Then run this script again."
    exit 0
fi

say "Step 3: growing the FS"
command -v resize2fs >/dev/null 2>&1 || die "resize2fs is not installed"

# Whether e2fsck has to run first depends entirely on the mount state:
#
#   mounted   -> resize2fs takes the ONLINE path (an ext4 ioctl). It does not
#                want a prior fsck, and running e2fsck on a mounted filesystem
#                is a good way to corrupt one. So: never.
#   unmounted -> resize2fs refuses outright with "Please run 'e2fsck -f' first",
#                so it has to run, and it is safe there.
#
# On the board this is always the mounted case, because it IS the root. The
# other branch is for running the tool from a rescue shell.
if awk -v d="$ROOTDEV" '$1 == d { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null; then
    logo "  $ROOTDEV is mounted -> online resize, no e2fsck"
else
    say "      not mounted: checking"
    logo "  $ROOTDEV is NOT mounted -> offline resize, e2fsck first"
    e2fsck -fp "$ROOTDEV" >/dev/null 2>&1
    logo "  e2fsck rc=$?"
fi

RZOUT=$(resize2fs "$ROOTDEV" 2>&1)
RZRC=$?
logo "  resize2fs rc=$RZRC"
logo "$RZOUT"
if [ "$RZRC" -ne 0 ]; then
    say "      resize2fs failed ($RZRC)"
    say "$RULE"
    say "Partition is now $(hs "$NEWSIZE")"
    say "but the FS was not grown."
    say "Reboot and run this again."
    exit 1
fi
say "      done"

say "Step 4: checking"
sync

# Measure the result rather than reporting what we asked for: re-read sysfs and
# the superblock, so the summary is what the card actually is now.
ENDPART=$(cat "$SYSP/size" 2>/dev/null || echo 0)
ENDFS=0
if command -v dumpe2fs >/dev/null 2>&1; then
    ENDFS=$(dumpe2fs -h "$ROOTDEV" 2>/dev/null | awk -F: -v bs="$FSBS" '
        /^Block count:/ { gsub(/ /,"",$2); printf "%.0f", $2 * (bs / 512) }')
fi
[ -n "$ENDFS" ] || ENDFS=0

# ----------------------------------------------------------------- 8. summary
say "$RULE"
say "Part  $(hs "$PSIZE") -> $(hs "$ENDPART")"
[ "$FSSECT" -gt 0 ] && [ "$ENDFS" -gt 0 ] \
    && say "FS    $(hs "$FSSECT") -> $(hs "$ENDFS")"
FREEH=$(df -h "$ROOTDEV" 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$FREEH" ] && say "Free space now: $FREEH"
say ""
say "REBOOT: not needed"

# Copy the log onto the FAT partition so it can be read from a PC. /media/fat
# is a plain directory in the ext4 here, not a mount of the boot partition, so
# the FAT has to be mounted by hand. Entirely optional: never fatal.
FATP=/dev/${DISKNAME}p1
if [ -b "$FATP" ] && [ "$LOG" != /dev/null ]; then
    MP=/tmp/.ch96fat.$$
    mkdir -p "$MP" 2>/dev/null
    if mount -t vfat -o rw "$FATP" "$MP" 2>/dev/null; then
        cp "$LOG" "$MP/expand_rootfs.log" 2>/dev/null && say "Log also on the boot part."
        sync; umount "$MP" 2>/dev/null
    fi
    rmdir "$MP" 2>/dev/null
fi

exit 0
