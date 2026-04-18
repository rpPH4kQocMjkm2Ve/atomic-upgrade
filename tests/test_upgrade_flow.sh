#!/usr/bin/env bash
# tests/test_upgrade_flow.sh — Integration tests for the main upgrade execution flow
# Covers snapshot creation, home isolation, chroot, UKI build, cleanup, dry-run
# Run: bash tests/test_upgrade_flow.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

SCRIPT="${PROJECT_ROOT}/bin/atomic-upgrade"

# Mock verify-lib
make_mock verify-lib "echo '${PROJECT_ROOT}/lib/atomic/common.sh'; exit 0"

# ── Setup ──────────────────────────────────────────────────────────────

_FAKE_ESP="${TESTDIR}/fake_esp"
_FAKE_BTRFS="${TESTDIR}/fake_btrfs"
_FAKE_NEWROOT="${TESTDIR}/newroot"

mkdir -p "${_FAKE_ESP}/EFI/Linux"
mkdir -p "${_FAKE_BTRFS}/root-current"
mkdir -p "${_FAKE_BTRFS}"
mkdir -p "${_FAKE_NEWROOT}"

# Create boot mock dir — files used for -f checks in the script
mkdir -p /tmp/atomic-test-boot
touch /tmp/atomic-test-boot/vmlinuz-linux
touch /tmp/atomic-test-boot/initramfs-linux.img

# Create fake module directory for snapshot consistency check
_FAKE_MODULES="/tmp/atomic-test-modules"
mkdir -p "${_FAKE_MODULES}/6.14.0-arch1-1"
echo "linux" > "${_FAKE_MODULES}/6.14.0-arch1-1/pkgbase"

