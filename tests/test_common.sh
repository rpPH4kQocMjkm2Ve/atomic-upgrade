#!/usr/bin/env bash
# tests/test_common.sh
#
# Unit tests for lib/atomic/common.sh
# Mocks all external commands (btrfs, findmnt, python3, etc.)
# Run: bash tests/test_common.sh

# No set -e: tests intentionally trigger non-zero returns.
# set -u catches typos in variable names.
set -uo pipefail

PASS=0
FAIL=0
TESTS=0

# ── Test helpers ─────────────────────────────────────────────

ok() {
    PASS=$((PASS + 1))
    TESTS=$((TESTS + 1))
    echo "  ✓ $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TESTS=$((TESTS + 1))
    echo "  ✗ $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$desc"
    else
        fail "$desc (expected='$expected', got='$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        ok "$desc"
    else
        fail "$desc (pattern='$pattern' not found in '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        fail "$desc (needle='$needle' not in output)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$desc"
    else
        fail "$desc (needle='$needle' unexpectedly found)"
    fi
}

# Run command in subshell, capture rc + combined stdout/stderr.
# Sets globals: _rc, _out
# Use when side effects in parent shell are NOT needed.
run_cmd() {
    _rc=0
    _out=$("$@" 2>&1) || _rc=$?
}

# Check only the return code (suppress output).
# Use for simple pass/fail where output doesn't matter.
assert_rc() {
    local desc="$1" expected="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$expected" "$rc"
}

section() {
    echo ""
    echo "── $1 ──"
}

# ── Setup test environment ───────────────────────────────────

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Create mock bin directory — prepended to PATH so mocks override real cmds
MOCK_BIN="${TESTDIR}/mock_bin"
mkdir -p "$MOCK_BIN"

# Save original PATH for later restoration
ORIG_PATH="$PATH"

# Write a mock script into MOCK_BIN.
# Args: name [body]
# The body receives all original arguments in $@ / $* / "$1" etc.
make_mock() {
    local name="$1"; shift
    local body="${*:-exit 0}"
    cat > "${MOCK_BIN}/${name}" <<ENDSCRIPT
#!/bin/bash
${body}
ENDSCRIPT
    chmod +x "${MOCK_BIN}/${name}"
}

# Write a mock script into an arbitrary directory.
# Used by check_dependencies test to create an isolated PATH.
make_mock_in() {
    local dir="$1" name="$2"; shift 2
    local body="${*:-exit 0}"
    mkdir -p "$dir"
    cat > "${dir}/${name}" <<ENDSCRIPT
#!/bin/bash
${body}
ENDSCRIPT
    chmod +x "${dir}/${name}"
}

# ── Prepare environment before sourcing common.sh ────────────

export PATH="${MOCK_BIN}:${PATH}"

# Smart stat mock: intercept ownership checks (stat -c %u),
# proxy everything else to real stat.  A blanket "echo 0" mock
# would break anything internally relying on stat.
REAL_STAT=$(command -v stat 2>/dev/null || echo /usr/bin/stat)
make_mock stat "
if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%u\" ]]; then
    echo \"0\"
else
    exec \"${REAL_STAT}\" \"\$@\"
fi
"

make_mock findmnt    'echo ""'
make_mock mountpoint 'exit 0'
make_mock python3    'echo ""'
make_mock mount      'exit 0'
make_mock btrfs      'exit 0'
make_mock flock      'exit 0'
make_mock df         'echo ""'

# Prevent load_config from reading a real config at source time.
# load_config() is called at line 74 of common.sh during source;
# pointing to a nonexistent file makes it a harmless no-op.
export CONFIG_FILE="${TESTDIR}/nonexistent.conf"

# Resolve project root (tests/ is one level below)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/atomic/common.sh
source "${PROJECT_ROOT}/lib/atomic/common.sh"


# ═══════════════════════════════════════════════════════════════
#  TEST SUITE
# ═══════════════════════════════════════════════════════════════

# ── All expected functions are defined ───────────────────────

section "Function definitions"

EXPECTED_FUNCTIONS=(
    load_config validate_config check_dependencies acquire_lock
    is_child_of_aur_helper sign_uki verify_uki update_fstab
    get_current_subvol get_current_subvol_raw get_root_device
    ensure_btrfs_mounted validate_subvolume check_btrfs_space
    check_esp_space list_generations build_uki garbage_collect
    delete_generation
)

