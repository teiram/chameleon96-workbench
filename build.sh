#!/bin/sh
# Build all Chameleon96/MiSTer artifacts with buildroot:
#   - SPL + U-Boot:   build/images/u-boot-with-spl.sfp  (A2 partition)
#   - kernel:         build/images/zImage + socfpga_cyclone5_chameleon96.dtb
#   - boot set (FAT): build/images/{u-boot.scr,Menu_MiSTer.rbf,extlinux/...}
#   - rootfs:         build/images/rootfs.tar (with Main_MiSTer + minimal RBFs)
#
# The kernel/u-boot sources are cloned from GitHub by buildroot.
# The Main_MiSTer binary is built by the buildroot host toolchain
# (or a user-supplied CROSS_COMPILE toolchain).
#
# ---------------------------------------------------------------------------
# WHY THIS IS MORE THAN "defconfig && make"
#
# Loading a new defconfig does NOT make buildroot rebuild the packages whose
# options changed. Each package records that it is configured with a stamp
# file, and buildroot never compares that stamp against the .config. So
# enabling, say, BR2_PACKAGE_UTIL_LINUX_AGETTY on a tree where util-linux is
# already built produces a clean, successful, twenty-minute build with no
# agetty in it -- and nothing anywhere says so.
#
# The kernel has the same problem with an extra twist: its .config is merged
# from the defconfig plus BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES, guarded by
# .stamp_dotconfig, and running "linux-reconfigure" BEFORE this script has
# loaded the defconfig regenerates it from a build/.config that does not
# mention the fragment yet -- then leaves a stamp newer than the fragment, so
# the merge never happens at all.
#
# So this script:
#   1. loads the defconfig FIRST (that is what puts the fragment list in place)
#   2. checks that every symbol the defconfig asks for actually survived
#      kconfig's dependency resolution
#   3. compares the resulting .config with the one the last build used and runs
#      <package>-reconfigure for each package whose options moved
#   4. drops stale files from the target's Scripts directory, which buildroot
#      never prunes
#   5. builds
#
# Step 3 costs nothing when nothing changed, which is the common case.
# ---------------------------------------------------------------------------
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
BR="$ROOT/buildroot"
OUT="$ROOT/build"
DEFCONFIG="$ROOT/config/chameleon96_config"

[ -d "$BR" ] || {
    echo "ERROR: no buildroot clone at $BR" >&2
    echo "       git clone https://gitlab.com/buildroot.org/buildroot.git" >&2
    exit 1
}

# Download cache. Override with BR2_DL_DIR=/some/path to reuse a cache.
DL_DIR="${BR2_DL_DIR:-$BR/dl}"

# What the previous run of this script ended up with, so we can tell what moved.
SNAP="$OUT/.ch96-last-config"

TMP=$(mktemp -d 2>/dev/null || echo /tmp/.ch96build.$$)
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --------------------------------------------------------------------------
echo "== Buildroot config (O=$OUT, dl=$DL_DIR)"
make -C "$BR" O="$OUT" defconfig \
    BR2_DEFCONFIG="$DEFCONFIG" \
    BR2_DL_DIR="$DL_DIR"

# ------------------------------------------------- 2. did every symbol survive?
# A symbol whose dependencies are not met is dropped in silence. Listing the
# casualties here turns "the feature is missing from the image" into "these two
# symbols never made it into the config".
awk -F= '/^BR2_[A-Z0-9_]+=y$/ { print $1 }' "$DEFCONFIG"  | sort -u > "$TMP/want"
awk -F= '/^BR2_[A-Z0-9_]+=y$/ { print $1 }' "$OUT/.config" | sort -u > "$TMP/got"
if [ -s "$TMP/want" ]; then
    comm -23 "$TMP/want" "$TMP/got" > "$TMP/dropped" || true
    if [ -s "$TMP/dropped" ]; then
        echo
        echo "WARNING: kconfig dropped these symbols (unmet dependencies):"
        sed 's/^/    /' "$TMP/dropped"
        echo "         The build will continue without them."
        echo
    fi
fi

# ----------------------------------- 3. reconfigure the packages that changed
# Normalise both configs so that turning an option off is a change too, not
# just a disappearing line.
norm() {
    sed -n \
        -e 's/^# \(BR2_[A-Za-z0-9_]*\) is not set$/\1=n/p' \
        -e 's/^\(BR2_[A-Za-z0-9_]*\)=\(.*\)$/\1=\2/p' \
        "$1" | sort
}