# Prepare NEW_ROOT with fake modules, boot, etc for snapshot verification
_FAKE_NEWROOT="${TESTDIR}/newroot"
mkdir -p "${_FAKE_NEWROOT}"
mkdir -p "${_FAKE_NEWROOT}/usr/lib/modules/6.14.0-arch1-1"
echo "linux" > "${_FAKE_NEWROOT}/usr/lib/modules/6.14.0-arch1-1/pkgbase"
mkdir -p "${_FAKE_NEWROOT}/boot"
cp /tmp/atomic-test-boot/* "${_FAKE_NEWROOT}/boot/"
mkdir -p "${_FAKE_NEWROOT}/etc"
mkdir -p "${_FAKE_NEWROOT}/efi"

# Build mocks to inject after common.sh sourcing
cat > "${TESTDIR}/upgrade-flow-mocks.txt" << MOCKS

# === Test mocks ===
ESP="${_FAKE_ESP}"
BTRFS_MOUNT="${_FAKE_BTRFS}"
NEW_ROOT="${_FAKE_NEWROOT}"

date() {
    if [[ "\${1:-}" == "+%Y%m%d-%H%M%S" ]]; then
        echo "20250615-120000"
    else
        command date "\$@"
    fi
}

load_config()         { return 0; }
acquire_lock()        { echo "ACQUIRE_LOCK"; }
validate_config()     { return 0; }
check_dependencies()  { return 0; }
get_current_subvol_raw() { echo "/root-current"; }
get_current_subvol()  { echo "root-current"; }
get_root_device()     { echo "/dev/sda2"; }
ensure_btrfs_mounted(){ return 0; }
validate_subvolume()  { return 0; }
check_btrfs_space()   { return 0; }
check_esp_space()     { return 0; }

btrfs() {
    if [[ "\$1" == "subvolume" && "\$2" == "snapshot" ]]; then
        mkdir -p "\${BTRFS_MOUNT}/root-20250615-120000"
    elif [[ "\$1" == "subvolume" && "\$2" == "create" ]]; then
        mkdir -p "\${3}"
    elif [[ "\$1" == "subvolume" && "\$2" == "delete" ]]; then
        rm -rf "\${3}"
    fi
    return 0
}

mount() { return 0; }
mountpoint() { return 1; }
umount() { return 0; }

chroot_snapshot() {
    return "\${CHROOT_RC:-0}"
}

update_fstab() {
    local fstab_file="\$1" old_subvol="\$2" new_subvol="\$3"
    mkdir -p "\$(dirname "\$fstab_file")"
    echo "UUID=xxx  /  btrfs  subvol=/\${new_subvol}  0 1" > "\$fstab_file"
    return 0
}
update_fstab_home() { return 0; }

build_uki() {
    local gen_id="\$1"
    touch "\${ESP}/EFI/Linux/arch-\${gen_id}.efi"
    echo "\${ESP}/EFI/Linux/arch-\${gen_id}.efi"
    return 0
}

sign_uki() { return 0; }
verify_uki() { return 0; }
populate_home_skeleton() { return 0; }
garbage_collect() { return 0; }

/usr/bin/pacman() {
    if [[ "\$*" == "-Qu" ]]; then
        echo "   vim 9.0-1 -> 9.1-1"
    fi
    return 0
}
MOCKS

# Create the patched test script
_TEST_SCRIPT="${TESTDIR}/atomic-upgrade-flow-test"

# Create real-looking boot files so the script's -f checks pass
mkdir -p /tmp/atomic-test-boot
touch /tmp/atomic-test-boot/vmlinuz-linux
touch /tmp/atomic-test-boot/initramfs-linux.img

# Patch: skip EUID, inject mocks, override /boot to test dir
sed \
    -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e 's|"/boot/|"/tmp/atomic-test-boot/|g' \
    -e '/^_src "\${LIBDIR}\/common.sh"$/r '"${TESTDIR}/upgrade-flow-mocks.txt"'' \
    "$SCRIPT" > "$_TEST_SCRIPT"

chmod +x "$_TEST_SCRIPT"

_run_upgrade() {
    # Clean previous UKI files
    rm -f "${_FAKE_ESP}/EFI/Linux/arch-"*.efi 2>/dev/null || true
    
    run_cmd env \
        _TEST_ESP="$_FAKE_ESP" \
        _TEST_BTRFS="$_FAKE_BTRFS" \
        _TEST_NEWROOT="$_FAKE_NEWROOT" \
        CHROOT_RC=0 \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "$_TEST_SCRIPT" "$@"
}

# ── Successful basic upgrade ─────────────────────────────────────────

section "Successful basic upgrade flow"

_run_upgrade
assert_eq "upgrade succeeds" "0" "$_rc"
assert_contains "lock acquired" "ACQUIRE_LOCK" "$_out"
assert_contains "shows current and new" "Current:" "$_out"
assert_contains "shows command" "Command:" "$_out"
assert_contains "snapshot created" "Creating snapshot" "$_out"
assert_contains "mounting new root" "Mounting new root" "$_out"
assert_contains "running chroot" "Running:" "$_out"
assert_contains "verifying snapshot" "Verifying snapshot" "$_out"
assert_contains "updating fstab" "Updating fstab" "$_out"
assert_contains "building UKI" "Building UKI" "$_out"
assert_contains "unmounting" "Unmounting new root" "$_out"
assert_contains "garbage collection" "Running garbage collection" "$_out"
assert_contains "ready message" "ready" "$_out"

# ── Upgrade with --dry-run ───────────────────────────────────────────

section "Upgrade with --dry-run"

_run_upgrade --dry-run
assert_eq "dry-run → exit 0" "0" "$_rc"
assert_contains "DRY RUN header" "DRY RUN" "$_out"
assert_contains "would create snapshot" "would create snapshot" "$_out"
assert_contains "chroot command shown" "DRY RUN - chroot command" "$_out"
assert_contains "would create UKI" "would create UKI" "$_out"
assert_contains "signing disabled" "sbctl signing: disabled" "$_out"
assert_contains "would run GC" "would run garbage collection" "$_out"
assert_contains "DRY RUN complete" "DRY RUN complete" "$_out"
assert_not_contains "no actual snapshot" "Creating snapshot" "$_out"

# ── Upgrade with --no-gc ────────────────────────────────────────────

section "Upgrade with --no-gc"

_run_upgrade --no-gc
assert_eq "no-gc → exit 0" "0" "$_rc"
assert_contains "GC skipped" "Garbage collection skipped" "$_out"

# ── Upgrade with custom tag ──────────────────────────────────────────

section "Upgrade with --tag"

_run_upgrade --tag pre-nvidia
assert_eq "tagged upgrade → exit 0" "0" "$_rc"
assert_contains "tagged snapshot name" "root-20250615-120000-pre-nvidia" "$_out"

# ── Upgrade with --separate-home (new home) ──────────────────────────

section "Upgrade with --separate-home"

rm -rf "${_FAKE_BTRFS}/home-myhome" 2>/dev/null || true

_run_upgrade --separate-home -t myhome
assert_eq "separate-home → exit 0" "0" "$_rc"
assert_contains "home isolated" "Home: isolated" "$_out"
assert_contains "creating home" "Creating home subvolume" "$_out"
assert_contains "ready with home" "home: home-myhome" "$_out"

# ── Upgrade with --separate-home (existing home) ─────────────────────

section "Upgrade with existing home"

mkdir -p "${_FAKE_BTRFS}/home-existing"

_run_upgrade --separate-home -t existing
assert_eq "existing home → exit 0" "0" "$_rc"
assert_contains "using existing" "Using existing home" "$_out"

# ── Upgrade with custom command ──────────────────────────────────────

section "Upgrade with custom command"

_run_upgrade -- pacman -S vim
assert_eq "custom command → exit 0" "0" "$_rc"
assert_contains "custom command shown" "pacman -S vim" "$_out"

# ── Error: chroot command fails → cleanup triggered ──────────────────

section "Error: chroot command failure"

run_cmd env \
    _TEST_ESP="$_FAKE_ESP" \
    _TEST_BTRFS="$_FAKE_BTRFS" \
    _TEST_NEWROOT="$_FAKE_NEWROOT" \
    CHROOT_RC=1 \
    PATH="${MOCK_BIN}:${PATH}" \
    bash "$_TEST_SCRIPT"

assert_eq "chroot fail → exit 1" "1" "$_rc"
assert_contains "error message" "Command failed" "$_out"
assert_contains "cleaning up" "Cleaning up" "$_out"
assert_contains "removing snapshot" "Removing failed snapshot" "$_out"

# ── Error: kernel not found in current system ────────────────────────

section "Error: kernel not found"

# Temporarily remove boot mock
rm -f /tmp/atomic-test-boot/vmlinuz-linux

_run_upgrade
assert_eq "missing kernel → exit 1" "1" "$_rc"
assert_contains "kernel error" "No kernel" "$_out"

# Restore
touch /tmp/atomic-test-boot/vmlinuz-linux

# ── Error: initramfs not found ───────────────────────────────────────

section "Error: initramfs not found"

rm -f /tmp/atomic-test-boot/initramfs-linux.img

_run_upgrade
assert_eq "missing initramfs → exit 1" "1" "$_rc"
assert_contains "initramfs error" "No initramfs" "$_out"

# Restore
touch /tmp/atomic-test-boot/initramfs-linux.img

# ── Cleanup trap structure verification ─────────────────────────────

section "Cleanup trap: structure verification"

_script_content=$(cat "$SCRIPT")

assert_contains "cleanup function defined" "cleanup()" "$_script_content"
assert_contains "EXIT trap set" "trap cleanup EXIT" "$_script_content"
assert_contains "removes snapshot" "btrfs subvolume delete" "$_script_content"
assert_contains "removes UKI file" ".efi" "$_script_content"
assert_contains "unmounts NEW_ROOT" "NEW_ROOT" "$_script_content"
assert_contains "closes lock FD" "LOCK_FD" "$_script_content"
assert_contains "lazy unmount fallback" "umount -Rl" "$_script_content"

# Verify rollback logic: only on failure + snapshot created
assert_contains "rollback condition: exit_code" 'exit_code -ne 0' "$_script_content"
assert_contains "rollback condition: SNAPSHOT_CREATED" 'SNAPSHOT_CREATED' "$_script_content"

# ── fstab home update warning ───────────────────────────────────────

section "fstab home update warning"

# Patch update_fstab_home to fail
cat > "${TESTDIR}/upgrade-flow-mocks-fstab-fail.txt" << MOCKS

ESP="${_FAKE_ESP}"
BTRFS_MOUNT="${_FAKE_BTRFS}"
NEW_ROOT="${_FAKE_NEWROOT}"

date() {
    if [[ "\${1:-}" == "+%Y%m%d-%H%M%S" ]]; then
        echo "20250615-120000"
    else
        command date "\$@"
    fi
}

load_config()         { return 0; }
acquire_lock()        { :; }
validate_config()     { return 0; }
check_dependencies()  { return 0; }
get_current_subvol_raw() { echo "/root-current"; }
get_current_subvol()  { echo "root-current"; }
get_root_device()     { echo "/dev/sda2"; }
ensure_btrfs_mounted(){ return 0; }
validate_subvolume()  { return 0; }
check_btrfs_space()   { return 0; }
check_esp_space()     { return 0; }

btrfs() { mkdir -p "\${BTRFS_MOUNT}/root-20250615-120000-fstab"; return 0; }
mount() { return 0; }
mountpoint() { return 1; }
umount() { return 0; }
chroot_snapshot() { return 0; }
update_fstab() {
    local fstab_file="\$1" new_subvol="\$3"
    mkdir -p "\$(dirname "\$fstab_file")"
    echo "UUID=xxx  /  btrfs  subvol=/\${new_subvol}  0 1" > "\$fstab_file"
    return 0
}
update_fstab_home() { return 1; }

build_uki() {
    touch "\${ESP}/EFI/Linux/arch-\${1}.efi"
    echo "\${ESP}/EFI/Linux/arch-\${1}.efi"
    return 0
}

sign_uki() { return 0; }
verify_uki() { return 0; }
populate_home_skeleton() { return 0; }
garbage_collect() { return 0; }

/usr/bin/pacman() { return 0; }
MOCKS

rm -rf "${_FAKE_BTRFS}/home-fstab" 2>/dev/null || true

# Prepare NEW_ROOT for fstab test too
mkdir -p "${_FAKE_NEWROOT}/usr/lib/modules/6.14.0-arch1-1"
echo "linux" > "${_FAKE_NEWROOT}/usr/lib/modules/6.14.0-arch1-1/pkgbase"

_TEST_SCRIPT_FSTAB="${TESTDIR}/atomic-upgrade-fstab-test"
sed \
    -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e 's|"/boot/|"/tmp/atomic-test-boot/|g' \
    -e '/^_src "\${LIBDIR}\/common.sh"$/r '"${TESTDIR}/upgrade-flow-mocks-fstab-fail.txt"'' \
    "$SCRIPT" > "$_TEST_SCRIPT_FSTAB"

chmod +x "$_TEST_SCRIPT_FSTAB"

run_cmd env \
    _TEST_ESP="$_FAKE_ESP" \
    _TEST_BTRFS="$_FAKE_BTRFS" \
    _TEST_NEWROOT="$_FAKE_NEWROOT" \
    PATH="${MOCK_BIN}:${PATH}" \
    bash "$_TEST_SCRIPT_FSTAB" --separate-home -t fstab

assert_eq "fstab home fail → exit 0" "0" "$_rc"
assert_contains "fstab warning" "Could not update /home in fstab" "$_out"

summary
