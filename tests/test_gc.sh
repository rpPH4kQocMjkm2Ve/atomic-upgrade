#!/usr/bin/env bash
# tests/test_gc.sh — GC, generation listing/deletion, orphan handling
# Run: bash tests/test_gc.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


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


# ── Empty directory: no glob artifacts ──
ESP="${TESTDIR}/esp_nullglob"
mkdir -p "${ESP}/EFI/Linux"

result=$(list_generations)
rc=$?
assert_eq "empty dir → rc 0" "0" "$rc"
assert_eq "empty dir → no output" "" "$result"

# Verify nullglob did not leak into caller
_ng_test=( /nonexistent_path_$$/no_such_* )
assert_eq "nullglob not leaked to caller" "1" "${#_ng_test[@]}"

# Restore ESP for subsequent tests
ESP="${TESTDIR}/esp"


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

# ── Invalid gen_id format → rejected before any action ──
run_cmd delete_generation "invalid" 0 "root-20250601-120000"
assert_eq "rejects non-timestamp gen_id" "1" "$_rc"
assert_contains "format error message" "Invalid generation ID format" "$_out"

run_cmd delete_generation "../../etc" 0 "root-20250601-120000"
assert_eq "rejects path traversal gen_id" "1" "$_rc"
assert_contains "format error on traversal" "Invalid generation ID format" "$_out"

run_cmd delete_generation "" 0 "root-20250601-120000"
assert_eq "rejects empty gen_id" "1" "$_rc"

run_cmd delete_generation "20250615" 0 "root-20250601-120000"
assert_eq "rejects partial timestamp" "1" "$_rc"

# Valid formats accepted (dry run)
run_cmd delete_generation "20250615-120000" 1 "root-20250601-120000"
assert_eq "accepts valid plain gen_id" "0" "$_rc"

run_cmd delete_generation "20250615-120000-kde" 1 "root-20250601-120000"
assert_eq "accepts valid tagged gen_id" "0" "$_rc"

# Restore findmnt
make_mock findmnt 'echo "rw,subvol=/root-20250601-120000"'


# ── garbage_collect ──────────────────────────────────────────

section "garbage_collect"

# Each gc sub-test uses isolated ESP/BTRFS_MOUNT directories
# to avoid state leaking between tests (mock btrfs doesn't
# actually delete directories, so leftover dirs cause spurious
# orphan detections).

# Pre-fill root device cache so ensure_btrfs_mounted doesn't fail
mkdir -p "${TESTDIR}/fake_dev"
touch "${TESTDIR}/fake_dev/root_crypt"
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"

# ── Main gc: keep=2, delete oldest 2 of 4 non-current ──
ESP="${TESTDIR}/esp_gc"
BTRFS_MOUNT="${TESTDIR}/btrfs_gc"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

make_mock findmnt    'echo "rw,subvol=/root-20250605-120000"'
make_mock btrfs      'exit 0'
make_mock mountpoint 'exit 0'

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


# ── warn_orphan_homes ──────────────────────────────

section "warn_orphan_homes"

ESP="${TESTDIR}/esp_woh"
BTRFS_MOUNT="${TESTDIR}/btrfs_woh"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"
make_mock mountpoint 'exit 0'

# ── Tagged gen is last with that tag → warns ──
mkdir -p "${BTRFS_MOUNT}/home-vim"
touch "${ESP}/EFI/Linux/arch-20260320-034104-vim.efi"
# No other UKI with tag "vim"

run_cmd warn_orphan_homes "20260320-034104-vim"
assert_contains "warns about orphan home-vim" "home-vim" "$_out"
assert_contains "shows removal hint" "btrfs subvolume delete" "$_out"

# ── Another gen with same tag exists → no warning ──
touch "${ESP}/EFI/Linux/arch-20260321-010000-vim.efi"

run_cmd warn_orphan_homes "20260320-034104-vim"
assert_not_contains "no warning when other vim gen exists" "home-vim" "$_out"

rm -f "${ESP}/EFI/Linux/arch-20260321-010000-vim.efi"

# ── Both gens with same tag deleted at once → warns ──
touch "${ESP}/EFI/Linux/arch-20260321-010000-vim.efi"

run_cmd warn_orphan_homes "20260320-034104-vim" "20260321-010000-vim"
assert_contains "warns when all vim gens deleted" "home-vim" "$_out"

