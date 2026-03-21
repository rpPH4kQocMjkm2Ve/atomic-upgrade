# Tests

## Overview

| File | Language | Framework | What it tests |
|------|----------|-----------|---------------|
| `test_common.sh` | Bash | Custom assertions | `common.sh` — config loading, validation, locking, subvol/device detection, space checks, GC, home skeleton, orphan warnings |
| `test_integration.sh` | Bash | Custom assertions | `atomic-guard` and `pacman-wrapper` end-to-end — config propagation, lock verification, sysupgrade detection, AUR helper bypass |
| `test_fstab.py` | Python | pytest | `fstab.py` — fstab entry parsing, `subvol=` replacement (root and /home), atomic write with permission preservation, backup/rollback, subvolid= diagnostics |
| `test_rootdev.py` | Python | pytest | `rootdev.py` — root device detection (plain btrfs, LUKS, LVM, LUKS+LVM), bracket stripping in findmnt source, cmdline generation, CLI dispatch |

## Running

```bash
# All tests
make test

# Individual suites
bash tests/test_common.sh
bash tests/test_integration.sh
python -m pytest tests/test_fstab.py -v
python -m pytest tests/test_rootdev.py -v
```

## How they work

### Bash tests (`test_common.sh`, `test_integration.sh`)

Both suites use a custom lightweight test harness (`ok`/`fail`/`assert_eq`/`assert_contains`/`run_cmd`). No external test framework is required.

**`test_common.sh`** sources `common.sh` directly into the test process with all external commands (`btrfs`, `findmnt`, `mount`, `python3`, etc.) replaced by mocks in a temporary `$PATH`. Tests exercise functions in-process, swapping mocks between tests to simulate different system states. Covers:

- Config parser: whitelist enforcement, quoting, inline comments, ownership check, unknown key rejection
- Subvolume detection: `get_current_subvol` with various `findmnt` outputs
- Root device detection: python helper calls, caching, fallback to `MAPPER_NAME`
- Generation listing and deletion: sort order, current-generation protection, dry run
- Garbage collection: keep count, orphan subvolume/UKI detection, orphan home warnings, ESP-unmounted edge case
- Space checks: btrfs native and df fallback, percentage vs absolute thresholds
- Dependency checking: missing command detection
- Home skeleton: path traversal rejection, empty file list handling

**`test_integration.sh`** copies and patches project scripts into a temporary prefix (rewriting paths with `sed`), then runs `atomic-guard` and `pacman-wrapper` as separate processes. Tests verify:

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
- CI runs relevant suites on push/PR when source or test files change (path-filtered, see `.github/workflows/ci.yml`)
