#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
from pathlib import Path
import pytest

LIBDIR = Path(__file__).parent.parent / "lib" / "atomic"
CONFIG_SCRIPT = LIBDIR / "config.py"


def run_config(*args):
    env = os.environ.copy()
    if hasattr(run_config, 'config_path'):
        env['CONFIG_FILE'] = run_config.config_path
    result = subprocess.run(
        ["python3", str(CONFIG_SCRIPT)] + list(args),
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def create_temp_config(content, owner_uid=0):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
        f.write(content)
        path = f.name
    os.chmod(path, 0o644)
    if owner_uid != 0:
        try:
            os.chown(path, owner_uid, -1)
        except PermissionError:
            pass
    return path


class TestParseConfig:
    def test_defaults_without_file(self):
        code, stdout, stderr = run_config("dump")
        assert code == 0
        data = json.loads(stdout)
        assert data["BTRFS_MOUNT"] == "/run/atomic/temp_root"
        assert data["KEEP_GENERATIONS"] == "3"
        assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"

    def test_simple_key_value(self):
        config_path = create_temp_config("BTRFS_MOUNT=/custom/mount\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["BTRFS_MOUNT"] == "/custom/mount"
        finally:
            os.unlink(config_path)

    def test_quoted_value_single(self):
        config_path = create_temp_config("CHROOT_COMMAND='/usr/bin/pacman -Syu'\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"
        finally:
            os.unlink(config_path)

    def test_quoted_value_double(self):
        config_path = create_temp_config('CHROOT_COMMAND="/usr/bin/pacman -Syu"\n')
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"
        finally:
            os.unlink(config_path)

    def test_inline_comment(self):
        config_path = create_temp_config("ESP=/efi # this is a comment\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["ESP"] == "/efi"
        finally:
            os.unlink(config_path)

    def test_shlex_quote_handling(self):
        config_path = create_temp_config('CHROOT_COMMAND=pacman -S "package with spaces"\n')
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["CHROOT_COMMAND"] == 'pacman -S "package with spaces"'
        finally:
            os.unlink(config_path)

    def test_unknown_key_ignored(self):
        config_path = create_temp_config("UNKNOWN_KEY=value\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            assert "WARN" in stderr
            data = json.loads(stdout)
            assert "UNKNOWN_KEY" not in data
        finally:
            os.unlink(config_path)

    def test_comment_lines_skipped(self):
        config_path = create_temp_config("# This is a comment\nESP=/boot/efi\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("dump")
            assert code == 0
            data = json.loads(stdout)
            assert data["ESP"] == "/boot/efi"
        finally:
            os.unlink(config_path)

    def test_config_not_owned_by_root(self):
        config_path = create_temp_config("ESP=/efi\n")
        run_config.config_path = config_path
        try:
            if os.geteuid() == 0:
                os.chown(config_path, 1000, -1)
                code, stdout, stderr = run_config("dump")
                assert code == 1
                assert "not owned by root" in stderr
        finally:
            os.unlink(config_path)


class TestKeyLookup:
    def test_valid_key(self):
        code, stdout, stderr = run_config("CHROOT_COMMAND")
        assert code == 0
        assert "pacman" in stdout

    def test_invalid_key(self):
        code, stdout, stderr = run_config("NONEXISTENT")
        assert code == 1
        assert "ERROR" in stderr


class TestValidate:
    def test_valid_config(self):
        code, stdout, stderr = run_config("validate")
        assert code == 0
        assert "Config valid" in stdout

    def test_invalid_keep_generations(self):
        config_path = create_temp_config("KEEP_GENERATIONS=abc\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("validate")
            assert code == 1
        finally:
            os.unlink(config_path)


class TestShellOutput:
    def test_shell_output_format(self):
        code, stdout, stderr = run_config("shell")
        assert code == 0
        lines = stdout.split("\n")
        assert any(line.startswith("BTRFS_MOUNT=") for line in lines)
        assert any(line.startswith("KEEP_GENERATIONS=") for line in lines)


class TestArrayOutput:
    def test_array_simple(self):
        config_path = create_temp_config("CHROOT_COMMAND=/usr/bin/pacman -Syu\n")
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("array", "CHROOT_COMMAND")
            assert code == 0
            tokens = stdout.split("\0")
            assert "pacman" in tokens[0]
        finally:
            os.unlink(config_path)

    def test_array_with_quoted_spaces(self):
        config_path = create_temp_config('CHROOT_COMMAND=pacman -S "package with spaces"\n')
        run_config.config_path = config_path
        try:
            code, stdout, stderr = run_config("array", "CHROOT_COMMAND")
            assert code == 0
            tokens = [t for t in stdout.split("\0") if t]
            assert "package with spaces" in tokens
        finally:
            os.unlink(config_path)