for fn in "${EXPECTED_FUNCTIONS[@]}"; do
    if declare -f "$fn" >/dev/null 2>&1; then
        ok "function $fn defined"
    else
        fail "function $fn NOT defined"
    fi
done


# ── Default values after sourcing ────────────────────────────

section "Default values"

assert_eq "BTRFS_MOUNT default" "/run/atomic/temp_root" "$BTRFS_MOUNT"
assert_eq "NEW_ROOT default"    "/run/atomic/newroot"    "$NEW_ROOT"
assert_eq "ESP default"         "/efi"                   "$ESP"
assert_eq "KEEP_GENERATIONS default" "3"                 "$KEEP_GENERATIONS"
assert_eq "MAPPER_NAME default" "root_crypt"             "$MAPPER_NAME"
assert_eq "KERNEL_PKG default"  "linux"                  "$KERNEL_PKG"
assert_eq "LOCK_FILE default"   "/var/lock/atomic-upgrade.lock" "$LOCK_FILE"
assert_eq "SBCTL_SIGN default"  "0"                      "$SBCTL_SIGN"
assert_eq "UPGRADE_GUARD default" "1"                    "$UPGRADE_GUARD"
assert_match "KERNEL_PARAMS contains rw"     "rw"     "$KERNEL_PARAMS"
assert_match "KERNEL_PARAMS contains pti=on" "pti=on" "$KERNEL_PARAMS"


# ── load_config() ───────────────────────────────────────────

section "load_config"

# Test: config file does not exist → success (no-op)
CONFIG_FILE="${TESTDIR}/no_such_file.conf"
assert_rc "missing config file → rc 0" 0 load_config

# Test: valid config file — direct call so side effects
# (variable assignments) are visible in the parent shell
CONFIG_FILE="${TESTDIR}/good.conf"
cat > "$CONFIG_FILE" <<'EOF'
# This is a comment
KEEP_GENERATIONS=5
ESP=/boot/efi
SBCTL_SIGN=1
KERNEL_PKG=linux-zen
EOF
KEEP_GENERATIONS=3; ESP="/efi"; SBCTL_SIGN=0; KERNEL_PKG="linux"
load_config
assert_eq "KEEP_GENERATIONS loaded" "5"         "$KEEP_GENERATIONS"
assert_eq "ESP loaded"              "/boot/efi" "$ESP"
assert_eq "SBCTL_SIGN loaded"      "1"          "$SBCTL_SIGN"
assert_eq "KERNEL_PKG loaded"      "linux-zen"  "$KERNEL_PKG"

# Restore defaults for subsequent tests
KEEP_GENERATIONS=3; ESP="/efi"; SBCTL_SIGN=0; KERNEL_PKG="linux"

# Test: quoted values — both single and double quotes stripped
CONFIG_FILE="${TESTDIR}/quoted.conf"
cat > "$CONFIG_FILE" <<'EOF'
ESP="/boot/efi"
KERNEL_PKG='linux-lts'
EOF
load_config
assert_eq "double-quoted value" "/boot/efi" "$ESP"
assert_eq "single-quoted value" "linux-lts"  "$KERNEL_PKG"
ESP="/efi"; KERNEL_PKG="linux"

# Test: inline comments stripped
CONFIG_FILE="${TESTDIR}/inline.conf"
cat > "$CONFIG_FILE" <<'EOF'
KEEP_GENERATIONS=7 # keep seven
EOF
KEEP_GENERATIONS=3
load_config
assert_eq "inline comment stripped" "7" "$KEEP_GENERATIONS"
KEEP_GENERATIONS=3

# Test: value containing # without leading space — must NOT be stripped
CONFIG_FILE="${TESTDIR}/hash_in_value.conf"
cat > "$CONFIG_FILE" <<'EOF'
KERNEL_PARAMS=rw console=ttyS0,115200n8#1
EOF
KERNEL_PARAMS="default"
load_config
assert_eq "hash without space preserved" "rw console=ttyS0,115200n8#1" "$KERNEL_PARAMS"
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"