# BR2_PACKAGE_UTIL_LINUX_AGETTY -> util-linux, by trying the longest name that
# is an actual package directory and shortening at each dash. That gets
# sub-options right (e2fsprogs-resize2fs -> e2fsprogs) without a lookup table.
pkg_of_symbol() {
    _s=${1#BR2_PACKAGE_}
    [ "$_s" != "$1" ] || return 1
    _n=$(printf '%s' "$_s" | tr 'A-Z_' 'a-z-')
    while [ -n "$_n" ]; do
        [ -d "$BR/package/$_n" ] && { printf '%s\n' "$_n"; return 0; }
        case "$_n" in
            *-*) _n=${_n%-*} ;;
            *)   return 1 ;;
        esac
    done
    return 1
}

RECONF=""
if [ -f "$SNAP" ]; then
    norm "$SNAP"        > "$TMP/old"
    norm "$OUT/.config" > "$TMP/new"
    comm -3 "$TMP/old" "$TMP/new" | sed 's/^[[:space:]]*//; s/=.*//' | sort -u > "$TMP/changed"

    if [ -s "$TMP/changed" ]; then
        echo "== Config changed since the last build:"
        sed 's/^/    /' "$TMP/changed"

        while IFS= read -r sym; do
            case "$sym" in
                # The kernel and u-boot are not "packages" under package/, and
                # both are built from a custom source here, so they are named
                # explicitly.
                BR2_LINUX_KERNEL*)  p=linux ;;
                BR2_TARGET_UBOOT*)  p=uboot ;;
                *)                  p=$(pkg_of_symbol "$sym") || continue ;;
            esac
            # Only bother with something that is already built: anything else
            # gets configured from scratch on this run anyway.
            ls -d "$OUT/build/$p-"* >/dev/null 2>&1 || continue
            case " $RECONF " in *" $p "*) ;; *) RECONF="$RECONF $p" ;; esac
        done < "$TMP/changed"
    fi
fi

if [ -n "$RECONF" ]; then
    echo
    echo "== Reconfiguring the packages those symbols belong to:$RECONF"
    echo "   (buildroot would otherwise keep the previously configured build)"
    for p in $RECONF; do
        echo "-- $p-reconfigure"
        make -C "$BR" O="$OUT" BR2_DL_DIR="$DL_DIR" "$p-reconfigure"
    done
    echo
fi

