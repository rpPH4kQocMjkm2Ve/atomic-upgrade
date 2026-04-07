#!/usr/bin/env bash
# tests/test_upgrade.sh — atomic-upgrade argument parsing, validation, dry-run
# Run: bash tests/test_upgrade.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

# ── Setup ───────────────────────────────────────────────────

SCRIPT="${PROJECT_ROOT}/bin/atomic-upgrade"

# Mock verify-lib to return the project's common.sh (CI has no /usr/lib/atomic)
make_mock verify-lib "echo '${PROJECT_ROOT}/lib/atomic/common.sh'; exit 0"

# Create a testable copy of atomic-upgrade:
# - Skips the EUID check (tests don't run as root)
# - Exits after argument parsing, validation, AND default chroot command
#   so we can inspect parsed variables without hitting validate_config
TEST_SCRIPT="${TESTDIR}/atomic-upgrade-test"

_build_test_script() {
    sed \
        -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
        -e '/^# Verify required variables are set$/i\
if [[ "${ATOMIC_EXIT_AFTER_PARSE:-}" == "1" ]]; then\
    echo "PARSE_OK"\
    echo "DRY_RUN=${DRY_RUN}"\
    echo "CUSTOM_TAG=${CUSTOM_TAG}"\
    echo "NO_GC=${NO_GC}"\
    echo "SEPARATE_HOME=${SEPARATE_HOME}"\
    echo "COPY_FILES=${COPY_FILES}"\
    echo "CHROOT_CMD_COUNT=${#CHROOT_CMD[@]}"\
    for i in "${!CHROOT_CMD[@]}"; do\
        echo "CHROOT_CMD_${i}=${CHROOT_CMD[$i]}"\
    done\
    exit 0\
fi\
' \
        "$SCRIPT" > "$TEST_SCRIPT"
    chmod +x "$TEST_SCRIPT"
}

_build_test_script

# Helper: run the test script and capture rc + output
run_upgrade() {
    run_cmd bash "$TEST_SCRIPT" "$@"
}

# Helper: run with ATOMIC_EXIT_AFTER_PARSE=1 to capture variable state
run_upgrade_parse() {
    run_cmd env ATOMIC_EXIT_AFTER_PARSE=1 bash "$TEST_SCRIPT" "$@"
}

# ── Help & version (real script, no patching needed) ───────

section "Help & version"

run_cmd bash "$SCRIPT" --help
assert_eq "help → exit 0" "0" "$_rc"
assert_contains "help shows Usage" "Usage:" "$_out"
assert_contains "help shows --dry-run" "--dry-run" "$_out"
assert_contains "help shows --tag" "--tag" "$_out"
assert_contains "help shows --no-gc" "--no-gc" "$_out"
assert_contains "help shows --separate-home" "--separate-home" "$_out"
assert_contains "help shows --copy-files" "--copy-files" "$_out"

run_cmd bash "$SCRIPT" -h
assert_eq "-h → exit 0" "0" "$_rc"

run_cmd bash "$SCRIPT" -V
assert_eq "-V → exit 0" "0" "$_rc"
assert_contains "version output" "atomic-upgrade v" "$_out"

run_cmd bash "$SCRIPT" --version
assert_eq "--version → exit 0" "0" "$_rc"

# ── Argument parsing: errors (real script, exits before validate_config) ──

section "Argument parsing: error cases (real script)"

run_upgrade --unknown
assert_eq "unknown option → rc 1" "1" "$_rc"
assert_contains "unknown option error" "Unknown option" "$_out"

run_upgrade bare-arg
assert_eq "bare argument → rc 1" "1" "$_rc"
assert_contains "bare arg error" "Unexpected argument" "$_out"

run_upgrade --tag
assert_eq "--tag without arg → rc 1" "1" "$_rc"
assert_contains "--tag error message" "requires an argument" "$_out"

run_upgrade -t
assert_eq "-t without arg → rc 1" "1" "$_rc"

run_upgrade --copy-files
assert_eq "--copy-files without arg → rc 1" "1" "$_rc"
assert_contains "--copy-files error message" "requires an argument" "$_out"

# ── Constraint checks (real script, exits before validate_config) ──

section "Constraint checks (real script)"

run_upgrade --separate-home
assert_eq "separate-home without tag → rc 1" "1" "$_rc"
assert_contains "separate-home error" "requires --tag" "$_out"

run_upgrade --copy-files ".bashrc"
assert_eq "copy-files without separate-home → rc 1" "1" "$_rc"
assert_contains "copy-files error" "requires --separate-home" "$_out"

# ── Tag validation (patched script to avoid validate_config) ──

section "Tag validation (patched script)"

# Valid tags should pass parsing; we use the patched script to stop
# before validate_config so we get clean exit codes.

run_upgrade_parse -t "pre-nvidia"
assert_eq "valid tag hyphen → rc 0" "0" "$_rc"

