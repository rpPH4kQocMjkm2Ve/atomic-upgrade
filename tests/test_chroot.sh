#!/usr/bin/env bash
# tests/test_chroot.sh — chroot_snapshot isolation, mounts, resolv.conf
# Run: bash tests/test_chroot.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── chroot_snapshot ───────────────────────────────────────────

section "chroot_snapshot"

_CS_ROOT="${TESTDIR}/cs_root"
_CS_LOG="${TESTDIR}/cs_unshare_log"

_cs_setup() {
    rm -rf "$_CS_ROOT" "$_CS_LOG"
    mkdir -p "${_CS_ROOT}/proc" "${_CS_ROOT}/sys/firmware/efi/efivars"
    mkdir -p "${_CS_ROOT}/dev/pts" "${_CS_ROOT}/dev/shm"
    mkdir -p "${_CS_ROOT}/run" "${_CS_ROOT}/tmp" "${_CS_ROOT}/etc"
}

make_mock umount 'exit 0'

# ── Happy path: rc 0 + correct unshare flags ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
mkdir -p "$LOCK_DIR"
make_mock mount   'exit 0'
make_mock unshare 'echo "$*" > "'"${_CS_LOG}"'"; exit 0'

run_cmd chroot_snapshot "$_CS_ROOT" /usr/bin/pacman -Syu
assert_eq "happy path → rc 0" "0" "$_rc"

_cs_args=$(cat "$_CS_LOG" 2>/dev/null || echo "")
assert_contains "uses --fork"          "--fork"        "$_cs_args"
assert_contains "uses --pid"           "--pid"         "$_cs_args"
assert_contains "uses --kill-child"    "--kill-child"  "$_cs_args"
assert_contains "uses --mount"         "--mount "      "$_cs_args"
assert_contains "uses --mount-proc"    "--mount-proc=${_CS_ROOT}/proc" "$_cs_args"
assert_contains "chroots into root"    "chroot ${_CS_ROOT}" "$_cs_args"
assert_contains "passes ATOMIC_UPGRADE"    "ATOMIC_UPGRADE=1"    "$_cs_args"
assert_contains "passes SYSTEMD_IN_CHROOT" "SYSTEMD_IN_CHROOT=1" "$_cs_args"
assert_contains "passes SHELL"             "SHELL=/bin/bash"      "$_cs_args"
assert_contains "forwards command"     "/usr/bin/pacman" "$_cs_args"
assert_contains "forwards args"        "-Syu"           "$_cs_args"

# ── Command failure → rc propagated ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'exit 42'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/false
assert_eq "command failure → rc propagated" "42" "$_rc"

# ── Multiple arguments forwarded ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'echo "$*" > "'"${_CS_LOG}"'"; exit 0'

run_cmd chroot_snapshot "$_CS_ROOT" /usr/bin/pacman -S --needed base-devel git
_cs_args=$(cat "$_CS_LOG" 2>/dev/null || echo "")
assert_contains "multi-arg: -S"         "-S"         "$_cs_args"
assert_contains "multi-arg: --needed"   "--needed"   "$_cs_args"
assert_contains "multi-arg: base-devel" "base-devel" "$_cs_args"
assert_contains "multi-arg: git"        "git"        "$_cs_args"

# ── LOCK_DIR exposed inside root ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock_expose"
mkdir -p "$LOCK_DIR"
make_mock mount   'exit 0'
make_mock unshare 'exit 0'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
[[ -d "${_CS_ROOT}${LOCK_DIR}" ]] \
    && ok "LOCK_DIR created inside root" \
    || fail "LOCK_DIR not created inside root"

# ── LOCK_DIR missing on host → no crash ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock_nonexistent_$$"
make_mock mount   'exit 0'
make_mock unshare 'exit 0'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "missing LOCK_DIR → no crash" "0" "$_rc"

# ── resolv.conf symlink: saved and restored ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'exit 0'

ln -sf "../run/systemd/resolve/stub-resolv.conf" "${_CS_ROOT}/etc/resolv.conf"
_orig_target=$(readlink "${_CS_ROOT}/etc/resolv.conf")

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
[[ -L "${_CS_ROOT}/etc/resolv.conf" ]] \
    && ok "resolv.conf symlink restored" \
    || fail "resolv.conf not a symlink after teardown"
