# Tests

## Overview

| File | Language | Framework | What it tests |
|------|----------|-----------|---------------|
| `test_config.sh` | Bash | Custom assertions | Config loading, parsing, quoting, inline comments, ownership check, unknown key rejection, whitelist security, UPGRADE_GUARD, KERNEL_PARAMS, HOME_COPY_FILES, key whitespace trimming |
| `test_validate.sh` | Bash | Custom assertions | Function definitions, `validate_config` (numeric checks, path conflicts, ESP mount), `check_dependencies` (missing commands, LUKS→cryptsetup, SBCTL_SIGN→sbctl), `is_child_of_aur_helper` |
| `test_device.sh` | Bash | Custom assertions | `get_current_subvol`/`get_current_subvol_raw` with various findmnt outputs, `get_root_device` (python helper, caching, fallback), `ensure_btrfs_mounted`, `validate_subvolume` |
| `test_space.sh` | Bash | Custom assertions | `check_esp_space` (sufficient/low/df-failure), `check_btrfs_space` (native/df-fallback/both-fail, absolute minimum threshold, non-numeric btrfs output) |
| `test_chroot.sh` | Bash | Custom assertions | `chroot_snapshot` — unshare flags, env propagation, arg forwarding, exit code propagation, LOCK_DIR bind mount, resolv.conf symlink save/restore, mount failure early return, mount cleanup on mid-chain failure, efivarfs failure tolerance |
| `test_gc.sh` | Bash | Custom assertions | `list_generations` (nullglob, empty dir, no leak), `delete_generation` (current protection, dry run, invalid gen_id format rejection), `garbage_collect` (keep count, orphan subvol/UKI, dry run, edge cases, ESP unmounted), `warn_orphan_homes`, orphan home in GC, glob false positive regression |
| `test_uki.sh` | Bash | Custom assertions | `sign_uki`/`verify_uki`, `build_uki` — missing kernel/initramfs/os-release, rootdev.py failure, ukify failure, kernel version via pkgbase/fallback, `--uname` omission, cmdline composition, PRETTY_NAME rewrite, custom KERNEL_PKG, tagged gen_id |
| `test_home.sh` | Bash | Custom assertions | `populate_home_skeleton` — normal file/directory copy, path traversal rejection, absolute path blocking, empty copy_files handling, glob character protection, noglob state restoration |
| `test_harness.sh` | Bash | — | Shared test infrastructure: assertions, mocks, TESTDIR setup, common.sh sourcing (not run directly) |
| `test_integration.sh` | Bash | Custom assertions | `atomic-guard` and `pacman-wrapper` end-to-end — config propagation, lock verification, sysupgrade detection, AUR helper bypass |
| `test_fstab.py` | Python | pytest | `fstab.py` — fstab entry parsing, `subvol=` replacement (root and /home), atomic write with permission preservation, backup/rollback, subvolid= diagnostics |
| `test_rootdev.py` | Python | pytest | `rootdev.py` — root device detection (plain btrfs, LUKS, LVM, LUKS+LVM), bracket stripping in findmnt source, cmdline generation, CLI dispatch |

## Running

```bash
# All tests
make test

# Individual suites
bash tests/test_config.sh
bash tests/test_validate.sh
bash tests/test_device.sh
bash tests/test_space.sh
bash tests/test_chroot.sh
bash tests/test_gc.sh
bash tests/test_uki.sh
bash tests/test_home.sh
bash tests/test_integration.sh
python -m pytest tests/test_fstab.py -v
python -m pytest tests/test_rootdev.py -v
```

## How they work

### Bash unit tests (`test_config.sh` .. `test_home.sh`)

All eight unit test files source `test_harness.sh`, which provides:

- **Assertion functions**: `ok`/`fail`/`assert_eq`/`assert_match`/`assert_contains`/`assert_not_contains`/`assert_rc`/`run_cmd`
- **Temporary directory**: `$TESTDIR` cleaned up via `trap EXIT`
- **Mock framework**: `make_mock` (writes scripts to `$MOCK_BIN`) and `make_mock_in` (arbitrary directory)
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

### Python tests (`test_fstab.py`, `test_rootdev.py`)

Standard pytest suites. No system access — all filesystem operations use `tmp_path`, all subprocess calls are mocked.

**`test_fstab.py`** tests the `FstabEntry` dataclass (parsing, `replace_subvol`, `set_subvol`, formatting) and the `update_fstab`/`update_fstab_home` functions (atomic write, backup cleanup, permission preservation, post-write verification, error diagnostics for `subvolid=` without `subvol=`).

**`test_rootdev.py`** tests `run()` error handling (timeout, not found), `detect_root()` with mocked `findmnt`/`dmsetup`/`cryptsetup`/`blkid` responses for each device type, `_detect_dm_type()` directly, `build_cmdline()` output format and ordering, and `main()` CLI dispatch. Includes end-to-end pipeline tests that chain detect → cmdline for LUKS and plain setups.

## Test environment

- Bash tests create a temporary directory (`mktemp -d`) cleaned up via `trap EXIT`
- No root privileges required
- No real disks, partitions, or btrfs volumes are touched
- Python tests use pytest's `tmp_path` fixture
- CI runs relevant suites on push/PR when source or test files change (path-filtered)