rm -f "${ESP}/EFI/Linux/arch-20260321-010000-vim.efi"

# ── Untagged gen → no warning ──
run_cmd warn_orphan_homes "20260320-034104"
assert_eq "untagged gen → no output" "" "$_out"

# ── No home subvolume for tag → no warning ──
rm -rf "${BTRFS_MOUNT}/home-vim"
touch "${ESP}/EFI/Linux/arch-20260320-034104-vim.efi"

run_cmd warn_orphan_homes "20260320-034104-vim"
assert_eq "no home subvol → no output" "" "$_out"

# ── Tag substring mismatch: home-vim not warned by super-vim ──
mkdir -p "${BTRFS_MOUNT}/home-vim"
touch "${ESP}/EFI/Linux/arch-20260322-010000-super-vim.efi"

run_cmd warn_orphan_homes "20260322-010000-super-vim"
assert_not_contains "super-vim does not affect home-vim" "home-vim" "$_out"

rm -f "${ESP}/EFI/Linux/arch-20260322-010000-super-vim.efi"

# Cleanup
rm -f "${ESP}/EFI/Linux/arch-20260320-034104-vim.efi"


# ── orphan home subvolumes in GC ──────────────

section "garbage_collect: orphan home subvolumes"

ESP="${TESTDIR}/esp_orphan_home"
BTRFS_MOUNT="${TESTDIR}/btrfs_orphan_home"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

make_mock findmnt    'echo "rw,subvol=/root-20250605-120000"'
make_mock btrfs      'exit 0'
make_mock mountpoint 'exit 0'

# Current generation
touch "${ESP}/EFI/Linux/arch-20250605-120000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250605-120000"

# Generation with tag "kde"
touch "${ESP}/EFI/Linux/arch-20250604-100000-kde.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250604-100000-kde"

# Home subvolume matching the tag — NOT orphan
mkdir -p "${BTRFS_MOUNT}/home-kde"

# Orphan home subvolume — no generation with tag "old-test"
mkdir -p "${BTRFS_MOUNT}/home-old-test"

run_cmd garbage_collect 3 0
assert_contains "orphan home detected" "Orphan home" "$_out"
assert_contains "orphan mentions tag" "old-test" "$_out"
assert_not_contains "non-orphan home not flagged" "Orphan home: home-kde" "$_out"

# Verify home subvolumes are never deleted (even orphans)
[[ -d "${BTRFS_MOUNT}/home-old-test" ]] \
    && ok "orphan home NOT auto-deleted" || fail "orphan home was deleted"
[[ -d "${BTRFS_MOUNT}/home-kde" ]] \
    && ok "active home preserved" || fail "active home was deleted"

# ── GC orphan home: glob false positive (tag suffix match) ──
# Regression test: glob "*-${tag}.efi" would match "super-kde" for
# home-kde.  The regex-based check must require an exact tag match.

section "garbage_collect: orphan home glob false positive"

ESP="${TESTDIR}/esp_orphan_glob"
BTRFS_MOUNT="${TESTDIR}/btrfs_orphan_glob"
mkdir -p "${ESP}/EFI/Linux" "$BTRFS_MOUNT"

make_mock findmnt    'echo "rw,subvol=/root-20250605-120000"'
make_mock btrfs      'exit 0'
make_mock mountpoint 'exit 0'

# Current generation (untagged)
touch "${ESP}/EFI/Linux/arch-20250605-120000.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250605-120000"

# Generation with tag "super-kde" — must NOT protect home-kde
touch "${ESP}/EFI/Linux/arch-20250604-100000-super-kde.efi"
mkdir -p "${BTRFS_MOUNT}/root-20250604-100000-super-kde"

# home-kde: no generation with exact tag "kde" → must be orphan
mkdir -p "${BTRFS_MOUNT}/home-kde"

# home-super-kde: has a matching generation → not orphan
mkdir -p "${BTRFS_MOUNT}/home-super-kde"

run_cmd garbage_collect 3 0
assert_contains "glob fp: home-kde flagged as orphan" "Orphan home: home-kde" "$_out"
assert_not_contains "glob fp: home-super-kde not orphan" "Orphan home: home-super-kde" "$_out"


summary