_restored=$(readlink "${_CS_ROOT}/etc/resolv.conf" 2>/dev/null || echo "")
assert_eq "resolv.conf link target matches" "$_orig_target" "$_restored"

# ── resolv.conf regular file: not mangled ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'exit 0'

echo "nameserver 1.1.1.1" > "${_CS_ROOT}/etc/resolv.conf"

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
[[ -f "${_CS_ROOT}/etc/resolv.conf" && ! -L "${_CS_ROOT}/etc/resolv.conf" ]] \
    && ok "resolv.conf regular file preserved" \
    || fail "resolv.conf regular file lost or became symlink"

# ── No resolv.conf in root: no crash ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'exit 0'
rm -f "${_CS_ROOT}/etc/resolv.conf"

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "no resolv.conf → no crash" "0" "$_rc"

# ── resolv.conf symlink still restored after command failure ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 0'
make_mock unshare 'exit 1'

ln -sf "../run/systemd/resolve/stub-resolv.conf" "${_CS_ROOT}/etc/resolv.conf"

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
[[ -L "${_CS_ROOT}/etc/resolv.conf" ]] \
    && ok "symlink restored even after failure" \
    || fail "symlink not restored after failure"

# ── Mount failure → early return, unshare not called ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock mount   'exit 1'
make_mock unshare 'echo "SHOULD_NOT_RUN" > "'"${_CS_LOG}"'"; exit 0'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "mount failure → rc 1" "1" "$_rc"
_cs_ran=$(cat "$_CS_LOG" 2>/dev/null || echo "")
assert_not_contains "unshare not called on mount failure" "SHOULD_NOT_RUN" "$_cs_ran"

# ── efivarfs failure does not abort (|| true) ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
make_mock unshare 'exit 0'
make_mock mount '
if echo "$*" | grep -q "efivarfs"; then
    exit 1
fi
exit 0
'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "efivarfs failure ignored → rc 0" "0" "$_rc"

# ── Mount failure mid-chain → earlier mounts cleaned up ──
_cs_setup
LOCK_DIR="${TESTDIR}/cs_lock"
mkdir -p "$LOCK_DIR"

_CS_UMOUNT_LOG="${TESTDIR}/cs_umount_cleanup.log"
: > "$_CS_UMOUNT_LOG"

make_mock umount 'echo "$*" >> "'"${_CS_UMOUNT_LOG}"'"; exit 0'
make_mock unshare 'echo "SHOULD_NOT_RUN" > "'"${_CS_LOG}"'"; exit 0'

# devtmpfs fails → sysfs already mounted, must be cleaned up
make_mock mount '
if echo "$*" | grep -q "devtmpfs"; then exit 1; fi
exit 0
'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "devtmpfs failure → rc 1" "1" "$_rc"
_cs_ran=$(cat "$_CS_LOG" 2>/dev/null || echo "")
assert_not_contains "unshare not called on devtmpfs failure" "SHOULD_NOT_RUN" "$_cs_ran"

_cs_umount_out=$(cat "$_CS_UMOUNT_LOG")
assert_contains "sysfs cleaned up after devtmpfs failure" "/sys" "$_cs_umount_out"

# run tmpfs fails → dev, devpts, sysfs must be cleaned up
: > "$_CS_UMOUNT_LOG"
: > "$_CS_LOG"

make_mock mount '
if echo "$*" | grep -q "nosuid,nodev,mode=0755" && echo "$*" | grep -q "/run"; then exit 1; fi
exit 0
'

run_cmd chroot_snapshot "$_CS_ROOT" /bin/true
assert_eq "run tmpfs failure → rc 1" "1" "$_rc"
_cs_ran=$(cat "$_CS_LOG" 2>/dev/null || echo "")
assert_not_contains "unshare not called on run failure" "SHOULD_NOT_RUN" "$_cs_ran"

_cs_umount_out=$(cat "$_CS_UMOUNT_LOG")
assert_contains "dev cleaned up after run failure" "/dev" "$_cs_umount_out"
assert_contains "sys cleaned up after run failure" "/sys" "$_cs_umount_out"

# Restore mocks
make_mock mount      'exit 0'
make_mock umount     'exit 0'
make_mock mountpoint 'exit 0'
LOCK_DIR="/run/atomic"


summary
