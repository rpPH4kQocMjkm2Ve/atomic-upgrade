#!/usr/bin/env python3
"""
/usr/lib/atomic/fstab.py

Safe fstab manipulation for atomic-upgrade.
Handles subvol= replacement for mount entries.

Usage:
  fstab.py <fstab_path> <old_subvol> <new_subvol>          — update root (/)
  fstab.py home <fstab_path> <new_home_subvol>             — update /home

Safety features:
  - Only modifies entries with the target mountpoint
  - Creates backup before writing
  - Atomic write via tmp+rename
  - Post-write verification with auto-rollback
  - Preserves leading slash style in subvol= values
"""

import os
import re
import stat as stat_mod
import sys
import shutil
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class FstabEntry:
    """Represents a single fstab line (data or comment/blank)."""

    raw: str
    device: str = ""
    mountpoint: str = ""
    fstype: str = ""
    options: str = ""
    dump: str = "0"
    passno: str = "0"
    is_data: bool = False
    _modified: bool = field(default=False, init=False, repr=False, compare=False)

    @classmethod
    def parse(cls, line: str) -> "FstabEntry":
        """Parse a single fstab line. Non-data lines are preserved as-is."""
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return cls(raw=line)

        parts = stripped.split()
        if len(parts) < 4:
            return cls(raw=line)

        return cls(
            raw=line,
            device=parts[0],
            mountpoint=parts[1],
            fstype=parts[2],
            options=parts[3],
            dump=parts[4] if len(parts) > 4 else "0",
            passno=parts[5] if len(parts) > 5 else "0",
            is_data=True,
        )

    def replace_subvol(self, old: str, new: str) -> bool:
        """Replace subvol=<old> with subvol=<new> in mount options.

        Preserves the leading slash style: if the original value had
        a leading /, the replacement will too, and vice versa.

        Returns True if a replacement was made.
        """
        if not self.is_data:
            return False

        opts = self.options.split(",")
        if any(o.startswith("subvolid=") for o in opts):
            print(
                "WARN: subvolid= found in fstab root entry, "
                "may override subvol= on some kernels. "
                "Consider removing subvolid= from fstab.",
                file=sys.stderr,
            )
        changed = False
        result = []

        old_norm = old.strip("/")
        new_norm = new.strip("/")

        for opt in opts:
            if opt.startswith("subvol="):
                val = opt[len("subvol="):]
                if val.lstrip("/") == old_norm:
                    prefix = "/" if val.startswith("/") else ""
                    result.append(f"subvol={prefix}{new_norm}")
                    changed = True
                    continue
            result.append(opt)

        if changed:
            self.options = ",".join(result)
            self._modified = True
        return changed

    def set_subvol(self, new: str) -> bool:
        """Set subvol= to a new value regardless of old value.

        Used for /home where we don't know/care about the old subvol name.
        Preserves leading slash style of the existing value.

        Returns True if a change was made.
        """
        if not self.is_data:
            return False

        opts = self.options.split(",")
        new_norm = new.strip("/")
        changed = False
        result = []

        for opt in opts:
            if opt.startswith("subvol="):
                val = opt[len("subvol="):]
                current_norm = val.lstrip("/")
                if current_norm == new_norm:
                    result.append(opt)
                    continue
                prefix = "/" if val.startswith("/") else ""
                result.append(f"subvol={prefix}{new_norm}")
                changed = True
                continue
            result.append(opt)

        if changed:
            self.options = ",".join(result)
            self._modified = True
        return changed

    def format(self) -> str:
        """Format entry back to fstab line."""
        if not self.is_data:
            return self.raw
        if not self._modified:
            return self.raw
        return (
            f"{self.device}\t{self.mountpoint}\t{self.fstype}"
            f"\t{self.options}\t{self.dump} {self.passno}\n"
        )