# ------------------------------------------------ 4. drop stale target files
# buildroot copies the rootfs overlay over build/target/ and never removes
# anything, so a script deleted or renamed in config/rootfs-overlay stays in
# the image -- and keeps showing up in MiSTer's Scripts menu -- until the tree
# is cleaned. Prune just that one directory, which is entirely ours.
OVL_SCRIPTS="$ROOT/config/rootfs-overlay/media/fat/Scripts"
TGT_SCRIPTS="$OUT/target/media/fat/Scripts"
if [ -d "$OVL_SCRIPTS" ] && [ -d "$TGT_SCRIPTS" ]; then
    for f in "$TGT_SCRIPTS"/*; do
        # Regular files only. "rm -f" on a directory fails, and with set -e
        # that would abort the whole build over a stray subdirectory.
        [ -f "$f" ] || continue
        b=$(basename "$f")
        case "$b" in *.log) continue ;; esac
        [ -e "$OVL_SCRIPTS/$b" ] && continue
        echo "== Removing stale target file: media/fat/Scripts/$b"
        rm -f "$f"
    done
fi

# --------------------------------------------------------------------------
echo "== Buildroot build"
make -C "$BR" O="$OUT" BR2_DL_DIR="$DL_DIR"

# Remember what this build used, so the next run can tell what moved.
cp "$OUT/.config" "$SNAP"

# ---------------------------------------------- 6. did the kernel fragment take?
# The fragment is merged into the kernel .config exactly once, guarded by
# .stamp_dotconfig. When that guard wins, the build still succeeds -- it just
# produces a kernel without the options, and the only symptom is a driver that
# is missing from the image. Check rather than assume, and say which lines are
# missing rather than "something is wrong".
FRAG=$(sed -n 's/^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="\(.*\)"$/\1/p' "$OUT/.config" | head -1)
if [ -n "$FRAG" ]; then
    FRAG=$(printf '%s' "$FRAG" | sed "s|\$(TOPDIR)|$BR|g")
    KDIR=""
    for d in "$OUT"/build/linux-*; do
        [ -f "$d/.config" ] && KDIR=$d
    done
    if [ -n "$KDIR" ]; then
        MISSING=""
        for f in $FRAG; do
            [ -f "$f" ] || { echo "WARNING: fragment $f does not exist"; continue; }
            while IFS= read -r line; do
                case "$line" in ''|\#*) continue ;; esac
                case "$line" in *=*) ;; *) continue ;; esac
                grep -qxF "$line" "$KDIR/.config" || MISSING="$MISSING $line"
            done < "$f"
        done
        if [ -n "$MISSING" ]; then
            echo
            echo "WARNING: the kernel config fragment did not fully take."
            echo "         Missing from $KDIR/.config:"
            for m in $MISSING; do echo "             $m"; done
            echo "         The zImage in images/ does NOT have those options."
            echo "         Force the merge and rebuild the kernel with:"
            echo "             make -C buildroot O=\"$OUT\" linux-reconfigure && $0"
            echo
        else
            echo "== Kernel config fragment: all options present"
        fi
    fi
fi

# --------------------------------------------- 7. did the rootfs get the parts?
# The mirror image of the check above, for packages instead of the kernel. A
# symbol can be set, the package can build, and the binary can still be absent
# -- most often because buildroot did not reconfigure an already-built package
# after a sub-option changed. Every one of these failures is silent at build
# time and only shows up on the board, usually as something unrelated:
# a blinking cursor instead of script output, or an sshd that never starts.
#
# One line per symbol: SYMBOL followed by the paths that would satisfy it, any
# one of which is enough (buildroot puts things under /sbin or /usr/sbin
# depending on merged-usr).
ROOTFS_TAR="$OUT/images/rootfs.tar"
if [ -f "$ROOTFS_TAR" ]; then
    TARLIST="$TMP/tarlist"
    if tar tf "$ROOTFS_TAR" > "$TARLIST" 2>/dev/null; then
        ABSENT=""
        # shellcheck disable=SC2162
        while read sym paths; do
            case "$sym" in ''|\#*) continue ;; esac
            grep -qx "$sym=y" "$OUT/.config" || continue
            found=0
            for p in $paths; do
                grep -qx "./$p" "$TARLIST" && { found=1; break; }
            done
            [ "$found" -eq 1 ] || ABSENT="$ABSENT
    $sym -> none of: $paths"
        done <<'CHECKS'
BR2_PACKAGE_BASH                bin/bash usr/bin/bash
BR2_PACKAGE_UTIL_LINUX_AGETTY   sbin/agetty usr/sbin/agetty
BR2_PACKAGE_UTIL_LINUX_PARTX    sbin/partx usr/sbin/partx usr/bin/partx
BR2_PACKAGE_E2FSPROGS_RESIZE2FS sbin/resize2fs usr/sbin/resize2fs
BR2_PACKAGE_OPENSSH_SERVER      usr/sbin/sshd sbin/sshd
BR2_PACKAGE_OPENSSH_KEY_UTILS   usr/bin/ssh-keygen usr/sbin/ssh-keygen
CHECKS
        if [ -n "$ABSENT" ]; then
            echo
            echo "WARNING: these symbols are set but produced nothing in the rootfs:$ABSENT"
            echo "         Buildroot does not reconfigure an already-built package when"
            echo "         one of its sub-options changes. Force the ones you need:"
            echo "             make -C buildroot O=\"$OUT\" <package>-reconfigure && $0"
            echo
        fi

        # sshd is the one daemon here that can fail to start with nothing in
        # any log: S50sshd opens with "[ -f /usr/bin/ssh-keygen ] || exit 0",
        # and sshd_config says PermitEmptyPasswords no, so an empty root
        # password refuses every login instead of accepting anything.
        if grep -qx 'BR2_PACKAGE_OPENSSH=y' "$OUT/.config"; then
            SH="$TMP/shadow"
            if tar xf "$ROOTFS_TAR" -O ./etc/shadow > "$SH" 2>/dev/null; then
                if awk -F: '$1 == "root" && $2 != "" && $2 !~ /^[!*]/ { ok = 1 } END { exit !ok }' "$SH"; then
                    echo "== SSH: root has a password set"
                else
                    echo
                    echo "WARNING: openssh is enabled but root has no usable password in"
                    echo "         /etc/shadow, and sshd_config sets PermitEmptyPasswords no,"
                    echo "         so every SSH login would be refused. Check"
                    echo "         BR2_TARGET_GENERIC_ROOT_PASSWD in the defconfig."
                    echo
                fi
            fi
        fi
    fi
fi

echo
echo "== Artifacts in $OUT/images"
ls -la "$OUT/images"
