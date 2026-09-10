#!/bin/sh
# ---------------------------------------------------------------------------
# net_up.sh -- load the wired driver and get an address, right now.
#
# At boot none of this is needed. Two files in the rootfs overlay do it:
#
#   /etc/modules-load.d/ch96-net.conf   loads r8152, because this rootfs has
#                                       no uevent helper and nothing ever
#                                       calls modprobe on its own
#   /etc/network/interfaces             gives eth0 a dhcp stanza, so the
#                                       "ifup -a" in S40network really does
#                                       ask for a lease
#
# This is for what those two cannot cover: plugging the adapter in with the
# board already running. The driver is resident, so eth0 appears by itself,
# but with no uevent helper nothing asks for an address -- and an interface
# without one reads as "No network" in the OSD, because Main_MiSTer's getNet()
# only counts an interface named exactly "eth0" (or "wlan*") carrying an
# AF_INET address that is not 169.254.x.x.
#
# It is also how to test the fix before rewriting the card. It writes nothing
# outside /var and /tmp. Scripts/net_info.sh diagnoses without touching
# anything.
# ---------------------------------------------------------------------------
exec 2>&1

# Parse tool output in the C locale; see the same note in expand_rootfs.sh.
LC_ALL=C
export LC_ALL

LOGDIR=/media/fat/Scripts
LOG="$LOGDIR/net_up.log"
[ -d "$LOGDIR" ] || LOG=/tmp/net_up.log
: > "$LOG" 2>/dev/null || LOG=/dev/null

COLS=32
WIDE=0
if [ -t 1 ]; then
    WIDE=1; COLS=80
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

ipv4_of() {   # ipv4_of <iface> -- the address, or empty
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2; exit}'
}

say "Chameleon96 network up"
say "$RULE"

# ------------------------------------------------------------- 1. the driver
# Prefer the list the boot uses, so this script and the boot agree; fall back
# to the wired driver alone if the file is not there yet.
MODS=""
if [ -r /etc/modules-load.d/ch96-net.conf ]; then
    MODS=$(sed 's/#.*//' /etc/modules-load.d/ch96-net.conf | awk 'NF { print $1 }')
fi
[ -n "$MODS" ] || MODS=r8152

say "Modules:"
MISSING=""
for m in $MODS; do
    if [ -d "/sys/module/$m" ]; then
        say "  $m already loaded"
        continue
    fi
    _out=$(modprobe "$m" 2>&1)
    if [ -d "/sys/module/$m" ]; then
        say "  $m loaded now"
    else
        say "  $m FAILED"
        MISSING="$MISSING $m"
        [ -n "$_out" ] && logo "      $_out"
    fi
done
say "$RULE"

# ---------------------------------------------------------- 2. the interface
# A USB driver binds asynchronously: the module returns before the netdev is
# registered, so give it a moment rather than declaring failure immediately.
IFACE=""
_n=0
while [ "$_n" -lt 10 ]; do
    if [ -e /sys/class/net/eth0 ]; then IFACE=eth0; break; fi
    for d in /sys/class/net/*; do
        _c=$(basename "$d")
        [ "$_c" = lo ] && continue
        [ -e "$d/device" ] || continue
        IFACE=$_c
        break
    done
    [ -n "$IFACE" ] && break
    _n=$((_n + 1))
    sleep 1
done

if [ -z "$IFACE" ]; then
    say "No wired interface appeared."
    say ""
    if [ -n "$MISSING" ]; then
        say "The driver did not load:"
        for m in $MISSING; do say "  $m"; done
        say ""
        say "It is probably NOT BUILT."
        say "Run net_info for the"
        say "verdict, then rebuild the"
        say "kernel on the PC."
    else
        say "The driver loaded but did"
        say "not claim any device."
        say "Is the adapter plugged in?"
    fi
    exit 1
fi

say "Interface: $IFACE"
if [ "$IFACE" != eth0 ]; then
    say ""
    say "NOTE: the OSD only shows an"
    say "interface named eth0 or"
    say "wlan*, so this one will not"
    say "appear in Information."
    say ""
fi

CUR=$(ipv4_of "$IFACE")
if [ -n "$CUR" ]; then
    say "Already has: $CUR"
    say "Nothing to do."
    say "$RULE"
    ip route 2>/dev/null | while IFS= read -r l; do logo "  $l"; done
    exit 0
fi

# ------------------------------------------------------------------ 3. lease
say "Asking for a lease..."
ip link set "$IFACE" up 2>/dev/null

USED=""
if grep -qE "^[[:space:]]*iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" \
        /etc/network/interfaces 2>/dev/null; then
    # There is a stanza: go through ifup so the result matches what the boot
    # would do. ifdown first, because busybox refuses to bring up an
    # interface it already has marked as configured in /var/run/ifstate.
    ifdown "$IFACE" >/dev/null 2>&1
    _out=$(ifup "$IFACE" 2>&1)
    USED="ifup"
else
    say "  (no dhcp stanza for it in"
    say "   /etc/network/interfaces,"
    say "   calling udhcpc directly)"
    _out=$(udhcpc -i "$IFACE" -n -q -t 6 -T 2 2>&1)
    USED="udhcpc"
fi
printf '%s\n' "$_out" >> "$LOG" 2>/dev/null
[ "$WIDE" -eq 1 ] && printf '%s\n' "$_out" | while IFS= read -r l; do logo "  $l"; done

# ifup does NOT wait for the lease. Buildroot's busybox is built with
# CONFIG_IFUPDOWN_UDHCPC_CMD_OPTIONS="-t1 -A3 -b -R -O search -O staticroutes":
# -t1 sends one discover and -b puts udhcpc in the background if that one
# fails, so ifup returns almost immediately and the address turns up a second
# or two later. Reading the address right here would report failure on a
# perfectly good connection, so poll instead.
NEW=""
_n=0
while [ "$_n" -lt 15 ]; do
    NEW=$(ipv4_of "$IFACE")
    [ -n "$NEW" ] && break
    _n=$((_n + 1))
    sleep 1
done
say "$RULE"
if [ -z "$NEW" ]; then
    say "No address after 15 s"
    say "($USED)."
    say ""
    say "Cable plugged in? Is there a"
    say "DHCP server on this LAN?"
    say "carrier=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo '?')"
    say "Detail: $LOG"
    exit 1
fi

say "Address: $NEW"
_gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
[ -n "$_gw" ] && say "Gateway: $_gw"
_dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
[ -n "$_dns" ] && say "DNS:     $_dns"
say ""
say "The OSD Information panel"
say "should show it within two"
say "seconds (it refreshes on a"
say "2 s timer)."
exit 0