# Test: unknown key → warning on stderr, known keys still applied.
# Direct call for side effects; capture stderr to file.
CONFIG_FILE="${TESTDIR}/unknown.conf"
cat > "$CONFIG_FILE" <<'EOF'
EVIL_KEY=hacked
KEEP_GENERATIONS=2
EOF
KEEP_GENERATIONS=3
load_config 2>"${TESTDIR}/unknown_stderr.txt"
assert_eq "known key still works with unknown present" "2" "$KEEP_GENERATIONS"
_captured=$(cat "${TESTDIR}/unknown_stderr.txt")
assert_contains "warns about unknown key" "Unknown config key" "$_captured"
KEEP_GENERATIONS=3

# Test: config not owned by root → error, variables unchanged.
# run_cmd (subshell) is safe here: we verify value did NOT change.
CONFIG_FILE="${TESTDIR}/badowner.conf"
cat > "$CONFIG_FILE" <<'EOF'
KEEP_GENERATIONS=9
EOF
make_mock stat "
if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%u\" ]]; then
    echo \"1000\"
else
    exec \"${REAL_STAT}\" \"\$@\"
fi
"
KEEP_GENERATIONS=3
run_cmd load_config
assert_eq "bad owner returns error"       "1" "$_rc"
assert_eq "bad owner doesn't change value" "3" "$KEEP_GENERATIONS"
assert_contains "bad owner error message" "not owned by root" "$_out"

# Restore stat mock to uid 0
make_mock stat "
if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%u\" ]]; then
    echo \"0\"
else
    exec \"${REAL_STAT}\" \"\$@\"
fi
"


# ── UPGRADE_GUARD config ─────────────────────────────────────

section "UPGRADE_GUARD config"

# Test: UPGRADE_GUARD=0 disables guard
CONFIG_FILE="${TESTDIR}/guard_off.conf"
cat > "$CONFIG_FILE" <<'EOF'
UPGRADE_GUARD=0
EOF
UPGRADE_GUARD=1
load_config
assert_eq "UPGRADE_GUARD=0 loaded" "0" "$UPGRADE_GUARD"

# Test: UPGRADE_GUARD=1 explicitly enables guard
CONFIG_FILE="${TESTDIR}/guard_on.conf"
cat > "$CONFIG_FILE" <<'EOF'
UPGRADE_GUARD=1
EOF
UPGRADE_GUARD=0
load_config
assert_eq "UPGRADE_GUARD=1 loaded" "1" "$UPGRADE_GUARD"

# Test: quoted UPGRADE_GUARD values
CONFIG_FILE="${TESTDIR}/guard_quoted.conf"
cat > "$CONFIG_FILE" <<'EOF'
UPGRADE_GUARD="0"
EOF
UPGRADE_GUARD=1
load_config
assert_eq "UPGRADE_GUARD quoted value" "0" "$UPGRADE_GUARD"

# Test: UPGRADE_GUARD absent → default preserved
CONFIG_FILE="${TESTDIR}/guard_absent.conf"
cat > "$CONFIG_FILE" <<'EOF'
KEEP_GENERATIONS=3
EOF
UPGRADE_GUARD=1
load_config
assert_eq "UPGRADE_GUARD absent → stays 1" "1" "$UPGRADE_GUARD"

# Test: UPGRADE_GUARD=0 with inline comment
CONFIG_FILE="${TESTDIR}/guard_comment.conf"
cat > "$CONFIG_FILE" <<'EOF'
UPGRADE_GUARD=0 # disable protection
EOF
UPGRADE_GUARD=1
load_config
assert_eq "UPGRADE_GUARD with inline comment" "0" "$UPGRADE_GUARD"

# Restore
UPGRADE_GUARD=1


# ── get_current_subvol / get_current_subvol_raw ─────────────

section "get_current_subvol"

# Typical btrfs mount options with subvol at the end
make_mock findmnt 'echo "rw,noatime,compress=zstd:3,ssd,subvol=/root-20250601-120000"'
result_raw=$(get_current_subvol_raw)
assert_eq "get_current_subvol_raw" "/root-20250601-120000" "$result_raw"

result=$(get_current_subvol)
assert_eq "get_current_subvol strips slash" "root-20250601-120000" "$result"