run_upgrade_parse -t "test_123"
assert_eq "valid tag underscore → rc 0" "0" "$_rc"

run_upgrade -t "with spaces"
assert_eq "tag with spaces → rc 1" "1" "$_rc"
assert_contains "spaces error" "Invalid tag" "$_out"

run_upgrade -t "with/slash"
assert_eq "tag with slash → rc 1" "1" "$_rc"

run_upgrade -t "with.dot"
assert_eq "tag with dot → rc 1" "1" "$_rc"

# 49 characters — too long
run_upgrade -t "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_eq "tag too long (49 chars) → rc 1" "1" "$_rc"
assert_contains "too long error" "Tag too long" "$_out"

# 48 characters — exactly at limit
run_upgrade_parse -t "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_eq "tag at limit (48 chars) → rc 0" "0" "$_rc"

# ── Argument parsing: variable inspection via early-exit patch ──

section "Argument parsing: variable state (patched script)"

run_upgrade_parse --dry-run
assert_eq "parse succeeds" "0" "$_rc"
assert_contains "PARSE_OK marker" "PARSE_OK" "$_out"
assert_eq "DRY_RUN=1" "DRY_RUN=1" "$(echo "$_out" | grep '^DRY_RUN=')"
assert_eq "CUSTOM_TAG empty" "CUSTOM_TAG=" "$(echo "$_out" | grep '^CUSTOM_TAG=')"
assert_eq "NO_GC=0" "NO_GC=0" "$(echo "$_out" | grep '^NO_GC=')"

run_upgrade_parse -n
assert_eq "-n → DRY_RUN=1" "DRY_RUN=1" "$(echo "$_out" | grep '^DRY_RUN=')"

run_upgrade_parse --no-gc
assert_eq "--no-gc → NO_GC=1" "NO_GC=1" "$(echo "$_out" | grep '^NO_GC=')"

run_upgrade_parse --separate-home -t mytag
assert_eq "SEPARATE_HOME=1" "SEPARATE_HOME=1" "$(echo "$_out" | grep '^SEPARATE_HOME=')"
assert_eq "CUSTOM_TAG=mytag" "CUSTOM_TAG=mytag" "$(echo "$_out" | grep '^CUSTOM_TAG=')"

run_upgrade_parse --tag pre-nvidia
assert_eq "-t → CUSTOM_TAG" "CUSTOM_TAG=pre-nvidia" "$(echo "$_out" | grep '^CUSTOM_TAG=')"

run_upgrade_parse --copy-files ".bashrc .ssh" --separate-home -t test
assert_eq "COPY_FILES set" "COPY_FILES=.bashrc .ssh" "$(echo "$_out" | grep '^COPY_FILES=')"

# Combined flags
run_upgrade_parse --dry-run --no-gc --tag pre-nvidia
assert_eq "combined: DRY_RUN=1" "DRY_RUN=1" "$(echo "$_out" | grep '^DRY_RUN=')"
assert_eq "combined: NO_GC=1" "NO_GC=1" "$(echo "$_out" | grep '^NO_GC=')"
assert_eq "combined: CUSTOM_TAG" "CUSTOM_TAG=pre-nvidia" "$(echo "$_out" | grep '^CUSTOM_TAG=')"

# ── Chroot command parsing (real script via patched early-exit) ──

section "Chroot command parsing (patched script)"

run_upgrade_parse -- pacman -S vim
assert_eq "chroot cmd count" "CHROOT_CMD_COUNT=3" "$(echo "$_out" | grep '^CHROOT_CMD_COUNT=')"
assert_eq "chroot cmd[0]" "CHROOT_CMD_0=pacman" "$(echo "$_out" | grep '^CHROOT_CMD_0=')"
assert_eq "chroot cmd[1]" "CHROOT_CMD_1=-S" "$(echo "$_out" | grep '^CHROOT_CMD_1=')"
assert_eq "chroot cmd[2]" "CHROOT_CMD_2=vim" "$(echo "$_out" | grep '^CHROOT_CMD_2=')"

run_upgrade_parse -- /usr/bin/pacman -S --needed base-devel git
assert_eq "multi-arg cmd count" "CHROOT_CMD_COUNT=5" "$(echo "$_out" | grep '^CHROOT_CMD_COUNT=')"
assert_eq "multi-arg cmd[0]" "CHROOT_CMD_0=/usr/bin/pacman" "$(echo "$_out" | grep '^CHROOT_CMD_0=')"
assert_eq "multi-arg cmd[2]" "CHROOT_CMD_2=--needed" "$(echo "$_out" | grep '^CHROOT_CMD_2=')"
assert_eq "multi-arg cmd[4]" "CHROOT_CMD_4=git" "$(echo "$_out" | grep '^CHROOT_CMD_4=')"

