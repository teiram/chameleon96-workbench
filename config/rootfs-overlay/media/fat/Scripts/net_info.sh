#!/bin/sh
# ---------------------------------------------------------------------------
# net_info.sh -- why is there no network? Reads only, changes nothing.
#
# "The kernel sees the adapter but the OSD says No network" has four different
# causes, and they need four different fixes. This tells them apart instead of
# leaving it to guesswork:
#
#   1. the module was never BUILT           -> the kernel fragment did not take
#   2. built but not LOADED                 -> nothing called modprobe
#   3. loaded but not BOUND to the device   -> wrong driver, or nothing plugged in
#   4. bound, but the interface has NO IPv4 -> nothing ran DHCP on it
#
# Causes 2 and 4 are both configuration, and both are invisible without a
# serial console:
#
#   2. The rootfs is built with BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_DEVTMPFS=y
#      and neither mdev nor eudev, so there is NO uevent helper: device nodes
#      appear, but nothing ever runs modprobe. A module only gets loaded if
#      /etc/modules-load.d/*.conf lists it, which /etc/init.d/S11modules reads
#      at boot.
#
#   4. BR2_SYSTEM_DHCP is empty, so the /etc/network/interfaces that buildroot
#      generates carries the loopback stanza and nothing else. "ifup -a" from
#      S40network then has nothing to do for eth0, and eth0 stays without an
#      address. The overlay supplies its own copy for exactly this reason.
#
# Cause 4 is what actually decides the OSD text: Main_MiSTer's getNet() walks
# getifaddrs() and only counts an interface named exactly "eth0" (or one
# starting with "wlan") carrying an AF_INET address that is not 169.254.x.x.
#
# Scripts/net_up.sh is the one that acts on any of this.
#
# Same OSD rules as the other scripts here: stdout only, 32 characters per
# line, verdict last, and a wider layout when there is a real console.
# ---------------------------------------------------------------------------
exec 2>&1

# Parse tool output in the C locale; see the same note in expand_rootfs.sh.
LC_ALL=C
export LC_ALL

LOGDIR=/media/fat/Scripts
LOG="$LOGDIR/net_info.log"
[ -d "$LOGDIR" ] || LOG=/tmp/net_info.log
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

KREL=$(uname -r)
drv_of() {  # drv_of <sysfs dir> -- the driver bound to it, or empty
    [ -L "$1/driver" ] || return 1
    basename "$(readlink -f "$1/driver" 2>/dev/null)" 2>/dev/null
}

say "Chameleon96 network info"
say "$RULE"

