#!/usr/bin/env bash
# tests/test_integration.sh
#
# Integration tests for atomic-upgrade system.
# Tests actual script behavior (atomic-guard, pacman-wrapper)
# with real config parsing, lock mechanics, and argument detection.
#
# Creates a test prefix with patched copies of scripts/libraries
# so tests run without installation and without root.
#
# Run: bash tests/test_integration.sh

set -uo pipefail

PASS=0
FAIL=0
TESTS=0

# ── Test helpers ─────────────────────────────────────────────

ok()   { PASS=$((PASS+1)); TESTS=$((TESTS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TESTS=$((TESTS+1)); echo "  ✗ $1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    [[ "$expected" == "$actual" ]] \
        && ok "$desc" || fail "$desc (expected='$expected', got='$actual')"
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    [[ "$haystack" == *"$needle"* ]] \
        && ok "$desc" || fail "$desc (needle='$needle' not in output)"
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    [[ "$haystack" != *"$needle"* ]] \
        && ok "$desc" || fail "$desc (needle='$needle' unexpectedly found)"
}

run_cmd() { _rc=0; _out=$("$@" 2>&1) || _rc=$?; }

section() { echo ""; echo "── $1 ──"; }

# ── Setup ─────────────────────────────────────────────────────

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"; kill 0 2>/dev/null' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${TESTDIR}/prefix"
MOCK_BIN="${TESTDIR}/mock_bin"
CONF_DIR="${TESTDIR}/conf"
mkdir -p "${PREFIX}/usr/lib/atomic" "${PREFIX}/usr/bin" \
         "${PREFIX}/usr/local/bin" "$MOCK_BIN" "$CONF_DIR"

# ── Copy and patch project files ──────────────────────────────
# Integration tests run against real scripts, but paths like
# /usr/lib/atomic and /usr/bin/pacman are hardcoded.
# We sed-patch them to point to our test prefix.

cp "${PROJECT_ROOT}/lib/atomic/"* "${PREFIX}/usr/lib/atomic/"

# Make CONFIG_FILE and LOCK_FILE overridable via environment
# (production code hardcodes defaults; tests need to redirect)
sed -i \
    -e 's|^CONFIG_FILE="/etc/atomic.conf"|CONFIG_FILE="${CONFIG_FILE:-/etc/atomic.conf}"|' \
    -e 's|^LOCK_FILE="/var/lock/atomic-upgrade.lock"|LOCK_FILE="${LOCK_FILE:-/var/lock/atomic-upgrade.lock}"|' \
    "${PREFIX}/usr/lib/atomic/common.sh"

# Patch atomic-guard: redirect LIBDIR
sed "s|/usr/lib/atomic|${PREFIX}/usr/lib/atomic|g" \
    "${PROJECT_ROOT}/bin/atomic-guard" > "${PREFIX}/usr/bin/atomic-guard"
chmod +x "${PREFIX}/usr/bin/atomic-guard"

# Mock pacman binary (replaces /usr/bin/pacman in wrapper)
MOCK_PACMAN="${TESTDIR}/mock_pacman"
cat > "$MOCK_PACMAN" <<'MOCK'
#!/bin/bash
echo "MOCK_PACMAN_CALLED"
echo "ARGS: $*"
exit 0
MOCK
chmod +x "$MOCK_PACMAN"

# Patch pacman-wrapper: redirect LIBDIR and /usr/bin/pacman
sed -e "s|/usr/lib/atomic|${PREFIX}/usr/lib/atomic|g" \
    -e "s|/usr/bin/pacman|${MOCK_PACMAN}|g" \
    "${PROJECT_ROOT}/extras/pacman-wrapper" > "${PREFIX}/usr/local/bin/pacman-wrapper"
chmod +x "${PREFIX}/usr/local/bin/pacman-wrapper"

# Broken copies — LIBDIR points nowhere, common.sh won't load
sed "s|${PREFIX}/usr/lib/atomic|${TESTDIR}/nonexistent_lib|g" \
    "${PREFIX}/usr/bin/atomic-guard" > "${PREFIX}/usr/bin/atomic-guard-broken"
chmod +x "${PREFIX}/usr/bin/atomic-guard-broken"

sed "s|${PREFIX}/usr/lib/atomic|${TESTDIR}/nonexistent_lib|g" \
    "${PREFIX}/usr/local/bin/pacman-wrapper" > "${PREFIX}/usr/local/bin/pacman-wrapper-broken"
chmod +x "${PREFIX}/usr/local/bin/pacman-wrapper-broken"

# ── Mock system commands ──────────────────────────────────────

cat > "${MOCK_BIN}/verify-lib" <<'MOCK'
#!/bin/bash
[[ -f "$1" ]] && echo "$1" && exit 0
echo "ERROR: $1 not found" >&2; exit 1
MOCK
chmod +x "${MOCK_BIN}/verify-lib"

REAL_STAT=$(command -v stat)
cat > "${MOCK_BIN}/stat" <<MOCK
#!/bin/bash
if [[ "\${1:-}" == "-c" && "\${2:-}" == "%u" ]]; then
    echo "0"
else
    exec "${REAL_STAT}" "\$@"
fi
MOCK
chmod +x "${MOCK_BIN}/stat"

for cmd in mountpoint mount btrfs df python3; do
    printf '#!/bin/bash\nexit 0\n' > "${MOCK_BIN}/${cmd}"
    chmod +x "${MOCK_BIN}/${cmd}"
done

cat > "${MOCK_BIN}/findmnt" <<'MOCK'
#!/bin/bash
echo "rw,subvol=/root-20250601-120000"
MOCK
chmod +x "${MOCK_BIN}/findmnt"

export PATH="${MOCK_BIN}:${PATH}"

# ── Config files ──────────────────────────────────────────────

cat > "${CONF_DIR}/guard_off.conf" <<'EOF'
UPGRADE_GUARD=0
EOF

cat > "${CONF_DIR}/guard_on.conf" <<'EOF'
UPGRADE_GUARD=1
EOF

cat > "${CONF_DIR}/guard_off_quoted.conf" <<'EOF'
UPGRADE_GUARD="0"
EOF

cat > "${CONF_DIR}/empty.conf" <<'EOF'
# No settings — all defaults
EOF

TEST_LOCK="${TESTDIR}/test.lock"
GUARD="${PREFIX}/usr/bin/atomic-guard"
GUARD_BROKEN="${PREFIX}/usr/bin/atomic-guard-broken"
WRAPPER="${PREFIX}/usr/local/bin/pacman-wrapper"
WRAPPER_BROKEN="${PREFIX}/usr/local/bin/pacman-wrapper-broken"


# ═══════════════════════════════════════════════════════════════
#  atomic-guard
# ═══════════════════════════════════════════════════════════════

section "guard: UPGRADE_GUARD=0 bypasses everything"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "guard disabled → exit 0" "0" "$_rc"

# Quoted value
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off_quoted.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "guard disabled (quoted) → exit 0" "0" "$_rc"

# Disabled guard ignores ATOMIC_UPGRADE context too
run_cmd env ATOMIC_UPGRADE=1 CONFIG_FILE="${CONF_DIR}/guard_off.conf" \
    LOCK_FILE="$TEST_LOCK" bash "$GUARD"
assert_eq "guard disabled + ATOMIC_UPGRADE → exit 0" "0" "$_rc"


section "guard: UPGRADE_GUARD=1 blocks direct calls"

# Not called from pacman → is_sysupgrade can't find pacman
# in process tree → blocks for safety
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "guard enabled → exit 1" "1" "$_rc"
assert_contains "block message mentions atomic-upgrade" "atomic-upgrade" "$_out"


section "guard: default config → guard active"

run_cmd env CONFIG_FILE="${CONF_DIR}/empty.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "empty config → default guard active → exit 1" "1" "$_rc"


section "guard: missing config → defaults → blocks"

run_cmd env CONFIG_FILE="${TESTDIR}/nonexistent.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "missing config → exit 1" "1" "$_rc"


section "guard: common.sh load failure → safe default (block)"

# verify-lib fails → common.sh not loaded → UPGRADE_GUARD unset
# → ${UPGRADE_GUARD:-1} == "1" → guard active
run_cmd env LOCK_FILE="$TEST_LOCK" bash "$GUARD_BROKEN"
assert_eq "broken lib → safe default → exit 1" "1" "$_rc"


section "guard: ATOMIC_UPGRADE + lock held → pass"

# Background process holds an exclusive flock
(
    exec 9>"$TEST_LOCK"
    flock -n 9
    sleep 10
) &
LOCK_PID=$!
sleep 0.2

run_cmd env ATOMIC_UPGRADE=1 CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    LOCK_FILE="$TEST_LOCK" bash "$GUARD"
assert_eq "ATOMIC_UPGRADE + lock held → exit 0" "0" "$_rc"

kill $LOCK_PID 2>/dev/null; wait $LOCK_PID 2>/dev/null


section "guard: ATOMIC_UPGRADE + lock file missing → fail"

rm -f "$TEST_LOCK"
run_cmd env ATOMIC_UPGRADE=1 CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    LOCK_FILE="$TEST_LOCK" bash "$GUARD"
assert_eq "ATOMIC_UPGRADE, no lock file → exit 1" "1" "$_rc"


section "guard: ATOMIC_UPGRADE + lock file exists but not held → fail"

touch "$TEST_LOCK"
run_cmd env ATOMIC_UPGRADE=1 CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    LOCK_FILE="$TEST_LOCK" bash "$GUARD"
assert_eq "ATOMIC_UPGRADE, lock not held → exit 1" "1" "$_rc"


# ═══════════════════════════════════════════════════════════════
#  pacman-wrapper
# ═══════════════════════════════════════════════════════════════

section "wrapper: UPGRADE_GUARD=0 → all calls pass through"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" bash "$WRAPPER" -Syu
assert_eq "-Syu with guard off → exit 0" "0" "$_rc"
assert_contains "-Syu reaches pacman" "MOCK_PACMAN_CALLED" "$_out"
assert_not_contains "no hint shown" "atomic-upgrade" "$_out"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" bash "$WRAPPER" -S vim
assert_eq "-S vim with guard off → exit 0" "0" "$_rc"
assert_contains "-S vim reaches pacman" "MOCK_PACMAN_CALLED" "$_out"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" bash "$WRAPPER" -Q
assert_eq "-Q with guard off → exit 0" "0" "$_rc"
assert_contains "-Q reaches pacman" "MOCK_PACMAN_CALLED" "$_out"


section "wrapper: ATOMIC_UPGRADE=1 → immediate bypass"

run_cmd env ATOMIC_UPGRADE=1 CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    bash "$WRAPPER" -Syu
assert_eq "ATOMIC_UPGRADE bypass → exit 0" "0" "$_rc"
assert_contains "reaches pacman" "MOCK_PACMAN_CALLED" "$_out"
assert_not_contains "no hint" "atomic-upgrade" "$_out"


section "wrapper: -Syu blocked (non-interactive)"

# stdin is not a terminal → wrapper aborts for safety
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" -Syu
assert_eq "-Syu non-interactive → exit 1" "1" "$_rc"
assert_contains "shows hint" "atomic-upgrade" "$_out"
assert_contains "non-interactive abort" "Non-interactive" "$_out"
assert_not_contains "pacman not called" "MOCK_PACMAN_CALLED" "$_out"


section "wrapper: -Su blocked (sysupgrade without refresh)"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" -Su
assert_eq "-Su → exit 1" "1" "$_rc"
assert_contains "-Su shows hint" "atomic-upgrade" "$_out"


section "wrapper: --sync --sysupgrade blocked (long form)"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    bash "$WRAPPER" --sync --sysupgrade
assert_eq "long form → exit 1" "1" "$_rc"
assert_contains "long form shows hint" "atomic-upgrade" "$_out"


section "wrapper: -Syyu blocked (double refresh)"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" -Syyu
assert_eq "-Syyu → exit 1" "1" "$_rc"
assert_contains "-Syyu shows hint" "atomic-upgrade" "$_out"


section "wrapper: non-sysupgrade operations pass through"

for args in "-S vim" "-S vim firefox" "-Ss kernel" "-Si linux" \
            "-Q" "-Qi bash" "-R vim" "-Rns vim" "-F ls" "-Fy"; do
    # shellcheck disable=SC2086
    run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" $args
    assert_eq "'pacman $args' → exit 0" "0" "$_rc"
    assert_contains "'pacman $args' reaches pacman" "MOCK_PACMAN_CALLED" "$_out"
done


section "wrapper: no arguments passes through"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER"
assert_eq "no args → exit 0" "0" "$_rc"
assert_contains "no args reaches pacman" "MOCK_PACMAN_CALLED" "$_out"


section "wrapper: -Sy warns about partial upgrade"

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" -Sy
assert_eq "-Sy → exit 0" "0" "$_rc"
assert_contains "-Sy partial upgrade warning" "partial" "$_out"
assert_contains "-Sy still reaches pacman" "MOCK_PACMAN_CALLED" "$_out"


section "wrapper: arguments after -- not parsed"

# -- stops option parsing; -Syu after it is not a flag
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" \
    bash "$WRAPPER" -S -- -Syu
assert_eq "args after -- not parsed → exit 0" "0" "$_rc"
assert_contains "reaches pacman" "MOCK_PACMAN_CALLED" "$_out"


section "wrapper: common.sh load failure → safe default (blocks -Syu)"

run_cmd bash "$WRAPPER_BROKEN" -Syu
assert_eq "broken lib + -Syu → exit 1" "1" "$_rc"

# Non-sysupgrade still passes through
run_cmd bash "$WRAPPER_BROKEN" -S vim
assert_eq "broken lib + -S → exit 0" "0" "$_rc"
assert_contains "reaches pacman" "MOCK_PACMAN_CALLED" "$_out"


# ═══════════════════════════════════════════════════════════════
#  Config propagation end-to-end
# ═══════════════════════════════════════════════════════════════

section "config: runtime toggle without restart"

# Simulate: guard was on, user disables it, immediate effect
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "step 1: guard on → blocks" "1" "$_rc"

# "User edits config"
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "step 2: guard off → passes" "0" "$_rc"

# "User re-enables"
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
assert_eq "step 3: guard on again → blocks" "1" "$_rc"


section "config: guard and wrapper agree on same config"

# Both should block with guard_on
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
guard_rc=$_rc

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_on.conf" bash "$WRAPPER" -Syu
wrapper_rc=$_rc

assert_eq "guard blocks" "1" "$guard_rc"
assert_eq "wrapper blocks" "1" "$wrapper_rc"

# Both should pass with guard_off
run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" LOCK_FILE="$TEST_LOCK" \
    bash "$GUARD"
guard_rc=$_rc

run_cmd env CONFIG_FILE="${CONF_DIR}/guard_off.conf" bash "$WRAPPER" -Syu
wrapper_rc=$_rc

assert_eq "guard passes" "0" "$guard_rc"
assert_eq "wrapper passes" "0" "$wrapper_rc"


# ═══════════════════════════════════════════════════════════════
#  RESULTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed (total: $TESTS)"
echo "════════════════════════════════════"

[[ $FAIL -ne 0 ]] && exit 1
exit 0