# Subvol without leading slash
make_mock findmnt 'echo "rw,subvol=root-20250601-120000"'
result=$(get_current_subvol)
assert_eq "get_current_subvol without slash" "root-20250601-120000" "$result"

# subvol in the middle of options (not last)
make_mock findmnt 'echo "rw,noatime,subvol=/myroot,compress=zstd"'
result_raw=$(get_current_subvol_raw)
assert_eq "subvol in middle of options" "/myroot" "$result_raw"


# ── get_root_device ──────────────────────────────────────────

section "get_root_device"

# Clear cache
_ROOT_DEVICE=""

# Make python3 return a path that actually exists on the filesystem
mkdir -p "${TESTDIR}/fake_dev"
touch "${TESTDIR}/fake_dev/root_crypt"
make_mock python3 "echo '${TESTDIR}/fake_dev/root_crypt'"

result=$(get_root_device)
assert_eq "get_root_device from python" "${TESTDIR}/fake_dev/root_crypt" "$result"

# Test caching: first call ran in subshell $(), so parent
# _ROOT_DEVICE is still empty.  Set it manually to test
# that the cache prevents re-calling python3.
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"
make_mock python3 'echo "/dev/should_not_be_called"'
result=$(get_root_device)
assert_eq "get_root_device cached" "${TESTDIR}/fake_dev/root_crypt" "$result"

# Test error case: python3 returns empty, MAPPER_NAME doesn't resolve
_ROOT_DEVICE=""
make_mock python3 'echo ""'
MAPPER_NAME="nonexistent_mapper_xyz_$$"
run_cmd get_root_device
assert_eq "get_root_device fails when nothing found" "1" "$_rc"
assert_contains "error message on failure" "Cannot detect" "$_out"
MAPPER_NAME="root_crypt"


# ── list_generations ─────────────────────────────────────────

section "list_generations"

ESP="${TESTDIR}/esp"
mkdir -p "${ESP}/EFI/Linux"

# No generations
result=$(list_generations)
assert_eq "no generations → empty" "" "$result"

# Create some UKI files
touch "${ESP}/EFI/Linux/arch-20250601-120000.efi"
touch "${ESP}/EFI/Linux/arch-20250602-090000.efi"
touch "${ESP}/EFI/Linux/arch-20250530-180000.efi"
# Non-matching file should be ignored
touch "${ESP}/EFI/Linux/something-else.efi"

result=$(list_generations)
first=$(echo "$result" | head -1)
last=$(echo "$result"  | tail -1)
count=$(echo "$result" | wc -l | tr -d ' ')

assert_eq "list_generations count"        "3"               "$count"
assert_eq "list_generations newest first" "20250602-090000" "$first"
assert_eq "list_generations oldest last"  "20250530-180000" "$last"
assert_not_contains "non-arch files excluded" "something-else" "$result"


# ── delete_generation ────────────────────────────────────────

section "delete_generation"

BTRFS_MOUNT="${TESTDIR}/btrfs"
mkdir -p "${BTRFS_MOUNT}/root-20250530-180000"
touch "${ESP}/EFI/Linux/arch-20250530-180000.efi"

make_mock btrfs   'exit 0'
# Current subvol is root-20250601-120000
make_mock findmnt 'echo "rw,subvol=/root-20250601-120000"'

# Refuse to delete current generation
run_cmd delete_generation "20250601-120000" 0 "root-20250601-120000"
assert_eq "refuse to delete current → rc 1" "1" "$_rc"
assert_contains "refuse message" "REFUSE" "$_out"

# Dry run: reports but does NOT delete
run_cmd delete_generation "20250530-180000" 1 "root-20250601-120000"
assert_contains "dry run says 'Would delete'" "Would delete" "$_out"
[[ -f "${ESP}/EFI/Linux/arch-20250530-180000.efi" ]] \
    && ok "dry run keeps UKI" || fail "dry run deleted UKI"

# Actual delete
delete_generation "20250530-180000" 0 "root-20250601-120000" >/dev/null 2>&1
[[ ! -f "${ESP}/EFI/Linux/arch-20250530-180000.efi" ]] \
    && ok "actual delete removes UKI" || fail "actual delete kept UKI"

