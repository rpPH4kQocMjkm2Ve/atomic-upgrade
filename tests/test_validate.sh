#!/usr/bin/env bash
# tests/test_validate.sh — Function defs, validate_config, check_dependencies
# Run: bash tests/test_validate.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── All expected functions are defined ───────────────────────

section "Function definitions"

EXPECTED_FUNCTIONS=(
    load_config validate_config check_dependencies acquire_lock
    chroot_snapshot
    is_child_of_aur_helper sign_uki verify_uki update_fstab
    update_fstab_home populate_home_skeleton
    get_current_subvol get_current_subvol_raw get_root_device
    ensure_btrfs_mounted validate_subvolume check_btrfs_space
    check_esp_space list_generations build_uki garbage_collect
    delete_generation warn_orphan_homes
)

for fn in "${EXPECTED_FUNCTIONS[@]}"; do
    if declare -f "$fn" >/dev/null 2>&1; then
        ok "function $fn defined"
    else
        fail "function $fn NOT defined"
    fi
done


# ── validate_config ──────────────────────────────────────────

section "validate_config"

make_mock mountpoint 'exit 0'
# Pre-fill cache so get_root_device succeeds
mkdir -p "${TESTDIR}/fake_dev"
touch "${TESTDIR}/fake_dev/root_crypt"
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"
KEEP_GENERATIONS=3
NEW_ROOT="/run/atomic/newroot"
BTRFS_MOUNT="/run/atomic/temp_root"

assert_rc "valid config passes" 0 validate_config

# KEEP_GENERATIONS not a number
KEEP_GENERATIONS="abc"
run_cmd validate_config
assert_eq "non-numeric KEEP_GENERATIONS → rc 1" "1" "$_rc"
KEEP_GENERATIONS=3

# KEEP_GENERATIONS = 0
KEEP_GENERATIONS=0
run_cmd validate_config
assert_eq "KEEP_GENERATIONS=0 → rc 1" "1" "$_rc"
assert_contains "KEEP_GENERATIONS error" "must be >= 1" "$_out"
KEEP_GENERATIONS=3

# NEW_ROOT == BTRFS_MOUNT
NEW_ROOT="/same/path"; BTRFS_MOUNT="/same/path"
run_cmd validate_config
assert_eq "same paths → rc 1" "1" "$_rc"
assert_contains "same path error" "must be different" "$_out"
NEW_ROOT="/run/atomic/newroot"; BTRFS_MOUNT="/run/atomic/temp_root"

# ESP not mounted and mount fails
make_mock mountpoint 'exit 1'
make_mock mount      'exit 1'
run_cmd validate_config
assert_eq "ESP not mounted → rc 1" "1" "$_rc"
assert_contains "ESP error" "ESP not mounted" "$_out"

# Restore
make_mock mountpoint 'exit 0'
make_mock mount      'exit 0'


# ── check_dependencies ──────────────────────────────────────

section "check_dependencies"

# check_dependencies verifies /usr/lib/atomic/{fstab,rootdev}.py exist.
# In CI the package isn't installed, so point LIBDIR at stub files.
_stub_lib="${TESTDIR}/atomic_lib_stub"
mkdir -p "$_stub_lib"
touch "${_stub_lib}/fstab.py" "${_stub_lib}/rootdev.py"

if [[ ! -f /usr/lib/atomic/fstab.py ]]; then
    LIBDIR="$_stub_lib"
fi

# Create an isolated bin dir with everything EXCEPT btrfs.
# This tests that check_dependencies correctly reports it missing.
_dep_bin="${TESTDIR}/dep_bin"
mkdir -p "$_dep_bin"
for cmd in ukify findmnt chroot unshare; do
    make_mock_in "$_dep_bin" "$cmd" 'exit 0'
done
# python3: return empty root type so cryptsetup isn't required
make_mock_in "$_dep_bin" python3 'echo ""'

# Temporarily replace PATH entirely so only dep_bin is searched
_save_path="$PATH"
PATH="$_dep_bin"
run_cmd check_dependencies
assert_eq "missing btrfs → rc 1" "1" "$_rc"
assert_contains "reports missing btrfs" "btrfs" "$_out"
PATH="$_save_path"


