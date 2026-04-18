#!/usr/bin/env bash
# tests/test_rebuild_uki_flow.sh — Integration tests for bin/atomic-rebuild-uki
# Covers --list, overwrite prompt, mount/build/sign/unmount flow, cleanup
# Run: bash tests/test_rebuild_uki_flow.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

SCRIPT="${PROJECT_ROOT}/bin/atomic-rebuild-uki"

# Mock verify-lib
make_mock verify-lib "echo '${PROJECT_ROOT}/lib/atomic/common.sh'; exit 0"

# ── Setup ──────────────────────────────────────────────────────────────

_FAKE_ESP="${TESTDIR}/fake_esp"
_FAKE_BTRFS="${TESTDIR}/fake_btrfs"
_FAKE_LOCK="${TESTDIR}/lock"

mkdir -p "${_FAKE_ESP}/EFI/Linux"
mkdir -p "${_FAKE_BTRFS}"
mkdir -p "${_FAKE_LOCK}"

# Create a test generation
GEN_ID="20250615-120000"
mkdir -p "${_FAKE_BTRFS}/root-${GEN_ID}"
mkdir -p "${_FAKE_BTRFS}/root-${GEN_ID}/boot"
mkdir -p "${_FAKE_BTRFS}/root-${GEN_ID}/usr/lib/modules/6.14.0-arch1-1"
echo "linux" > "${_FAKE_BTRFS}/root-${GEN_ID}/usr/lib/modules/6.14.0-arch1-1/pkgbase"
touch "${_FAKE_BTRFS}/root-${GEN_ID}/boot/vmlinuz-linux"
touch "${_FAKE_BTRFS}/root-${GEN_ID}/boot/initramfs-linux.img"
mkdir -p "${_FAKE_BTRFS}/root-${GEN_ID}/etc"
echo "PRETTY_NAME=\"Arch Linux\"" > "${_FAKE_BTRFS}/root-${GEN_ID}/etc/os-release"
mkdir -p "${_FAKE_BTRFS}/root-${GEN_ID}/efi"

# Build mocks
cat > "${TESTDIR}/rebuild-mocks.txt" << MOCKS

ESP="${_FAKE_ESP}"
BTRFS_MOUNT="${_FAKE_BTRFS}"
LOCK_DIR="${_FAKE_LOCK}"

acquire_lock()        { echo "ACQUIRE_LOCK"; }
validate_config()     { return 0; }
ensure_btrfs_mounted(){ echo "ENSURE_BTRFS"; return 0; }
validate_subvolume() {
    local subvol="\$1"
    if [[ -d "\${BTRFS_MOUNT}/\${subvol}" ]]; then
        return 0
    else
        echo "ERROR: Subvolume not found" >&2
        return 1
    fi
}

get_root_device()     { echo "/dev/sda2"; }

build_uki() {
    local gen_id="\$1"
    echo "BUILD_UKI gen=\$gen_id"
    touch "\${ESP}/EFI/Linux/arch-\${gen_id}.efi"
    echo "\${ESP}/EFI/Linux/arch-\${gen_id}.efi"
    return 0
}

sign_uki() { echo "SIGN_UKI"; return 0; }

mount() { echo "MOUNT: \$*"; return 0; }
mountpoint() { return 1; }
umount() { echo "UMOUNT: \$*"; return 0; }
rmdir() { echo "RMDIR: \$*"; return 0; }
mktemp() { echo "${_FAKE_LOCK}/rebuild-XXXXXX"; }

MOCKS

# Create patched test script
_TEST_SCRIPT="${TESTDIR}/rebuild-uki-flow-test"

sed \
    -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e '/^validate_config || exit 1$/s/^/# /' \
    -e '/^_src "\${LIBDIR}\/common.sh"$/r '"${TESTDIR}/rebuild-mocks.txt"'' \
    "$SCRIPT" > "$_TEST_SCRIPT"