# Delete with auto-detected current_subvol (pass empty 3rd arg →
# function calls get_current_subvol internally)
touch "${ESP}/EFI/Linux/arch-20250602-090000.efi"
make_mock findmnt 'echo "rw,subvol=/root-20250601-120000"'
delete_generation "20250602-090000" 0 "" >/dev/null 2>&1
[[ ! -f "${ESP}/EFI/Linux/arch-20250602-090000.efi" ]] \
    && ok "delete with auto-detect current" || fail "delete with auto-detect failed"

# Delete when current subvol cannot be determined → refuse
make_mock findmnt 'echo ""'
run_cmd delete_generation "20250601-120000" 0 ""
assert_eq "refuse when current unknown" "1" "$_rc"

# Restore findmnt
make_mock findmnt 'echo "rw,subvol=/root-20250601-120000"'


# ── sign_uki / verify_uki ───────────────────────────────────

section "sign_uki / verify_uki"

# SBCTL_SIGN=0 → skip signing
SBCTL_SIGN=0
run_cmd sign_uki "/fake/path.efi"
assert_contains "sign skip message" "Skipping" "$_out"

# SBCTL_SIGN=1 → call sbctl sign
SBCTL_SIGN=1
make_mock sbctl 'exit 0'
run_cmd sign_uki "/fake/path.efi"
assert_eq "sign success → rc 0" "0" "$_rc"
assert_contains "sign calls sbctl" "Signing" "$_out"

# sbctl sign fails → propagate error
make_mock sbctl 'exit 1'
run_cmd sign_uki "/fake/path.efi"
assert_eq "sign failure → rc 1" "1" "$_rc"

# verify with SBCTL_SIGN=1
make_mock sbctl 'exit 0'
run_cmd verify_uki "/fake/path.efi"
assert_contains "verify calls sbctl" "Verifying" "$_out"

# verify with SBCTL_SIGN=0 → silent no-op
SBCTL_SIGN=0
run_cmd verify_uki "/fake/path.efi"
assert_eq "verify skipped when SBCTL_SIGN=0" "" "$_out"


# ── check_esp_space ──────────────────────────────────────────

section "check_esp_space"

# df -k --output=avail → value in KB.  512000 KB = 500 MB
make_mock df 'echo -e "Avail\n512000"'
run_cmd check_esp_space 100
assert_eq "enough ESP space → rc 0" "0" "$_rc"
assert_contains "shows free space" "500" "$_out"

# 51200 KB = 50 MB — below the 100 MB threshold
make_mock df 'echo -e "Avail\n51200"'
run_cmd check_esp_space 100
assert_eq "low ESP space → rc 1" "1" "$_rc"
assert_contains "low space error" "Low ESP" "$_out"

# df returns empty → warning, rc 0
make_mock df 'echo ""'
run_cmd check_esp_space
assert_eq "df failure → rc 0 (warn)" "0" "$_rc"
assert_contains "df fail warns" "Cannot check" "$_out"

# Restore df mock
make_mock df 'echo -e "Avail\n512000"'


# ── validate_config ──────────────────────────────────────────

section "validate_config"

make_mock mountpoint 'exit 0'
# Pre-fill cache so get_root_device succeeds
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

# Create an isolated bin dir with everything EXCEPT btrfs.
# This tests that check_dependencies correctly reports it missing.
_dep_bin="${TESTDIR}/dep_bin"
mkdir -p "$_dep_bin"
for cmd in ukify findmnt arch-chroot; do
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


# ── ensure_btrfs_mounted ────────────────────────────────────

section "ensure_btrfs_mounted"

BTRFS_MOUNT="${TESTDIR}/mnt_btrfs"
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"

# Already mounted
make_mock mountpoint 'exit 0'
assert_rc "already mounted → rc 0" 0 ensure_btrfs_mounted
[[ -d "$BTRFS_MOUNT" ]] && ok "creates mount dir" || fail "didn't create mount dir"

# Not mounted, mount succeeds
make_mock mountpoint 'exit 1'
make_mock mount      'exit 0'
assert_rc "mount succeeds → rc 0" 0 ensure_btrfs_mounted