# ── check_dependencies: missing ukify ──
_dep_bin2="${TESTDIR}/dep_bin2"
mkdir -p "$_dep_bin2"
for cmd in btrfs findmnt chroot unshare; do
    make_mock_in "$_dep_bin2" "$cmd" 'exit 0'
done
# python3: return empty root type so cryptsetup isn't required
make_mock_in "$_dep_bin2" python3 'echo ""'
# Omit ukify

_save_path="$PATH"
PATH="$_dep_bin2"
run_cmd check_dependencies
assert_eq "missing ukify → rc 1" "1" "$_rc"
assert_contains "reports missing ukify" "ukify" "$_out"
PATH="$_save_path"

# ── check_dependencies: missing python3 ──
_dep_bin3="${TESTDIR}/dep_bin3"
mkdir -p "$_dep_bin3"
for cmd in btrfs ukify findmnt chroot unshare; do
    make_mock_in "$_dep_bin3" "$cmd" 'exit 0'
done
# Omit python3

_save_path="$PATH"
PATH="$_dep_bin3"
run_cmd check_dependencies
assert_eq "missing python3 → rc 1" "1" "$_rc"
assert_contains "reports missing python3" "python3" "$_out"
PATH="$_save_path"

# ── check_dependencies: LUKS root requires cryptsetup ──
_dep_bin4="${TESTDIR}/dep_bin4"
mkdir -p "$_dep_bin4"
for cmd in btrfs ukify findmnt chroot unshare; do
    make_mock_in "$_dep_bin4" "$cmd" 'exit 0'
done
# python3 mock: first call is "rootdev.py detect", second is "-c ..." JSON parser
# The pipe means two separate python3 invocations.
make_mock_in "$_dep_bin4" python3 '
if [[ "$1" == *"rootdev.py" || "$1" == *"rootdev"* ]]; then
    echo "{\"type\": \"luks\"}"
elif [[ "$1" == "-c" ]]; then
    echo "luks"
else
    echo ""
fi
'
# Omit cryptsetup

_save_path="$PATH"
PATH="$_dep_bin4"
run_cmd check_dependencies
assert_eq "LUKS without cryptsetup → rc 1" "1" "$_rc"
assert_contains "reports missing cryptsetup" "cryptsetup" "$_out"
PATH="$_save_path"

# ── check_dependencies: all present → rc 0 ──
_dep_bin5="${TESTDIR}/dep_bin5"
mkdir -p "$_dep_bin5"
for cmd in btrfs ukify findmnt chroot unshare; do
    make_mock_in "$_dep_bin5" "$cmd" 'exit 0'
done
make_mock_in "$_dep_bin5" python3 'echo ""'

_save_path="$PATH"
PATH="$_dep_bin5"
run_cmd check_dependencies
assert_eq "all deps present → rc 0" "0" "$_rc"
PATH="$_save_path"

# ── check_dependencies: SBCTL_SIGN=1 requires sbctl ──
_dep_bin6="${TESTDIR}/dep_bin6"
mkdir -p "$_dep_bin6"
for cmd in btrfs ukify findmnt chroot unshare; do
    make_mock_in "$_dep_bin6" "$cmd" 'exit 0'
done
make_mock_in "$_dep_bin6" python3 'echo ""'
# Omit sbctl

_save_path="$PATH"
SBCTL_SIGN=1
PATH="$_dep_bin6"
run_cmd check_dependencies
assert_eq "SBCTL_SIGN=1 without sbctl → rc 1" "1" "$_rc"
assert_contains "reports missing sbctl" "sbctl" "$_out"
PATH="$_save_path"
SBCTL_SIGN=0


# ── is_child_of_aur_helper ──────────────────────────────────

section "is_child_of_aur_helper"

# In a normal test run we are not a child of yay/paru
run_cmd is_child_of_aur_helper
assert_eq "not child of aur helper" "1" "$_rc"


summary