# ---------------------------------------------------------------- interfaces
say "Interfaces:"
REAL=0
HAVEIP=0
NOIP=""
for d in /sys/class/net/*; do
    n=$(basename "$d")
    [ "$n" = lo ] && continue
    _c=$(cat "$d/carrier" 2>/dev/null || echo "?")
    _dr=$(drv_of "$d/device" 2>/dev/null) || _dr=""
    # sit0, ifb*, tunl* and friends are virtual: no device dir, no driver.
    if [ -e "$d/device" ]; then
        REAL=$((REAL + 1))
        _ip=$(ip -4 addr show "$n" 2>/dev/null | awk '/inet /{print $2; exit}')
        say "  $n carrier=$_c ${_dr:+drv=$_dr}"
        if [ -n "$_ip" ]; then
            say "     $_ip"
            HAVEIP=$((HAVEIP + 1))
        else
            say "     no IPv4"
            NOIP="$NOIP $n"
        fi
    else
        say "  $n (virtual)"
    fi
done
[ "$REAL" -eq 0 ] && say "  no real interface at all"
say "$RULE"

# -------------------------------------------------------------- usb devices
say "USB devices:"
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    _id="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
    _p=$(cat "$d/product" 2>/dev/null | cut -c1-14)
    # The driver lives on the INTERFACE (dev:1.0), not on the device node.
    _bound=""
    for i in "$d":*; do
        [ -d "$i" ] || continue
        _x=$(drv_of "$i") && { _bound="$_bound${_bound:+,}$_x"; }
    done
    if [ -n "$_bound" ]; then
        say "  $_id $_bound"
    else
        say "  $_id NO DRIVER"
    fi
    logo "      product: $_p"
done
say "$RULE"

# ----------------------------------------------------------------- modules
# Three states, and the difference is the whole point of this script.
say "Modules:"
NOFILE=""; NOTLOADED=""
for m in r8152; do
    _f=$(find "/lib/modules/$KREL" -name "$m.ko*" 2>/dev/null | head -1)
    if [ -d "/sys/module/$m" ]; then
        say "  $m built=yes loaded=YES"
    elif [ -n "$_f" ]; then
        say "  $m built=yes loaded=no"
        NOTLOADED="$NOTLOADED $m"
    else
        say "  $m NOT BUILT"
        NOFILE="$NOFILE $m"
    fi
    [ -n "$_f" ] && logo "      $_f"
done
say "$RULE"

# ------------------------------------------------- how modules get loaded here
AUTOLOAD=no
[ -n "$(cat /proc/sys/kernel/hotplug 2>/dev/null)" ] && AUTOLOAD=yes
[ -d /sys/class/mdev ] && AUTOLOAD=yes
pidof udevd >/dev/null 2>&1 && AUTOLOAD=yes
say "Autoload helper: $AUTOLOAD"
if [ -d /etc/modules-load.d ]; then
    _n=$(ls /etc/modules-load.d/*.conf 2>/dev/null | wc -l)
    say "modules-load.d: $_n file(s)"
    for f in /etc/modules-load.d/*.conf; do
        [ -r "$f" ] || continue
        logo "  --- $f ---"
        while IFS= read -r l; do
            case "$l" in ''|\#*) continue ;; esac
            logo "      $l"
        done < "$f"
    done
else
    say "modules-load.d: MISSING"
fi
say "$RULE"

# ------------------------------------------------- how an address gets asked for
# A loaded, bound driver with no lease is still "No network" in the OSD, so
# the DHCP side deserves the same treatment as the module side.
say "DHCP config:"
DHCPSTANZA=no
if [ -r /etc/network/interfaces ]; then
    if grep -qE '^[[:space:]]*iface[[:space:]]+eth0[[:space:]]+inet[[:space:]]+dhcp' \
            /etc/network/interfaces 2>/dev/null; then
        DHCPSTANZA=yes
        say "  eth0 dhcp stanza: yes"
    else
        say "  eth0 dhcp stanza: NO"
    fi
    while IFS= read -r l; do
        case "$l" in ''|\#*) continue ;; esac
        logo "      $l"
    done < /etc/network/interfaces
else
    say "  /etc/network/interfaces"
    say "  MISSING"
fi
if [ -x /usr/share/udhcpc/default.script ]; then
    say "  udhcpc script: yes"
else
    say "  udhcpc script: NO"
fi
_gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
say "  default route: ${_gw:-none}"
_dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
say "  dns: ${_dns:-none}"

logo ""
logo "  --- lsmod ---"
if [ "$WIDE" -eq 1 ]; then
    lsmod 2>/dev/null | while IFS= read -r l; do logo "  $l"; done
else
    lsmod 2>/dev/null >> "$LOG"
fi
logo "  --- dmesg: usb / eth ---"
if [ "$WIDE" -eq 1 ]; then
    dmesg 2>/dev/null | grep -iE 'usb|eth|r8152' | tail -20 \
        | while IFS= read -r l; do logo "  $(printf '%.76s' "$l")"; done
else
    dmesg 2>/dev/null | grep -iE 'usb|eth|r8152' | tail -40 >> "$LOG"
fi

# ----------------------------------------------------------------- verdict
say "$RULE"
if [ -n "$NOFILE" ]; then
    say "VERDICT: modules NOT BUILT"
    for _m in $NOFILE; do say "  $_m"; done
    say ""
    say "The kernel fragment did not"
    say "take. On the PC run:"
    say "  ./build.sh"
elif [ -n "$NOTLOADED" ]; then
    say "VERDICT: built but NOT LOADED"
    for _m in $NOTLOADED; do say "  $_m"; done
    say ""
    say "There is no uevent helper on"
    say "this rootfs (devtmpfs only),"
    say "so nothing calls modprobe."
    say "They must be listed in"
    say "/etc/modules-load.d/*.conf"
    say ""
    say "To try right now:"
    say "  Scripts -> net_up"
elif [ "$REAL" -eq 0 ]; then
    say "VERDICT: modules loaded, but"
    say "nothing bound. Is the"
    say "adapter plugged in? Wrong"
    say "driver for this chip?"
elif [ "$HAVEIP" -eq 0 ]; then
    say "VERDICT: driver OK, NO IPv4"
    for _m in $NOIP; do say "  $_m"; done
    say ""
    if [ "$DHCPSTANZA" = no ]; then
        say "No dhcp stanza for eth0 in"
        say "/etc/network/interfaces, so"
        say "ifup -a at boot never asks"
        say "for a lease. The OSD reads"
        say "an interface WITHOUT an"
        say "address as 'No network'."
    else
        say "The stanza is there, so the"
        say "lease itself failed: cable,"
        say "or no DHCP server."
    fi
    say ""
    say "To try right now:"
    say "  Scripts -> net_up"
else
    say "VERDICT: interfaces are up."
fi
exit 0