# Not mounted, mount fails
make_mock mountpoint 'exit 1'
make_mock mount      'exit 1'
run_cmd ensure_btrfs_mounted
assert_eq "mount fails → rc 1" "1" "$_rc"
assert_contains "mount error" "Failed to mount" "$_out"

# Restore
make_mock mountpoint 'exit 0'
make_mock mount      'exit 0'


# ── validate_subvolume ──────────────────────────────────────

section "validate_subvolume"

BTRFS_MOUNT="${TESTDIR}/mnt_val"
mkdir -p "${BTRFS_MOUNT}/root-20250601-120000"
make_mock mountpoint 'exit 0'
make_mock btrfs      'exit 0'

assert_rc "valid subvolume"    0 validate_subvolume "root-20250601-120000" "$BTRFS_MOUNT"
assert_rc "empty subvol name"  1 validate_subvolume "" "$BTRFS_MOUNT"
assert_rc "nonexistent subvol" 1 validate_subvolume "root-nonexistent" "$BTRFS_MOUNT"


# ── check_btrfs_space ───────────────────────────────────────

section "check_btrfs_space"

# btrfs mock: distinguish "usage" subcommand from other btrfs calls
# (e.g. "btrfs subvolume delete" used elsewhere)
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo "    Device size:                 107374182400"
    echo "    Free (estimated):             53687091200"
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "50% free → rc 0" "0" "$_rc"
assert_contains "shows percentage" "%" "$_out"

# btrfs fails → df fallback.
# df mock distinguishes -B1 (bytes, for btrfs) from -k (KB, for ESP).
make_mock btrfs 'exit 1'
make_mock df '
if echo "$*" | grep -q -- "-B1"; then
    echo "     Size     Avail"
    echo "1073741824 53687091"
else
    echo ""
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "5% free → rc 1" "1" "$_rc"
assert_contains "low disk space error" "Low disk space" "$_out"

# Both btrfs and df fail → warning, rc 0
make_mock btrfs 'exit 1'
make_mock df    'echo ""'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "cannot determine → rc 0 (warn)" "0" "$_rc"
assert_contains "warning message" "Cannot determine" "$_out"

# Restore
make_mock btrfs 'exit 0'
make_mock df    'echo -e "Avail\n512000"'


# ── check_btrfs_space: absolute minimum threshold ───────────

section "check_btrfs_space absolute minimum"

# Low percentage (3%) but plenty of absolute space (50GB) → pass with warning.
# Total ~1.6TB, free ~50GB: well above the 2GB absolute minimum.
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo "    Device size:              1717986918400"
    echo "    Free (estimated):           53687091200"
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "low % above abs min → rc 0" "0" "$_rc"
assert_contains "shows below-threshold note" "below" "$_out"
assert_contains "mentions absolute minimum" "minimum" "$_out"

# Low percentage (1%) AND low absolute space (0GB / ~100MB) → fail.
# Both thresholds crossed: percentage below 10% AND absolute below 2GB.
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo "    Device size:                 10737418240"
    echo "    Free (estimated):              107374182"
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "low % and low abs → rc 1" "1" "$_rc"
assert_contains "error mentions both thresholds" "or" "$_out"

# High percentage (50%) → normal message, no "below" warning
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo "    Device size:                 107374182400"
    echo "    Free (estimated):             53687091200"
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "high % → rc 0" "0" "$_rc"
assert_not_contains "no below warning for high %" "below" "$_out"

# Restore
make_mock btrfs 'exit 0'
make_mock df    'echo -e "Avail\n512000"'


# ── Config whitelist security ────────────────────────────────

section "Config security"

# Attempt to set dangerous variables via config —
# they must be rejected by the whitelist
CONFIG_FILE="${TESTDIR}/evil.conf"
cat > "$CONFIG_FILE" <<'EOF'
PATH=/evil/bin
LD_PRELOAD=/evil.so
HOME=/evil
KEEP_GENERATIONS=42
EOF
KEEP_GENERATIONS=3
_save_path="$PATH"
_save_home="$HOME"
_save_ld="${LD_PRELOAD:-}"

# Direct call — need side effects (KEEP_GENERATIONS=42 must apply)
load_config 2>/dev/null || true

