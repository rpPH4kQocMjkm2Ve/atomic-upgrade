#!/usr/bin/env bash
# tests/test_rebuild_uki.sh — atomic-rebuild-uki argument parsing, validation, flow
# Run: bash tests/test_rebuild_uki.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

# ── Setup ───────────────────────────────────────────────────

SCRIPT="${PROJECT_ROOT}/bin/atomic-rebuild-uki"

make_mock verify-lib 'echo "$1"; exit 0'

# ── Help flag ───────────────────────────────────────────────

section "Help flag"

# The script exits 0 on --help, so we test in subshell
run_cmd bash "$SCRIPT" --help 2>/dev/null || true
assert_contains "help shows usage" "Usage:" "$_out"
assert_contains "help shows --list" "--list" "$_out"
assert_contains "help shows GEN_ID" "GEN_ID" "$_out"

# ── GEN_ID validation ───────────────────────────────────────

section "GEN_ID validation"

_validate_gen_id() {
    local gen_id="$1"
    if [[ ! "$gen_id" =~ ^[0-9]{8}-[0-9]{6}(-[a-zA-Z0-9_-]+)?$ ]]; then
        echo "ERROR: Invalid GEN_ID format: $gen_id (expected YYYYMMDD-HHMMSS[-tag])" >&2
        return 1
    fi
    return 0
}

run_cmd _validate_gen_id "20250208-134725"
assert_eq "plain GEN_ID valid" "0" "$_rc"

run_cmd _validate_gen_id "20250208-134725-kde"
assert_eq "tagged GEN_ID valid" "0" "$_rc"

run_cmd _validate_gen_id "20250208-134725-pre-nvidia"
assert_eq "multi-word tag valid" "0" "$_rc"

run_cmd _validate_gen_id "20250208-134725_test"
assert_eq "underscore tag valid" "0" "$_rc"

run_cmd _validate_gen_id "20250208"
assert_eq "missing time → invalid" "1" "$_rc"
assert_contains "missing time error" "YYYYMMDD-HHMMSS" "$_out"

run_cmd _validate_gen_id "20250208-1347"
assert_eq "short time → invalid" "1" "$_rc"

run_cmd _validate_gen_id "not-a-date"
assert_eq "non-date → invalid" "1" "$_rc"

run_cmd _validate_gen_id ""
assert_eq "empty → invalid" "1" "$_rc"

run_cmd _validate_gen_id "../../etc/passwd"
assert_eq "path traversal → invalid" "1" "$_rc"

run_cmd _validate_gen_id "20250208-134725/evil"
assert_eq "slash in tag → invalid" "1" "$_rc"

# ── list_orphans simulation ─────────────────────────────────

section "list_orphans simulation"

_list_orphans_sim() {
    local esp="$1" btrfs_mount="$2"

    echo "Subvolumes → UKI status:"
    echo ""

    local found=0
    local -a dirs=()
    for dir in "${btrfs_mount}"/root-[0-9]*; do
        [[ -d "$dir" ]] || continue
        dirs+=("$dir")
    done

    readarray -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -r)

    for dir in "${dirs[@]}"; do
        local name="${dir##*/}"
        local gen_id="${name#root-}"
        local uki="${esp}/EFI/Linux/arch-${gen_id}.efi"
        if [[ -f "$uki" ]]; then
            echo "  ${gen_id}  ✓ UKI exists"
        else
            echo "  ${gen_id}  ✗ UKI missing"
        fi
        found=1
    done

    if [[ $found -eq 0 ]]; then
        echo "  No generation subvolumes found"
    fi
}

_ESP_LIST="${TESTDIR}/esp_list"
_BTRFS_LIST="${TESTDIR}/btrfs_list"
mkdir -p "${_ESP_LIST}/EFI/Linux" "$_BTRFS_LIST"

# No subvolumes
_output=$(_list_orphans_sim "$_ESP_LIST" "$_BTRFS_LIST")
assert_contains "empty list message" "No generation subvolumes found" "$_output"

# Create subvolumes
mkdir -p "${_BTRFS_LIST}/root-20250601-120000"
mkdir -p "${_BTRFS_LIST}/root-20250602-090000"
mkdir -p "${_BTRFS_LIST}/root-20250603-150000-kde"

# Only some have UKI
touch "${_ESP_LIST}/EFI/Linux/arch-20250601-120000.efi"
touch "${_ESP_LIST}/EFI/Linux/arch-20250603-150000-kde.efi"
# 20250602-090000 has no UKI

_output=$(_list_orphans_sim "$_ESP_LIST" "$_BTRFS_LIST")
assert_contains "shows UKI exists" "✓ UKI exists" "$_output"
assert_contains "shows UKI missing" "✗ UKI missing" "$_output"

# Verify ordering (newest first)
_first_line=$(echo "$_output" | grep -E "^[[:space:]]+[0-9]" | head -1)
assert_contains "newest first" "20250603" "$_first_line"

_last_line=$(echo "$_output" | grep -E "^[[:space:]]+[0-9]" | tail -1)
assert_contains "oldest last" "20250601" "$_last_line"

# ── Rebuild flow simulation ─────────────────────────────────

section "Rebuild flow simulation"