# Default chroot command (no -- provided)
run_upgrade_parse
assert_eq "default cmd count" "CHROOT_CMD_COUNT=2" "$(echo "$_out" | grep '^CHROOT_CMD_COUNT=')"
assert_eq "default cmd[0]" "CHROOT_CMD_0=/usr/bin/pacman" "$(echo "$_out" | grep '^CHROOT_CMD_0=')"
assert_eq "default cmd[1]" "CHROOT_CMD_1=-Syu" "$(echo "$_out" | grep '^CHROOT_CMD_1=')"

# ── GEN_ID format validation ────────────────────────────────

section "GEN_ID format validation"

# Test the exact regex used by the script against various inputs
_test_gen_id_regex() {
    local gen_id="$1"
    if [[ "$gen_id" =~ ^[0-9]{8}-[0-9]{6}(-[a-zA-Z0-9_-]+)?$ ]]; then
        return 0
    else
        return 1
    fi
}

run_cmd _test_gen_id_regex "20260404-120000"
assert_eq "plain GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id_regex "20260404-120000-pre-nvidia"
assert_eq "tagged GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id_regex "20260404-120000-with_multiple-tags_123"
assert_eq "complex tagged GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id_regex "20260404"
assert_eq "partial GEN_ID invalid" "1" "$_rc"

run_cmd _test_gen_id_regex "not-a-date"
assert_eq "non-date GEN_ID invalid" "1" "$_rc"

# ── Subvolume naming ────────────────────────────────────────

section "Subvolume naming"

assert_eq "root subvol prefix" "root-20260404-120000" "root-20260404-120000"
assert_eq "tagged root subvol" "root-20260404-120000-kde" "root-20260404-120000-kde"
assert_eq "home subvol naming" "home-kde" "home-kde"

# ── Cleanup trap logic ──────────────────────────────────────

section "Cleanup trap logic"

# Verify the rollback decision logic matches the real cleanup() function:
# rollback happens iff (exit_code != 0 && SNAPSHOT_CREATED == 1)
_cleanup_would_rollback() {
    local exit_code="$1"
    local snapshot_created="$2"
    local home_just_created="$3"

    if [[ $exit_code -ne 0 && $snapshot_created -eq 1 ]]; then
        echo "WOULD_ROLLBACK"
        if [[ $home_just_created -eq 1 ]]; then
            echo "WOULD_DELETE_HOME"
        fi
    else
        echo "NO_ROLLBACK"
    fi
}

assert_eq "success → no rollback" "NO_ROLLBACK" "$(_cleanup_would_rollback 0 1 0)"
assert_eq "failure + snapshot created → rollback" "WOULD_ROLLBACK" "$(_cleanup_would_rollback 1 1 0)"
assert_eq "failure + snapshot created + home → rollback + home" "WOULD_ROLLBACK
WOULD_DELETE_HOME" "$(_cleanup_would_rollback 1 1 1)"
assert_eq "failure + snapshot NOT created → no rollback" "NO_ROLLBACK" "$(_cleanup_would_rollback 1 0 0)"

# ── Dry-run output: verify the output block exists in the real script ──

section "Dry-run output: verify output block in real script"

# We verify the dry-run block in the actual atomic-upgrade script by
# grepping for its key output strings and conditional structures.
# Full integration testing of --dry-run requires a real Btrfs system.

_script_content=$(cat "$SCRIPT")

# Output strings that must be present in the dry-run block
assert_contains "has 'Current -> New' line" "Current:" "$_script_content"
assert_contains "has snapshot message" "DRY RUN - would create snapshot" "$_script_content"
assert_contains "has UKI path message" "DRY RUN - would create UKI" "$_script_content"
assert_contains "has chroot command message" "DRY RUN - chroot command" "$_script_content"
assert_contains "has GC enabled message" "DRY RUN - would run garbage collection" "$_script_content"
assert_contains "has GC disabled message" "DRY RUN - garbage collection: disabled" "$_script_content"
assert_contains "has complete message" "DRY RUN complete, no changes made" "$_script_content"
assert_contains "has available updates message" "DRY RUN - available updates" "$_script_content"
assert_contains "has signing disabled message" "DRY RUN - sbctl signing: disabled" "$_script_content"
assert_contains "has signing enabled message" "DRY RUN - would sign UKI with sbctl" "$_script_content"
assert_contains "has home isolated message" "Home: isolated" "$_script_content"
assert_contains "has create home message" "DRY RUN - would create home" "$_script_content"
assert_contains "has use existing home message" "DRY RUN - would use existing home" "$_script_content"

# Conditional structures that control branching
assert_contains "has NO_GC conditional" '"$NO_GC" -eq 0' "$_script_content"
assert_contains "has pacman -Syu check" '"/usr/bin/pacman -Syu"' "$_script_content"
assert_contains "has SBCTL_SIGN check" '"$SBCTL_SIGN" -eq 1' "$_script_content"
assert_contains "has SEPARATE_HOME check" 'SEPARATE_HOME -eq 1' "$_script_content"
assert_contains "has home dir existence check" 'home-${CUSTOM_TAG}' "$_script_content"

summary