assert_eq "evil PATH ignored"       "$_save_path" "$PATH"
assert_eq "evil HOME ignored"       "$_save_home" "$HOME"
assert_eq "evil LD_PRELOAD ignored" "$_save_ld"   "${LD_PRELOAD:-}"
assert_eq "whitelisted key still works" "42"       "$KEEP_GENERATIONS"
KEEP_GENERATIONS=3

# UPGRADE_GUARD must not be injectable via non-whitelisted names
CONFIG_FILE="${TESTDIR}/evil_guard.conf"
cat > "$CONFIG_FILE" <<'EOF'
UPGRADE_GUARD_OVERRIDE=0
upgrade_guard=0
EOF
UPGRADE_GUARD=1
load_config 2>/dev/null || true
assert_eq "UPGRADE_GUARD not affected by similar names" "1" "$UPGRADE_GUARD"


# ── KERNEL_PARAMS from config ───────────────────────────────

section "KERNEL_PARAMS config"

CONFIG_FILE="${TESTDIR}/params.conf"
cat > "$CONFIG_FILE" <<'EOF'
KERNEL_PARAMS=rw quiet splash
EOF
KERNEL_PARAMS="rw default"
load_config
assert_eq "KERNEL_PARAMS overridden" "rw quiet splash" "$KERNEL_PARAMS"
# Restore default
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"


# ── garbage_collect ──────────────────────────────────────────

section "garbage_collect"

# Each gc sub-test uses isolated ESP/BTRFS_MOUNT directories
# to avoid state leaking between tests (mock btrfs doesn't
# actually delete directories, so leftover dirs cause spurious
# orphan detections).

# ── Main gc: keep=2, delete oldest 2 of 4 non-current ──
ESP="${TESTDIR}/esp_gc"
BTRFS_MOUNT="${TESTDIR}/btrfs_gc"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

make_mock findmnt    'echo "rw,subvol=/root-20250605-120000"'
make_mock btrfs      'exit 0'
make_mock mountpoint 'exit 0'
# Pre-fill root device cache so ensure_btrfs_mounted doesn't fail
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"

# Create 5 generations (current + 4 others)
for ts in 20250601-100000 20250602-100000 20250603-100000 \
          20250604-100000 20250605-120000; do
    touch "${ESP}/EFI/Linux/arch-${ts}.efi"
    mkdir -p "${BTRFS_MOUNT}/root-${ts}"
done

KEEP_GENERATIONS=2
run_cmd garbage_collect 2 0
assert_contains "gc reports keeping"  "Keeping"  "$_out"
assert_contains "gc reports deleting" "Deleting" "$_out"
assert_contains "gc done"            "done"     "$_out"

# Current must never be deleted
[[ -f "${ESP}/EFI/Linux/arch-20250605-120000.efi" ]] \
    && ok "gc keeps current UKI" || fail "gc deleted current UKI"

# The 2 newest non-current should be kept
[[ -f "${ESP}/EFI/Linux/arch-20250604-100000.efi" ]] \
    && ok "gc keeps gen-1" || fail "gc deleted gen-1"
[[ -f "${ESP}/EFI/Linux/arch-20250603-100000.efi" ]] \
    && ok "gc keeps gen-2" || fail "gc deleted gen-2"

# Older should be deleted
[[ ! -f "${ESP}/EFI/Linux/arch-20250602-100000.efi" ]] \
    && ok "gc deletes gen-3" || fail "gc kept gen-3"
[[ ! -f "${ESP}/EFI/Linux/arch-20250601-100000.efi" ]] \
    && ok "gc deletes gen-4" || fail "gc kept gen-4"

# ── Orphan subvolume: subvol dir exists but no matching UKI ──
mkdir -p "${BTRFS_MOUNT}/root-20250510-999999"
run_cmd garbage_collect 2 0
assert_contains "orphan subvol detected" "Orphan" "$_out"

# ── Orphan UKI: UKI file exists but no matching subvol dir ──
# Fresh environment so the orphan isn't caught by the normal
# to_delete loop first (which would rm it before orphan detection).
# With keep=3 and only 2 gens total, nothing lands in to_delete,
# so the orphan UKI loop at lines 483-493 of common.sh fires.
ESP="${TESTDIR}/esp_orphan_uki"
BTRFS_MOUNT="${TESTDIR}/btrfs_orphan_uki"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

