#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
from pathlib import Path
import pytest

LIBDIR = Path(__file__).parent.parent / "lib" / "atomic"
CONFIG_SCRIPT = LIBDIR / "config.py"


@pytest.fixture
def temp_config(tmp_path):
    """Create a temporary config file and yield its path."""
    config_path = tmp_path / "atomic.conf"
    yield str(config_path)


def run_config(*args, config_path=None):
    env = os.environ.copy()
    if config_path is not None:
        env['CONFIG_FILE'] = config_path
    result = subprocess.run(
        ["python3", str(CONFIG_SCRIPT)] + list(args),
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def create_temp_config(path, content, owner_uid=0):
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, 0o644)
    if owner_uid != 0:
        try:
            os.chown(path, owner_uid, -1)
        except PermissionError:
            pass
    return path


class TestParseConfig:
    def test_defaults_without_file(self, temp_config):
        code, stdout, stderr = run_config("dump", config_path=temp_config)
        assert code == 0
        data = json.loads(stdout)
        assert data["BTRFS_MOUNT"] == "/run/atomic/temp_root"
        assert data["KEEP_GENERATIONS"] == "3"
        assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"

    def test_simple_key_value(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "BTRFS_MOUNT=/custom/mount\n")
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["BTRFS_MOUNT"] == "/custom/mount"

    def test_quoted_value_single(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "CHROOT_COMMAND='/usr/bin/pacman -Syu'\n")
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"

    def test_quoted_value_double(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, 'CHROOT_COMMAND="/usr/bin/pacman -Syu"\n')
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["CHROOT_COMMAND"] == "/usr/bin/pacman -Syu"

    def test_inline_comment(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "ESP=/efi # this is a comment\n")
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["ESP"] == "/efi"

    def test_shlex_quote_handling(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, 'CHROOT_COMMAND=pacman -S "package with spaces"\n')
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["CHROOT_COMMAND"] == 'pacman -S "package with spaces"'

    def test_unknown_key_ignored(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "UNKNOWN_KEY=value\n")
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        assert "WARN" in stderr
        data = json.loads(stdout)
        assert "UNKNOWN_KEY" not in data

    def test_comment_lines_skipped(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "# This is a comment\nESP=/boot/efi\n")
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["ESP"] == "/boot/efi"

    @pytest.mark.skipif(os.geteuid() != 0, reason="requires root")
    def test_config_not_owned_by_root(self, tmp_path):
        # Ownership check only triggers for /etc/atomic.conf.
        # Use a real path in /etc via bind-mount over tmpfs so no real file is modified.
        real_path = Path("/etc/atomic.conf")
        # Ensure mount point exists before bind-mount
        real_path.touch(exist_ok=True)
        mount_point = tmp_path / "etc_atomic_conf"
        mount_point.write_text("ESP=/efi\n")
        # Bind-mount tmp file over /etc/atomic.conf
        import subprocess as sp
        sp.run(["mount", "--bind", str(mount_point), str(real_path)], check=True)
        try:
            os.chown(str(real_path), 1000, -1)
            code, stdout, stderr = run_config("dump", config_path=str(real_path))
            assert code == 1
            assert "not owned by root" in stderr
        finally:
            sp.run(["umount", str(real_path)], check=False)


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

    def test_invalid_keep_generations(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "KEEP_GENERATIONS=abc\n")
        code, stdout, stderr = run_config("validate", config_path=config_path)
        assert code == 1


class TestShellOutput:
    def test_shell_output_format(self):
        code, stdout, stderr = run_config("shell")
        assert code == 0
        lines = stdout.split("\n")
        assert any(line.startswith("BTRFS_MOUNT=") for line in lines)
        assert any(line.startswith("KEEP_GENERATIONS=") for line in lines)

    def test_shell_output_escapes_spaces(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, 'CHROOT_COMMAND=pacman -S "package with spaces"\n')
        code, stdout, stderr = run_config("shell", config_path=config_path)
        assert code == 0
        lines = stdout.split("\n")
        cmd_line = [line for line in lines if line.startswith("CHROOT_COMMAND=")][0]
        assert "pacman" in cmd_line


class TestArrayOutput:
    def test_array_simple(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, "CHROOT_COMMAND=/usr/bin/pacman -Syu\n")
        code, stdout, stderr = run_config("array", "CHROOT_COMMAND", config_path=config_path)
        assert code == 0
        tokens = stdout.split("\0")
        assert "pacman" in tokens[0]

    def test_array_with_quoted_spaces(self, temp_config):
        config_path = temp_config
        create_temp_config(config_path, 'CHROOT_COMMAND=pacman -S "package with spaces"\n')
        code, stdout, stderr = run_config("array", "CHROOT_COMMAND", config_path=config_path)
        assert code == 0
        tokens = [t for t in stdout.split("\0") if t]
        assert "package with spaces" in tokens


class TestDefaultConfig:
    def test_owner_check_skipped_for_non_system_paths(self, temp_config):
        """Ownership check should be skipped for paths other than /etc/atomic.conf."""
        config_path = temp_config
        create_temp_config(config_path, "ESP=/test\n", owner_uid=1000)
        code, stdout, stderr = run_config("dump", config_path=config_path)
        assert code == 0
        data = json.loads(stdout)
        assert data["ESP"] == "/test"
