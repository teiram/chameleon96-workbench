#!/bin/sh
# ---------------------------------------------------------------------------
# ssh_status.sh -- is SSH going to let me in, and if not, which piece is missing?
#
# Six things all have to be true, and when one is missing the symptom usually
# looks like one of the others:
#
#   1. sshd and ssh-keygen are in the rootfs
#   2. host keys exist in /etc/ssh
#   3. sshd is running and listening
#   4. sshd_config permits root with a password
#   5. root actually HAS that password
#   6. /dev/pts is mounted, or every session dies at "PTY allocation request
#      failed on channel 0" -- after a successful authentication
#
# Points 1 and 4 are the quiet ones. S50sshd opens with
#     [ -f /usr/bin/ssh-keygen ] || exit 0
# so a missing key utility means the daemon exits with status 0 at every boot
# and logs nothing at all; and OpenSSH's built-in PermitRootLogin default has
# been prohibit-password since 7.0, so an unset directive refuses exactly the
# login we want.
#
# Point 5 is checked properly rather than guessed: the stored hash carries its
# own salt, so hashing "1" with that same salt and comparing says whether the
# MiSTer password is really in place. The hash itself is never printed.
#
# Reads only. Changes nothing.
#
# Same OSD rules as the other scripts here: stdout only, 32 characters per
# line, verdict last.
# ---------------------------------------------------------------------------
exec 2>&1

# Parse tool output in the C locale; see the same note in expand_rootfs.sh.
LC_ALL=C
export LC_ALL

LOGDIR=/media/fat/Scripts
LOG="$LOGDIR/ssh_status.log"
[ -d "$LOGDIR" ] || LOG=/tmp/ssh_status.log
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

CONF=/etc/ssh/sshd_config
FAIL=""

say "Chameleon96 SSH status"
say "$RULE"

# ------------------------------------------------------------- 1. binaries
say "Binaries:"
SSHD=""
for p in /usr/sbin/sshd /sbin/sshd /usr/bin/sshd; do
    [ -x "$p" ] && { SSHD=$p; break; }
done
if [ -n "$SSHD" ]; then
    say "  sshd: yes"
    logo "      $SSHD"
else
    say "  sshd: NOT BUILT"
    FAIL="$FAIL sshd"
fi
if [ -x /usr/bin/ssh-keygen ]; then
    say "  ssh-keygen: yes"
else
    # This one is quietly fatal: S50sshd's first line is
    #   [ -f /usr/bin/ssh-keygen ] || exit 0
    # so without it the daemon never starts and nothing is logged.
    say "  ssh-keygen: NOT BUILT"
    FAIL="$FAIL ssh-keygen"
fi
[ -x /usr/bin/ssh ] && say "  ssh client: yes" || say "  ssh client: no"
say "$RULE"

# ------------------------------------------------------------ 2. host keys
say "Host keys:"
NKEYS=0
for k in /etc/ssh/ssh_host_*_key; do
    [ -f "$k" ] || continue
    NKEYS=$((NKEYS + 1))
    _t=$(basename "$k"); _t=${_t#ssh_host_}; _t=${_t%_key}
    say "  $_t"
done
if [ "$NKEYS" -eq 0 ]; then
    say "  none yet"
    say "  (S50sshd runs ssh-keygen -A"
    say "   at start and makes them)"
fi
say "$RULE"

# --------------------------------------------------------------- 3. daemon
say "Daemon:"
PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2; exit }' "$CONF" 2>/dev/null)
PORT=${PORT:-22}
if pidof sshd >/dev/null 2>&1; then
    say "  running: yes"
else
    say "  running: NO"
    FAIL="$FAIL not-running"
fi

# TCP state 0A is LISTEN; the local port is the hex after the colon in field 2.
listening() {
    _hex=$(printf '%04X' "$1")
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        awk -v p=":$_hex" '$4 == "0A" && index($2, p) { n = 1 } END { exit !n }' "$f" 2>/dev/null && return 0
    done
    return 1
}
if listening "$PORT"; then
    say "  listening on $PORT: yes"
else
    say "  listening on $PORT: NO"
    FAIL="$FAIL not-listening"
fi
say "$RULE"

# ---------------------------------------------------------------- 4. config
say "Config:"
if [ -r "$CONF" ]; then
    _prl=$(awk '/^[[:space:]]*PermitRootLogin/ { print $2; exit }' "$CONF")
    _pa=$(awk '/^[[:space:]]*PasswordAuthentication/ { print $2; exit }' "$CONF")
    # Unset is not the same as "no": the compiled-in default for
    # PermitRootLogin has been prohibit-password since OpenSSH 7.0, which
    # refuses exactly the login we want.
    case "$_prl" in
        yes) say "  PermitRootLogin: yes" ;;
        "")  say "  PermitRootLogin: unset"
             say "   -> defaults to"
             say "      prohibit-password"
             FAIL="$FAIL PermitRootLogin" ;;
        *)   say "  PermitRootLogin: $_prl"
             FAIL="$FAIL PermitRootLogin" ;;
    esac
    case "$_pa" in
        no) say "  PasswordAuth: NO"; FAIL="$FAIL PasswordAuth" ;;
        "") say "  PasswordAuth: unset (yes)" ;;
        *)  say "  PasswordAuth: $_pa" ;;
    esac