chmod +x "$_TEST_SCRIPT"

_run_rebuild() {
    run_cmd bash "$_TEST_SCRIPT" "$@"
}

# ── Successful rebuild ───────────────────────────────────────────────

section "Successful rebuild flow"

# Remove UKI so no overwrite prompt
rm -f "${_FAKE_ESP}/EFI/Linux/arch-${GEN_ID}.efi"

_run_rebuild "$GEN_ID"
assert_eq "rebuild → exit 0" "0" "$_rc"
assert_contains "lock acquired" "ACQUIRE_LOCK" "$_out"
assert_contains "btrfs mounted" "ENSURE_BTRFS" "$_out"
assert_contains "subvolume checked" "Checking subvolume" "$_out"
assert_contains "mounting" "Mounting" "$_out"
assert_contains "UKI built" "Building UKI" "$_out"
assert_contains "BUILD_UKI called" "BUILD_UKI" "$_out"
assert_contains "UKI signed" "SIGN_UKI" "$_out"
assert_contains "unmounting" "Unmounting" "$_out"
assert_contains "done message" "Done:" "$_out"

# ── Rebuild with existing UKI (overwrite) ────────────────────────────

section "Rebuild with existing UKI"

# Create UKI file so the prompt triggers
touch "${_FAKE_ESP}/EFI/Linux/arch-${GEN_ID}.efi"

# The script asks for confirmation; we simulate "y" response
run_cmd bash -c "echo 'y' | bash '${_TEST_SCRIPT}' '${GEN_ID}'"
assert_eq "rebuild with overwrite → exit 0" "0" "$_rc"
assert_contains "already exists" "already exists" "$_out"

# ── Rebuild with existing UKI (abort) ────────────────────────────────

section "Rebuild: user aborts overwrite"

touch "${_FAKE_ESP}/EFI/Linux/arch-${GEN_ID}.efi"

run_cmd bash -c "echo 'n' | bash '${_TEST_SCRIPT}' '${GEN_ID}'" || true
assert_contains "aborted message" "Aborted" "$_out"

# ── --list: shows subvolumes ────────────────────────────────────────

section "List orphans"

# Create multiple subvolumes
mkdir -p "${_FAKE_BTRFS}/root-20250614-110000"
mkdir -p "${_FAKE_BTRFS}/root-20250613-100000-old"

# Create UKI for one of them
touch "${_FAKE_ESP}/EFI/Linux/arch-20250615-120000.efi"
touch "${_FAKE_ESP}/EFI/Linux/arch-20250614-110000.efi"
# No UKI for 20250613-100000-old

run_cmd bash "$_TEST_SCRIPT" --list
assert_eq "list → exit 0" "0" "$_rc"
assert_contains "shows subvolumes" "Subvolumes" "$_out"
assert_contains "UKI exists" "UKI exists" "$_out"
assert_contains "UKI missing" "UKI missing" "$_out"

# ── Invalid GEN_ID ──────────────────────────────────────────────────

section "Invalid GEN_ID"

_run_rebuild "invalid"
assert_eq "invalid → rc 1" "1" "$_rc"
assert_contains "error mentions format" "Invalid GEN_ID" "$_out"

_run_rebuild "20250615"
assert_eq "partial timestamp → rc 1" "1" "$_rc"

_run_rebuild ""
assert_eq "empty → rc 1" "1" "$_rc"

_run_rebuild "../../etc/passwd"
assert_eq "path traversal → rc 1" "1" "$_rc"

# ── Non-existent subvolume ──────────────────────────────────────────

section "Non-existent subvolume"

_run_rebuild "20250101-000000"
assert_eq "missing subvol → rc 1" "1" "$_rc"
assert_contains "error about subvolume" "Subvolume not found" "$_out"
assert_contains "suggests --list" "atomic-rebuild-uki --list" "$_out"

