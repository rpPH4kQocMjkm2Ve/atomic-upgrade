#!/usr/bin/env bash
# tests/test_config.sh — Config loading, parsing, security
# Run: bash tests/test_config.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── Default values after sourcing ────────────────────────────

section "Default values"

assert_eq "BTRFS_MOUNT default" "/run/atomic/temp_root" "$BTRFS_MOUNT"
assert_eq "NEW_ROOT default"    "/run/atomic/newroot"    "$NEW_ROOT"
assert_eq "ESP default"         "/efi"                   "$ESP"
assert_eq "KEEP_GENERATIONS default" "3"                 "$KEEP_GENERATIONS"
assert_eq "MAPPER_NAME default" "root_crypt"             "$MAPPER_NAME"
assert_eq "KERNEL_PKG default"  "linux"                  "$KERNEL_PKG"
assert_eq "LOCK_DIR default"    "/run/atomic"                      "$LOCK_DIR"
assert_eq "LOCK_FILE default"   "/run/atomic/atomic-upgrade.lock"  "$LOCK_FILE"
assert_eq "SBCTL_SIGN default"  "0"                      "$SBCTL_SIGN"
assert_eq "UPGRADE_GUARD default" "1"                    "$UPGRADE_GUARD"
assert_eq "HOME_COPY_FILES default" ""                   "$HOME_COPY_FILES"
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

# Test: ' #' inside value is treated as inline comment (documented limitation)
CONFIG_FILE="${TESTDIR}/space_hash_in_value.conf"
cat > "$CONFIG_FILE" <<'EOF'
KERNEL_PARAMS=rw console=ttyS0 #debug
EOF
KERNEL_PARAMS="default"
load_config
assert_eq "space-hash treated as comment (documented)" "rw console=ttyS0" "$KERNEL_PARAMS"
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


# ── HOME_COPY_FILES config ─────────────────────

section "HOME_COPY_FILES config"

# Test: HOME_COPY_FILES loaded from config
CONFIG_FILE="${TESTDIR}/home_copy.conf"
cat > "$CONFIG_FILE" <<'EOF'
HOME_COPY_FILES=.bashrc .ssh .gitconfig
EOF
HOME_COPY_FILES=""
load_config
assert_eq "HOME_COPY_FILES loaded" ".bashrc .ssh .gitconfig" "$HOME_COPY_FILES"

# Test: HOME_COPY_FILES with quotes
CONFIG_FILE="${TESTDIR}/home_copy_quoted.conf"
cat > "$CONFIG_FILE" <<'EOF'
HOME_COPY_FILES=".bashrc .bash_profile .ssh"
EOF
HOME_COPY_FILES=""
load_config
assert_eq "HOME_COPY_FILES quoted" ".bashrc .bash_profile .ssh" "$HOME_COPY_FILES"

# Test: HOME_COPY_FILES absent → default preserved
CONFIG_FILE="${TESTDIR}/home_copy_absent.conf"
cat > "$CONFIG_FILE" <<'EOF'
KEEP_GENERATIONS=3
EOF
HOME_COPY_FILES=""
load_config
assert_eq "HOME_COPY_FILES absent → stays empty" "" "$HOME_COPY_FILES"

# Restore
HOME_COPY_FILES=""

# ── COMMAND config ───────────────────────────────────

section "COMMAND config"

# Test: COMMAND loaded from config
CONFIG_FILE="${TESTDIR}/command.conf"
cat > "$CONFIG_FILE" <<'EOF'
COMMAND=/usr/bin/pacman -Syu
EOF
COMMAND=""
load_config
assert_eq "COMMAND loaded from config" "/usr/bin/pacman -Syu" "$COMMAND"
COMMAND=""

# Test: COMMAND with quotes
CONFIG_FILE="${TESTDIR}/command_quoted.conf"
cat > "$CONFIG_FILE" <<'EOF'
COMMAND="/usr/bin/pacman -S nvidia"
EOF
COMMAND=""
load_config
assert_eq "COMMAND with double quotes" "/usr/bin/pacman -S nvidia" "$COMMAND"
COMMAND=""

# Test: COMMAND absent → stays empty
CONFIG_FILE="${TESTDIR}/command_absent.conf"
cat > "$CONFIG_FILE" <<'EOF'
KEEP_GENERATIONS=3
EOF
COMMAND=""
load_config
assert_eq "COMMAND absent → stays empty" "" "$COMMAND"

#
# ── config key whitespace trimming ─────────────

section "Config key whitespace trimming"

CONFIG_FILE="${TESTDIR}/whitespace_key.conf"
printf '  KEEP_GENERATIONS=7\n' > "$CONFIG_FILE"
printf '\tESP=/boot/efi\n' >> "$CONFIG_FILE"
KEEP_GENERATIONS=3
ESP="/efi"
load_config
assert_eq "leading spaces in key trimmed" "7" "$KEEP_GENERATIONS"
assert_eq "leading tab in key trimmed" "/boot/efi" "$ESP"
KEEP_GENERATIONS=3
ESP="/efi"


summary
