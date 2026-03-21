#!/usr/bin/env bash
# tests/test_home.sh — populate_home_skeleton
# Run: bash tests/test_home.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── populate_home_skeleton ─────────────────────

section "populate_home_skeleton"

# Create a fake home directory with a test user.
_PHS_HOME="${TESTDIR}/phs_home"
_PHS_TARGET="${TESTDIR}/phs_target"
_PHS_USER="testuser_phs"
mkdir -p "${_PHS_HOME}/${_PHS_USER}"
mkdir -p "$_PHS_TARGET"

# Create files for copy tests
echo "user_data" > "${_PHS_HOME}/${_PHS_USER}/.bashrc"
mkdir -p "${_PHS_HOME}/${_PHS_USER}/.ssh"
echo "key" > "${_PHS_HOME}/${_PHS_USER}/.ssh/id_rsa"

# Create file outside user dir for traversal test
echo "secret" > "${_PHS_HOME}/shadow_file"

# Mock id to return uid 1000 for our fake user
make_mock id '
if [[ "$1" == "-u" && "$2" == "testuser_phs" ]]; then
    echo "1000"
else
    exit 1
fi
'

# Wrapper: calls populate_home_skeleton with /home overridden.
# We create a temporary script that re-sources common.sh, redefines
# the function body with /home replaced, and calls it.
_phs_test() {
    local target="$1"; shift
    local copy_files="$1"; shift
    # Re-source common.sh to get a clean function, then patch it
    local func_body
    func_body=$(declare -f populate_home_skeleton)
    # Replace bare /home with our test path — only whole /home/ and /home"
    func_body="${func_body//for user_dir in \/home\//for user_dir in ${_PHS_HOME}/}"
    func_body="${func_body//\[[ -d \"\/home\" ]]/[[ -d \"${_PHS_HOME}\" ]]}"
    eval "$func_body"
    populate_home_skeleton "$target" "$copy_files"
}

# Test: normal file copy works
rm -rf "${_PHS_TARGET:?}"/*
run_cmd _phs_test "$_PHS_TARGET" ".bashrc"
assert_eq "normal copy succeeds" "0" "$_rc"
[[ -f "${_PHS_TARGET}/${_PHS_USER}/.bashrc" ]] \
    && ok "normal file copied" || fail "normal file not copied"

# Test: directory copy works
rm -rf "${_PHS_TARGET:?}"/*
run_cmd _phs_test "$_PHS_TARGET" ".ssh"
assert_eq "dir copy succeeds" "0" "$_rc"
[[ -f "${_PHS_TARGET}/${_PHS_USER}/.ssh/id_rsa" ]] \
    && ok "nested file copied" || fail "nested file not copied"

# Test: path traversal is blocked — file must NOT appear
rm -rf "${_PHS_TARGET:?}"/*
run_cmd _phs_test "$_PHS_TARGET" "../shadow_file"
assert_eq "traversal does not crash" "0" "$_rc"
[[ ! -f "${_PHS_TARGET}/${_PHS_USER}/../shadow_file" ]] \
    && ok "traversal file not copied (relative)" || fail "traversal file was copied"
[[ ! -f "${_PHS_TARGET}/shadow_file" ]] \
    && ok "traversal file not copied (resolved)" || fail "traversal file appeared at target root"

# Test: absolute path is blocked
rm -rf "${_PHS_TARGET:?}"/*
run_cmd _phs_test "$_PHS_TARGET" "/etc/passwd"
assert_eq "absolute path does not crash" "0" "$_rc"
[[ ! -f "${_PHS_TARGET}/${_PHS_USER}/etc/passwd" ]] \
    && ok "absolute path not copied" || fail "absolute path was copied"
[[ ! -f "${_PHS_TARGET}/etc/passwd" ]] \
    && ok "absolute path not at target root" || fail "absolute path appeared at target root"

# Test: empty copy_files produces skeleton with user directory
rm -rf "${_PHS_TARGET:?}"/*
run_cmd _phs_test "$_PHS_TARGET" ""
assert_eq "empty copy_files does not crash" "0" "$_rc"
[[ -d "${_PHS_TARGET}/${_PHS_USER}" ]] \
    && ok "user dir created with empty copy_files" || fail "user dir not created"

# Test: glob characters in copy_files treated literally (not expanded)
rm -rf "${_PHS_TARGET:?}"/*
# Verify noglob state is restored after the function call
_phs_noglob_before=$(set +o | grep noglob)
run_cmd _phs_test "$_PHS_TARGET" "*.conf [test]"
_phs_noglob_after=$(set +o | grep noglob)
assert_eq "noglob state restored after call" "$_phs_noglob_before" "$_phs_noglob_after"
assert_eq "glob copy_files does not crash" "0" "$_rc"

# Restore id mock
make_mock id 'exit 1'


summary
