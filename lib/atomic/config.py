#!/usr/bin/env python3
"""
/usr/lib/atomic/config.py

Parse /etc/atomic.conf with proper shell-style quote handling.
Strips outer quotes (single/double) and handles inline comments.
Uses shlex only in config_to_array() for safe tokenization.

Usage:
  config.py                    -> dump all config as JSON
  config.py KEY                 -> print value of KEY
  config.py validate            -> validate config, exit 0/1
"""

import json
import shlex
import sys
import os
from pathlib import Path

DEFAULT_CONFIG = {
    "BTRFS_MOUNT": "/run/atomic/temp_root",
    "NEW_ROOT": "/run/atomic/newroot",
    "ESP": "/efi",
    "KEEP_GENERATIONS": "3",
    "MAPPER_NAME": "root_crypt",
    "KERNEL_PKG": "linux",
    "KERNEL_PARAMS": "rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off",
    "CHROOT_COMMAND": "/usr/bin/pacman -Syu",
    "SBCTL_SIGN": "0",
    "UPGRADE_GUARD": "1",
    "HOME_COPY_FILES": "",
}

ALLOWED_KEYS = set(DEFAULT_CONFIG.keys())


def parse_config(path=None):
    """Parse atomic.conf with proper quote handling.

    Strips outer quotes (single/double) and handles inline comments.
    Uses shlex only in config_to_array() for safe tokenization.
    """
    config = dict(DEFAULT_CONFIG)
    if path is None:
        path = os.environ.get("CONFIG_FILE", "/etc/atomic.conf")
    config_path = Path(path)
    if not config_path.exists():
        return config

    # Only check owner for /etc/atomic.conf (system config).
    # Resolve symlinks so that CONFIG_FILE set to a symlink pointing
    # to /etc/atomic.conf is still correctly validated.
    # Other paths (e.g. test configs) are allowed to have any owner.
    if config_path.resolve() == Path("/etc/atomic.conf"):
        try:
            if config_path.resolve().stat().st_uid != 0:
                print(f"ERROR: {config_path.resolve()} not owned by root", file=sys.stderr)
                sys.exit(1)
        except OSError as e:
            print(f"ERROR: Cannot read {path}: {e}", file=sys.stderr)
            sys.exit(1)

    content = config_path.read_text()

    for line in content.splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        if " #" in line:
            line = line[:line.index(" #")].strip()

        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if key not in ALLOWED_KEYS:
            print(f"WARN: Unknown config key ignored: {key}", file=sys.stderr)
            continue

        if len(value) >= 2:
            if (value.startswith('"') and value.endswith('"')) or \
               (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
        config[key] = value

    return config


def config_to_shell(config):
    """Convert config dict to shell-safe KEY=value lines."""
    lines = []
    for key, value in config.items():
        lines.append(f"{key}={value}")
    return "\n".join(lines)


def config_to_array(config, key):
    """Output array elements null-separated for safe shell reading."""
    value = config.get(key, "")
    if not value:
        return
    tokens = shlex.split(value, posix=True)
    for token in tokens:
        sys.stdout.write(token + '\0')


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "dump"

    if command == "dump":
        config = parse_config()
        json.dump(config, sys.stdout, indent=2)
        print()
        return 0

    if command == "validate":
        config = parse_config()
        numeric_keys = ["KEEP_GENERATIONS", "SBCTL_SIGN", "UPGRADE_GUARD"]
        for key in numeric_keys:
            try:
                int(config[key])
            except ValueError:
                print(f"ERROR: {key} must be a number", file=sys.stderr)
                return 1
        print("Config valid")
        return 0

    if command == "shell":
        config = parse_config()
        print(config_to_shell(config))
        return 0

    if command == "array":
        if len(sys.argv) < 3:
            print("ERROR: array command requires KEY argument", file=sys.stderr)
            return 1
        key = sys.argv[2]
        config = parse_config()
        config_to_array(config, key)
        return 0

    key = command
    config = parse_config()
    if key not in config:
        print(f"ERROR: Unknown key: {key}", file=sys.stderr)
        return 1

    print(config[key])
    return 0


if __name__ == "__main__":
    sys.exit(main())