def _atomic_write(path: Path, entries: list) -> None:
    """Write entries to fstab atomically with permission preservation."""
    tmp = path.with_suffix(".tmp")
    original_stat = path.stat()
    content = "".join(e.format() for e in entries).encode()

    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, content)
        os.fsync(fd)
    finally:
        os.close(fd)

    try:
        os.chown(tmp, original_stat.st_uid, original_stat.st_gid)
        os.chmod(tmp, stat_mod.S_IMODE(original_stat.st_mode))
    except OSError as e:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise RuntimeError(f"Failed to set permissions on {tmp}: {e}") from e

    tmp.replace(path)

    dir_fd = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def update_fstab(path_str: str, old_subvol: str, new_subvol: str) -> bool:
    """Update the root entry's subvol= in fstab.

    Returns True on success, False on any error.
    """
    path = Path(path_str)

    if not path.is_file():
        print(f"ERROR: fstab not found: {path}", file=sys.stderr)
        return False

    backup = path.with_suffix(".bak")
    shutil.copy2(path, backup)

    lines = path.read_text().splitlines(keepends=True)
    entries = [FstabEntry.parse(line) for line in lines]

    root_entries = [e for e in entries if e.is_data and e.mountpoint == "/"]

    if not root_entries:
        print("ERROR: No root (/) entry found in fstab", file=sys.stderr)
        return False

    updated = 0
    for entry in root_entries:
        if entry.replace_subvol(old_subvol, new_subvol):
            updated += 1

    if updated == 0:
        has_subvolid = any(
            e.is_data and e.mountpoint == "/"
            and any(o.startswith("subvolid=") for o in e.options.split(","))
            for e in entries
        )
        if has_subvolid:
            print(
                f"ERROR: Root entry uses subvolid= without subvol=. "
                f"Add 'subvol={old_subvol}' to fstab mount options.",
                file=sys.stderr,
            )
        else:
            print(
                f"ERROR: Root entry exists but subvol={old_subvol} not found",
                file=sys.stderr,
            )
        return False

    if updated > 1:
        print(
            f"WARN: Multiple root entries updated ({updated}), review fstab",
            file=sys.stderr,
        )

    _atomic_write(path, entries)

    # Post-write verification
    new_norm = new_subvol.strip("/")
    text = path.read_text()
    if f"subvol=/{new_norm}" not in text and f"subvol={new_norm}" not in text:
        print("ERROR: Verification failed, restoring backup", file=sys.stderr)
        shutil.copy2(backup, path)
        return False

    backup.unlink(missing_ok=True)
    return True


def update_fstab_home(path_str: str, new_home_subvol: str) -> bool:
    """Update the /home entry's subvol= in fstab.

    Unlike update_fstab(), this does not require knowing the old subvol name —
    it replaces whatever subvol= value is currently set on /home entries.

    Returns True on success, False on any error.
    """
    path = Path(path_str)

    if not path.is_file():
        print(f"ERROR: fstab not found: {path}", file=sys.stderr)
        return False

    new_norm = new_home_subvol.strip("/")
    if not new_norm:
        print("ERROR: Empty home subvolume name", file=sys.stderr)
        return False

    if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$', new_norm):
        print(f"ERROR: Invalid home subvolume name: {new_norm}", file=sys.stderr)
        return False

    backup = path.with_suffix(".home-bak")
    shutil.copy2(path, backup)

    lines = path.read_text().splitlines(keepends=True)
    entries = [FstabEntry.parse(line) for line in lines]

    home_entries = [e for e in entries if e.is_data and e.mountpoint == "/home"]

    if not home_entries:
        print("WARN: No /home entry found in fstab", file=sys.stderr)
        backup.unlink(missing_ok=True)
        return False

    has_subvol = any("subvol=" in e.options for e in home_entries)
    if not has_subvol:
        print("WARN: /home entry has no subvol= option", file=sys.stderr)
        backup.unlink(missing_ok=True)
        return False

    updated = 0
    for entry in home_entries:
        if entry.set_subvol(new_norm):
            updated += 1

    if updated == 0:
        print(f"   /home subvol already set to {new_norm}", file=sys.stderr)
        backup.unlink(missing_ok=True)
        return True

    if updated > 1:
        print(
            f"WARN: Multiple /home entries updated ({updated}), review fstab",
            file=sys.stderr,
        )

    _atomic_write(path, entries)

    text = path.read_text()
    if f"subvol=/{new_norm}" not in text and f"subvol={new_norm}" not in text:
        print("ERROR: /home fstab verification failed, restoring backup", file=sys.stderr)
        shutil.copy2(backup, path)
        backup.unlink(missing_ok=True)
        return False

    backup.unlink(missing_ok=True)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} FSTAB_PATH OLD_SUBVOL NEW_SUBVOL", file=sys.stderr)
        print(f"       {sys.argv[0]} home FSTAB_PATH NEW_HOME_SUBVOL", file=sys.stderr)
        sys.exit(1)

    if sys.argv[1] == "home":
        if len(sys.argv) != 4:
            print(f"Usage: {sys.argv[0]} home FSTAB_PATH NEW_HOME_SUBVOL", file=sys.stderr)
            sys.exit(1)
        sys.exit(0 if update_fstab_home(sys.argv[2], sys.argv[3]) else 1)
    else:
        if len(sys.argv) != 4:
            print(f"Usage: {sys.argv[0]} FSTAB_PATH OLD_SUBVOL NEW_SUBVOL", file=sys.stderr)
            sys.exit(1)
        sys.exit(0 if update_fstab(*sys.argv[1:]) else 1)
