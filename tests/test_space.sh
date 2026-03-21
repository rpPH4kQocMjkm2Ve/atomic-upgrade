#!/usr/bin/env bash
# tests/test_space.sh — ESP and btrfs space checking
# Run: bash tests/test_space.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


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

# ── Non-numeric btrfs output → df fallback ──
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo "    Device size:                 unknown"
    echo "    Free (estimated):            N/A"
fi
'
make_mock df '
if echo "$*" | grep -q -- "-B1"; then
    echo "     Size     Avail"
    echo "107374182400 53687091200"
else
    echo ""
fi
'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "non-numeric btrfs → df fallback → rc 0" "0" "$_rc"
assert_contains "reports space from df" "Disk space" "$_out"

# ── Empty btrfs output + empty df → graceful warn ──
make_mock btrfs '
if echo "$*" | grep -q "usage"; then
    echo ""
fi
'
make_mock df 'echo ""'
run_cmd check_btrfs_space "${TESTDIR}" 10
assert_eq "empty btrfs + empty df → rc 0 (warn)" "0" "$_rc"
assert_contains "warns about indeterminate space" "Cannot determine" "$_out"

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


summary