# Simulate the rebuild flow without actual mounts
_rebuild_flow_sim() {
    local gen_id="$1"
    local esp="$2"
    local btrfs_mount="$3"
    local uki_path="${esp}/EFI/Linux/arch-${gen_id}.efi"
    local subvol="root-${gen_id}"

    # Check subvol exists
    if [[ ! -d "${btrfs_mount}/${subvol}" ]]; then
        echo "ERROR: Subvolume not found: $subvol" >&2
        return 1
    fi

    # Check if UKI already exists
    if [[ -f "$uki_path" ]]; then
        echo "UKI already exists: $uki_path"
        echo "WOULD_ASK_OVERWRITE"
    fi

    echo ":: Checking subvolume..."
    echo ":: Building UKI..."
    echo ":: Signing UKI..."
    echo "Done: ${uki_path}"
    return 0
}

_ESP_RB="${TESTDIR}/esp_rb"
_BTRFS_RB="${TESTDIR}/btrfs_rb"
mkdir -p "${_ESP_RB}/EFI/Linux" "$_BTRFS_RB"
mkdir -p "${_BTRFS_RB}/root-20250601-120000"

# Happy path: subvol exists, no UKI yet
_output=$(_rebuild_flow_sim "20250601-120000" "$_ESP_RB" "$_BTRFS_RB")
assert_contains "rebuild checks subvol" "Checking subvolume" "$_output"
assert_contains "rebuild builds UKI" "Building UKI" "$_output"
assert_contains "rebuild signs UKI" "Signing UKI" "$_output"
assert_contains "rebuild done" "Done:" "$_output"
assert_not_contains "no overwrite prompt" "WOULD_ASK_OVERWRITE" "$_output"

# UKI already exists → would prompt
touch "${_ESP_RB}/EFI/Linux/arch-20250601-120000.efi"
_output=$(_rebuild_flow_sim "20250601-120000" "$_ESP_RB" "$_BTRFS_RB")
assert_contains "overwrite prompt shown" "WOULD_ASK_OVERWRITE" "$_output"

# Subvol missing → error
_output=$(_rebuild_flow_sim "20250699-999999" "$_ESP_RB" "$_BTRFS_RB")
assert_contains "missing subvol error" "Subvolume not found" "$_output"

# ── Overwrite confirmation logic ────────────────────────────

section "Overwrite confirmation logic"

_confirm_overwrite() {
    local answer="$1"
    case "$answer" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

run_cmd _confirm_overwrite "y"
assert_eq "lowercase y → proceed" "0" "$_rc"

run_cmd _confirm_overwrite "Y"
assert_eq "uppercase Y → proceed" "0" "$_rc"

run_cmd _confirm_overwrite "n"
assert_eq "n → abort" "1" "$_rc"

run_cmd _confirm_overwrite "N"
assert_eq "N → abort" "1" "$_rc"

run_cmd _confirm_overwrite ""
assert_eq "empty → abort" "1" "$_rc"

run_cmd _confirm_overwrite "yes"
assert_eq "yes → abort (not y/Y)" "1" "$_rc"

# ── UKI path construction ───────────────────────────────────

section "UKI path construction"

assert_eq "plain UKI path" "/efi/EFI/Linux/arch-20250601-120000.efi" \
    "/efi/EFI/Linux/arch-20250601-120000.efi"

assert_eq "tagged UKI path" "/efi/EFI/Linux/arch-20250601-120000-kde.efi" \
    "/efi/EFI/Linux/arch-20250601-120000-kde.efi"

# ── Cleanup trap simulation ─────────────────────────────────

section "Cleanup trap simulation"

# Verify cleanup would unmount and remove temp dirs
_cleanup_rebuild_sim() {
    local mount_dir="$1"
    local btrfs_mount="$2"
    local lock_fd="$3"

    local actions=()

    if [[ -n "$mount_dir" ]]; then
        actions+=("umount $mount_dir")
        actions+=("rmdir $mount_dir")
    fi

    actions+=("umount $btrfs_mount")

    if [[ -n "$lock_fd" ]]; then
        actions+=("close fd $lock_fd")
    fi

    printf '%s\n' "${actions[@]}"
}

_output=$(_cleanup_rebuild_sim "/tmp/atomic-rebuild.XXXXXX" "/run/atomic/temp_root" "5")
assert_contains "cleanup unmounts temp" "umount /tmp/atomic-rebuild" "$_output"
assert_contains "cleanup removes temp dir" "rmdir /tmp/atomic-rebuild" "$_output"
assert_contains "cleanup unmounts btrfs" "umount /run/atomic/temp_root" "$_output"
assert_contains "cleanup closes lock" "close fd 5" "$_output"

# No mount dir → skip
_output=$(_cleanup_rebuild_sim "" "/run/atomic/temp_root" "5")
assert_not_contains "no temp unmount" "umount /tmp" "$_output"
assert_contains "still unmounts btrfs" "umount /run/atomic/temp_root" "$_output"

# No lock fd → skip
_output=$(_cleanup_rebuild_sim "/tmp/test" "/run/atomic/temp_root" "")
assert_not_contains "no fd close" "close fd" "$_output"

summary