# ── Tagged generation rebuild ────────────────────────────────────────

section "Tagged generation rebuild"

TAGGED_GEN="20250616-130000-kde"
mkdir -p "${_FAKE_BTRFS}/root-${TAGGED_GEN}"
mkdir -p "${_FAKE_BTRFS}/root-${TAGGED_GEN}/boot"
mkdir -p "${_FAKE_BTRFS}/root-${TAGGED_GEN}/usr/lib/modules/6.14.0-arch1-1"
echo "linux" > "${_FAKE_BTRFS}/root-${TAGGED_GEN}/usr/lib/modules/6.14.0-arch1-1/pkgbase"
touch "${_FAKE_BTRFS}/root-${TAGGED_GEN}/boot/vmlinuz-linux"
touch "${_FAKE_BTRFS}/root-${TAGGED_GEN}/boot/initramfs-linux.img"
mkdir -p "${_FAKE_BTRFS}/root-${TAGGED_GEN}/etc"
echo "PRETTY_NAME=\"Arch Linux\"" > "${_FAKE_BTRFS}/root-${TAGGED_GEN}/etc/os-release"
mkdir -p "${_FAKE_BTRFS}/root-${TAGGED_GEN}/efi"

rm -f "${_FAKE_ESP}/EFI/Linux/arch-${TAGGED_GEN}.efi" 2>/dev/null || true

_run_rebuild "$TAGGED_GEN"
assert_eq "tagged rebuild → exit 0" "0" "$_rc"
assert_contains "tagged gen in output" "$TAGGED_GEN" "$_out"

# ── Cleanup trap structure ──────────────────────────────────────────

section "Cleanup trap: structure verification"

_script_content=$(cat "$SCRIPT")

assert_contains "cleanup function" "cleanup_rebuild()" "$_script_content"
assert_contains "EXIT trap" "trap cleanup_rebuild EXIT" "$_script_content"
assert_contains "unmounts MOUNT_DIR" 'MOUNT_DIR' "$_script_content"
assert_contains "rmdir MOUNT_DIR" 'rmdir' "$_script_content"
assert_contains "unmounts BTRFS" 'BTRFS_MOUNT' "$_script_content"
assert_contains "closes lock FD" 'LOCK_FD' "$_script_content"

# ── Version and help ────────────────────────────────────────────────

section "Version and help"

run_cmd bash "$SCRIPT" --version
assert_eq "version → exit 0" "0" "$_rc"
assert_contains "version output" "atomic-rebuild-uki v" "$_out"

run_cmd bash "$SCRIPT" --help
assert_eq "help → exit 0" "0" "$_rc"
assert_contains "usage" "Usage" "$_out"
assert_contains "list option" "list" "$_out"
assert_contains "GEN_ID mentioned" "GEN_ID" "$_out"

# ── Unknown option (real script requires root, so GEN_ID validation
#    is tested in test_rebuild_uki.sh with patched script) ──────────

section "Unknown option behavior"

# --bogus is treated as GEN_ID — real script checks EUID first
# so we verify the behavior with a quick patched test
_TEST_UO="${TESTDIR}/rebuild-unknown-test"
sed -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e '/^validate_config || exit 1$/s/^/# /' \
    "$SCRIPT" > "$_TEST_UO"
chmod +x "$_TEST_UO"

run_cmd bash "$_TEST_UO" --bogus
assert_eq "unknown option → rc 1" "1" "$_rc"
assert_contains "invalid GEN_ID error" "Invalid GEN_ID" "$_out"

# ── list_orphans function structure ─────────────────────────────────

section "list_orphans function structure"

assert_contains "list_orphans defined" "list_orphans()" "$_script_content"
assert_contains "subvolume glob" 'root-[0-9]' "$_script_content"
assert_contains "sort -r for reverse" "sort -r" "$_script_content"
assert_contains "empty message" "No generation subvolumes found" "$_script_content"

summary
