# Tests

## Overview

| File | Language | Framework | What it tests |
|------|----------|-----------|---------------|
| `test_config.py` | Python | pytest | `config.py` — parse_config (quoting, inline comments, unknown keys, ownership), key lookup, validate, shell output (format + escaping), array output (simple + quoted spaces) |
| `test_validate.sh` | Bash | Custom assertions | Function definitions, `validate_config` (numeric checks, path conflicts, ESP mount), `check_dependencies` (missing commands, LUKS→cryptsetup, SBCTL_SIGN→sbctl), `is_child_of_aur_helper` |
| `test_device.sh` | Bash | Custom assertions | `get_current_subvol`/`get_current_subvol_raw` with various findmnt outputs, `get_root_device` (python helper, caching, fallback error case), `ensure_btrfs_mounted`, `validate_subvolume` |
| `test_space.sh` | Bash | Custom assertions | `check_esp_space` (sufficient/low/df-failure), `check_btrfs_space` (native/df-fallback/both-fail, absolute minimum threshold, non-numeric btrfs output) |
| `test_chroot.sh` | Bash | Custom assertions | `chroot_snapshot` — unshare flags, env propagation, arg forwarding, exit code propagation, LOCK_DIR bind mount, resolv.conf symlink save/restore, mount failure early return, mount cleanup on mid-chain failure, efivarfs failure tolerance |
| `test_gc.sh` | Bash | Custom assertions | `list_generations` (nullglob, empty dir, no leak), `delete_generation` (current protection, dry run, invalid gen_id format rejection), `garbage_collect` (keep count, orphan subvol/UKI, dry run, edge cases, ESP unmounted), `warn_orphan_homes`, orphan home in GC, glob false positive regression |
| `test_uki.sh` | Bash | Custom assertions | `sign_uki`/`verify_uki`, `build_uki` — missing kernel/initramfs/os-release, rootdev.py failure, ukify failure, kernel version via pkgbase/fallback, `--uname` omission, cmdline composition, PRETTY_NAME rewrite, custom KERNEL_PKG, tagged gen_id |
| `test_home.sh` | Bash | Custom assertions | `populate_home_skeleton` — normal file/directory copy, path traversal rejection, absolute path blocking, empty copy_files handling, glob character protection, noglob state restoration |
| `test_upgrade.sh` | Bash | Custom assertions | `atomic-upgrade` argument parsing, `--tag`/`--separate-home`/`--copy-files` validation, dependency constraints, default chroot command, dry-run output structure, GEN_ID format validation, subvolume naming, cleanup trap logic |
| `test_rebuild_uki.sh` | Bash | Custom assertions | `atomic-rebuild-uki` help output, GEN_ID validation, `list_orphans` code verification (behavioral test in integration), rebuild flow, overwrite confirmation logic, UKI path construction, cleanup trap simulation |
| `test_atomic_gc.sh` | Bash | Custom assertions | `atomic-gc` CLI — help/version, unknown option rejection, `list` command output (+ active/protected markers), `rm` argument/GEN_ID validation, `rm` dry-run, `rm` refuses protected generation, `gc` count validation, `gc` dry-run, `activate`/`deactivate`/`protect`/`unprotect` commands, cleanup trap verification |
| `test_upgrade_flow.sh` | Bash | Custom assertions | End-to-end upgrade flow — snapshot creation, chroot execution, UKI build, fstab update, GC integration, dry-run output verification |
| `test_rebuild_uki_flow.sh` | Bash | Custom assertions | End-to-end `atomic-rebuild-uki` flow — UKI rebuild for existing generations, overwrite logic, list output, cleanup trap verification |
| `test_harness.sh` | Bash | — | Shared test infrastructure: assertions, mocks with call tracking, TESTDIR setup, `reset_atomic_globals`, common.sh sourcing (not run directly) |
| `test_integration.sh` | Bash | Custom assertions | `atomic-guard` and `pacman-wrapper` end-to-end — config propagation, lock verification, sysupgrade detection (`-Syu`, `--sync --sysupgrade`, `-Syyu`; `-Su` not explicitly tested), AUR helper bypass, stdin handling edge cases |
| `test_fstab.py` | Python | pytest | `fstab.py` — fstab entry parsing, `subvol=` replacement via `replace_subvol`/`set_subvol` (root and /home), format preservation, atomic write with permission preservation, backup/rollback, subvolid= diagnostics, chmod/fync failure cleanup |
| `test_rootdev.py` | Python | pytest | `rootdev.py` — root device detection (plain btrfs, LUKS, LVM, LUKS+LVM), bracket stripping in findmnt source, `_detect_dm_type()` directly, cmdline generation (format/ordering), CLI dispatch, timeout/missing utility handling, end-to-end pipeline tests |