# Current generation: has both UKI and subvol
touch "${ESP}/EFI/Linux/arch-20250605-120000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250605-120000"

# Orphan UKI: has UKI but NO subvol directory
touch "${ESP}/EFI/Linux/arch-20250401-111111.efi"
# Intentionally do NOT create ${BTRFS_MOUNT}/root-20250401-111111

run_cmd garbage_collect 3 0
assert_contains "orphan UKI detected" "Orphan UKI" "$_out"
[[ ! -f "${ESP}/EFI/Linux/arch-20250401-111111.efi" ]] \
    && ok "orphan UKI removed" || fail "orphan UKI kept"

# ── Dry run: nothing actually deleted ──
ESP="${TESTDIR}/esp_dryrun"
BTRFS_MOUNT="${TESTDIR}/btrfs_dryrun"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

touch "${ESP}/EFI/Linux/arch-20250605-120000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250605-120000"
touch "${ESP}/EFI/Linux/arch-20250301-010101.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250301-010101"

run_cmd garbage_collect 0 1
assert_contains "dry run says would delete" "Would delete" "$_out"
[[ -f "${ESP}/EFI/Linux/arch-20250301-010101.efi" ]] \
    && ok "dry run keeps files" || fail "dry run deleted files"


# ── garbage_collect edge cases ───────────────────────────────

section "garbage_collect edge cases"

ESP="${TESTDIR}/esp_empty"
BTRFS_MOUNT="${TESTDIR}/btrfs_empty"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"
make_mock findmnt    'echo "rw,subvol=/root-20250605-120000"'
make_mock mountpoint 'exit 0'
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"

# No UKI files at all
run_cmd garbage_collect 3 0
assert_contains "empty ESP → no generations" "No generations" "$_out"

# Cannot determine current subvol → error
make_mock findmnt 'echo ""'
run_cmd garbage_collect 3 0
assert_eq "no current subvol → rc 1" "1" "$_rc"
assert_contains "error about current subvol" "Cannot determine" "$_out"

# Restore
make_mock findmnt 'echo "rw,subvol=/root-20250605-120000"'


# ── garbage_collect: ESP not mounted → skip orphan sweep ─────

section "garbage_collect: ESP not mounted"

ESP="${TESTDIR}/esp_no_mount"
BTRFS_MOUNT="${TESTDIR}/btrfs_no_mount"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

make_mock findmnt 'echo "rw,subvol=/root-20250605-120000"'
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"
make_mock btrfs 'exit 0'

# Current generation
touch "${ESP}/EFI/Linux/arch-20250605-120000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250605-120000"

# One non-current generation (within keep limit)
touch "${ESP}/EFI/Linux/arch-20250604-100000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250604-100000"

# Orphan subvol — would be detected if ESP were mounted
mkdir -p "${BTRFS_MOUNT}/root-20250510-999999"

# mountpoint: succeed for everything except ESP
make_mock mountpoint '
for a in "$@"; do
    [[ "$a" == "'"${ESP}"'" ]] && exit 1
done
exit 0
'

run_cmd garbage_collect 3 0
assert_eq "ESP not mounted → gc still succeeds" "0" "$_rc"
assert_contains "warns about ESP not mounted" "ESP not mounted" "$_out"
assert_contains "mentions skipping orphan sweep" "skipping orphan sweep" "$_out"
assert_not_contains "no orphan detected when ESP unmounted" "Orphan:" "$_out"
assert_not_contains "no orphan UKI when ESP unmounted" "Orphan UKI" "$_out"
assert_contains "gc still completes" "done" "$_out"

# Restore mountpoint mock
make_mock mountpoint 'exit 0'


# ── is_child_of_aur_helper ──────────────────────────────────

section "is_child_of_aur_helper"

# In a normal test run we are not a child of yay/paru
run_cmd is_child_of_aur_helper
assert_eq "not child of aur helper" "1" "$_rc"


# ═══════════════════════════════════════════════════════════════
#  RESULTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed (total: $TESTS)"
echo "════════════════════════════════════"

if [[ $FAIL -ne 0 ]]; then
    exit 1
fi
exit 0