else
    say "  $CONF MISSING"
    FAIL="$FAIL sshd_config"
fi
say "$RULE"

# ------------------------------------------------------------- 5. password
# The salt is stored in the hash, so the answer here is a fact, not a guess.
say "Root password:"
HASH=$(awk -F: '$1 == "root" { print $2; exit }' /etc/shadow 2>/dev/null)
if [ -z "$HASH" ]; then
    say "  EMPTY - no password set"
    say "  (PermitEmptyPasswords no"
    say "   means logins will fail)"
    FAIL="$FAIL empty-password"
else
    case "$HASH" in
        '!'*|'*'*)
            say "  locked"
            FAIL="$FAIL locked-password" ;;
        '$'*)
            _id=$(printf '%s' "$HASH" | cut -d'$' -f2)
            _salt=$(printf '%s' "$HASH" | cut -d'$' -f3)
            case "$_id" in
                1) _m=md5 ;; 5) _m=sha256 ;; 6) _m=sha512 ;; *) _m="" ;;
            esac
            say "  set (\$$_id\$, ${_m:-unknown})"
            if [ -n "$_m" ] && command -v mkpasswd >/dev/null 2>&1; then
                _try=$(mkpasswd -m "$_m" -S "$_salt" "1" 2>/dev/null)
                if [ -n "$_try" ] && [ "$_try" = "$HASH" ]; then
                    say "  it is \"1\" (MiSTer's)"
                else
                    say "  it is NOT \"1\""
                fi
            fi ;;
        *)  say "  set (not a hash?)" ;;
    esac
fi
say "$RULE"

# ------------------------------------------------------------------ 6. ptys
say "Terminals:"
if awk '$2 == "/dev/pts" { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null; then
    say "  /dev/pts: mounted"
else
    say "  /dev/pts: NOT MOUNTED"
    FAIL="$FAIL devpts"
fi
[ -c /dev/ptmx ] && say "  /dev/ptmx: yes" || { say "  /dev/ptmx: NO"; FAIL="$FAIL ptmx"; }
say "$RULE"

# --------------------------------------------------------------- addresses
say "Connect to:"
NADDR=0
for d in /sys/class/net/*; do
    n=$(basename "$d")
    [ "$n" = lo ] && continue
    _ip=$(ip -4 addr show "$n" 2>/dev/null | awk '/inet /{ sub("/.*", "", $2); print $2; exit }')
    [ -n "$_ip" ] || continue
    NADDR=$((NADDR + 1))
    say "  ssh root@$_ip"
done
if [ "$NADDR" -eq 0 ]; then
    say "  no address on any"
    say "  interface: run network_up"
    FAIL="$FAIL no-address"
fi

logo ""
logo "  --- sshd -T (effective config) ---"
if [ "$WIDE" -eq 1 ] && [ -n "$SSHD" ]; then
    "$SSHD" -T 2>&1 | grep -iE 'permitrootlogin|passwordauth|port |subsystem|usedns|permitempty' \
        | while IFS= read -r l; do logo "  $l"; done
elif [ -n "$SSHD" ]; then
    "$SSHD" -T >> "$LOG" 2>&1
fi

# ----------------------------------------------------------------- verdict
say "$RULE"
if [ -z "$FAIL" ]; then
    say "VERDICT: ready."
    say "user root, password 1"
else
    say "VERDICT: not ready"
    for _f in $FAIL; do say "  $_f"; done
    say ""
    case "$FAIL" in
        *sshd*|*ssh-keygen*)
            say "openssh is not in the build."
            say "On the PC: ./build.sh"
            say "after enabling it in the"
            say "defconfig." ;;
        *devpts*|*ptmx*)
            say "Auth will succeed and the"
            say "session will die with"
            say "'PTY allocation request"
            say "failed'. rcS should mount"
            say "it; try now with:"
            say "  mount -a" ;;
        *empty-password*|*locked-password*)
            say "Set it on the board with"
            say "  passwd"
            say "or set the buildroot"
            say "symbol and rebuild." ;;
        *not-running*|*not-listening*)
            say "Try starting it by hand:"
            say "  /etc/init.d/S50sshd start" ;;
        *)  say "See $LOG" ;;
    esac
fi
exit 0