## Running

```bash
# All tests
make test

# Individual suites
python -m pytest tests/test_config.py -v
bash tests/test_validate.sh
bash tests/test_device.sh
bash tests/test_space.sh
bash tests/test_chroot.sh
bash tests/test_gc.sh
bash tests/test_uki.sh
bash tests/test_home.sh
bash tests/test_upgrade.sh
bash tests/test_upgrade_flow.sh
bash tests/test_rebuild_uki.sh
bash tests/test_rebuild_uki_flow.sh
bash tests/test_atomic_gc.sh
bash tests/test_integration.sh
python -m pytest tests/test_fstab.py -v
python -m pytest tests/test_rootdev.py -v
```

## How they work

### Bash unit tests (`test_validate.sh` .. `test_rebuild_uki.sh`)

All unit test files source `test_harness.sh`, which provides:

- **Assertion functions**: `ok`/`fail`/`assert_eq`/`assert_match`/`assert_contains`/`assert_not_contains`/`assert_file_exists`/`assert_file_not_exists`/`assert_file_contains`/`assert_rc`/`run_cmd`
- **Mock call tracking**: `mock_call_count`, `mock_last_args`, `mock_clear_log` — automatically log all mock invocations for verification
- **Temporary directory**: `$TESTDIR` cleaned up via `trap EXIT`
- **Global state isolation**: `reset_atomic_globals()` resets all atomic variables between test sections to prevent state leakage
- **Mock framework**: `make_mock` (writes scripts to `$MOCK_BIN` with automatic call logging) and `make_mock_in` (arbitrary directory, no logging)
- **Default mocks**: `stat`, `findmnt`, `mountpoint`, `python3`, `mount`, `btrfs`, `flock`, `df` — all prepended to `$PATH`
- **`common.sh` sourcing**: loaded with `_ATOMIC_NO_INIT=1` to skip auto-init

Each test file runs as an independent bash process with its own `$TESTDIR`, so there is no state leakage between files. Tests exercise `common.sh` functions in-process, swapping mocks between tests to simulate different system states.

### Integration tests (`test_integration.sh`)

Copies and patches project scripts into a temporary prefix (rewriting paths with `sed`), then runs `atomic-guard` and `pacman-wrapper` as separate processes. Tests verify:

- `UPGRADE_GUARD=0/1` config flag controls both guard and wrapper
- Lock file mechanics: held lock passes, missing/unheld lock fails
- Sysupgrade detection: `-Syu`, `-Su`, `--sync --sysupgrade`, `-Syyu` all blocked
- Non-sysupgrade operations (`-S`, `-Q`, `-R`, `-Ss`, etc.) always pass through
- Graceful degradation when `common.sh` fails to load (broken `LIBDIR`)
- Config changes take effect immediately (no restart)
- Non-interactive stdin handling: pipes and redirects trigger safe abort

### Python tests (`test_fstab.py`, `test_rootdev.py`)

Standard pytest suites. No system access — all filesystem operations use `tmp_path`, all subprocess calls are mocked.

**`test_fstab.py`** tests the `FstabEntry` dataclass (parsing, formatting, whitespace preservation) and the `update_fstab`/`update_fstab_home` functions (atomic write, `replace_subvol`/`set_subvol`, backup cleanup, permission preservation, post-write verification, error diagnostics for `subvolid=` without `subvol=`, simulated `chmod`/`fsync` failure with temp file cleanup).

**`test_rootdev.py`** tests `run()` error handling (timeout, not found), `detect_root()` with mocked `findmnt`/`dmsetup`/`cryptsetup`/`blkid` responses for each device type, `_detect_dm_type()` directly, `build_cmdline()` output format and ordering, and `main()` CLI dispatch. Includes end-to-end pipeline tests that chain detect → cmdline for LUKS and plain setups, plus tests for missing utilities and incomplete `cryptsetup` output.

## Test environment

- Bash tests create a temporary directory (`mktemp -d`) cleaned up via `trap EXIT`
- No root privileges required
- No real disks, partitions, or btrfs volumes are touched
- Python tests use pytest's `tmp_path` fixture
- CI runs relevant suites on push/PR when source or test files change (path-filtered)
