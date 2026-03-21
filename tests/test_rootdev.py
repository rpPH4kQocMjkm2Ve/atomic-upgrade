"""Tests for lib/atomic/rootdev.py"""

import json
import os
import subprocess
import sys
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib', 'atomic'))
from rootdev import run, detect_root, _detect_dm_type, build_cmdline, main

def _mock_run(responses):
    """Return a side_effect function that maps command tuples to outputs.

    Args:
        responses: list of (cmd_tuple, return_value) pairs
    """
    def fake(*cmd):
        for key, val in responses:
            if cmd == key:
                return val
        return ""
    return fake

# ─── run() ───────────────────────────────────────────────────────────────────

class TestRun:
    def test_success(self):
        with patch("rootdev.subprocess.run") as m:
            m.return_value = MagicMock(returncode=0, stdout="  hello  ")
            assert run("echo", "hello") == "hello"

    def test_failure_returns_empty(self):
        with patch("rootdev.subprocess.run") as m:
            m.return_value = MagicMock(returncode=1, stdout="err")
            assert run("false") == ""

    def test_timeout_returns_empty(self):
        with patch("rootdev.subprocess.run", side_effect=subprocess.TimeoutExpired("cmd", 10)):
            assert run("sleep", "999") == ""

    def test_not_found_returns_empty(self):
        with patch("rootdev.subprocess.run", side_effect=FileNotFoundError):
            assert run("nonexistent") == ""

    def test_passes_correct_args(self):
        with patch("rootdev.subprocess.run") as m:
            m.return_value = MagicMock(returncode=0, stdout="ok")
            run("blkid", "-s", "UUID", "-o", "value", "/dev/sda1")
            m.assert_called_once_with(
                ("blkid", "-s", "UUID", "-o", "value", "/dev/sda1"),
                capture_output=True, text=True, timeout=10,
            )


# ─── detect_root() — plain btrfs ────────────────────────────────────────────

FINDMNT_PLAIN = json.dumps({
    "filesystems": [{
        "source": "/dev/sda2",
        "fstype": "btrfs",
        "options": "rw,noatime,compress=zstd:3,subvol=/root-20250601",
    }]
})


class TestDetectRootPlain:
    def test_plain_btrfs(self):
        """Return a side_effect function that maps command tuples to outputs."""
        def fake(*cmd):
            for key, val in responses:
                if cmd == key:
                    return val
            return ""
        return fake

    def test_plain_btrfs(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_PLAIN),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/sda2"), "aaaa-bbbb-cccc"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["source"] == "/dev/sda2"
        assert info["fstype"] == "btrfs"
        assert info["subvol"] == "/root-20250601"
        assert info["type"] == "plain"
        assert info["luks_uuid"] is None
        assert info["luks_name"] is None
        assert info["root_arg"] == "UUID=aaaa-bbbb-cccc"

    def test_plain_no_blkid_uuid(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_PLAIN),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/sda2"), ""),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["root_arg"] == "/dev/sda2"

    def test_findmnt_empty(self):
        with patch("rootdev.run", return_value=""):
            assert detect_root() == {}

    def test_findmnt_invalid_json(self):
        with patch("rootdev.run", return_value="not-json"):
            assert detect_root() == {}

    def test_findmnt_missing_key(self):
        with patch("rootdev.run", return_value='{"something": []}'):
            assert detect_root() == {}

    def test_bracket_in_source(self):
        data = json.dumps({
            "filesystems": [{
                "source": "/dev/sda2[/root-20250601]",
                "fstype": "btrfs",
                "options": "rw,subvol=/root-20250601",
            }]
        })
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), data),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/sda2"), "some-uuid"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["source"] == "/dev/sda2"

    def test_no_subvol_in_options(self):
        data = json.dumps({
            "filesystems": [{
                "source": "/dev/sda2",
                "fstype": "ext4",
                "options": "rw,relatime",
            }]
        })
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), data),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/sda2"), "ext4-uuid"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["subvol"] is None
        assert info["fstype"] == "ext4"


# ─── detect_root() — LUKS ───────────────────────────────────────────────────

FINDMNT_LUKS = json.dumps({
    "filesystems": [{
        "source": "/dev/mapper/root_crypt[/root-20250601]",
        "fstype": "btrfs",
        "options": "rw,noatime,subvol=/root-20250601",
    }]
})

CRYPTSETUP_STATUS = """\
/dev/mapper/root_crypt is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  device:  /dev/nvme0n1p2
  offset:  32768 sectors
  size:    1234567 sectors
"""


class TestDetectRootLuks:
    def test_luks(self):
        def fake(*cmd):
            for key, val in responses:
                if cmd == key:
                    return val
            return ""
        return fake

    def test_luks(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_LUKS),
            (("dmsetup", "table", "--target", "crypt", "root_crypt"), "0 123 crypt aes-xts"),
            (("cryptsetup", "status", "root_crypt"), CRYPTSETUP_STATUS),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/nvme0n1p2"), "luks-uuid-1234"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["type"] == "luks"
        assert info["luks_name"] == "root_crypt"
        assert info["luks_uuid"] == "luks-uuid-1234"
        assert info["root_arg"] == "/dev/mapper/root_crypt"
        assert info["source"] == "/dev/mapper/root_crypt"

    def test_luks_no_underlying_uuid(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_LUKS),
            (("dmsetup", "table", "--target", "crypt", "root_crypt"), "0 123 crypt aes"),
            (("cryptsetup", "status", "root_crypt"), CRYPTSETUP_STATUS),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/nvme0n1p2"), ""),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["type"] == "luks"
        assert info["luks_uuid"] is None


# ─── detect_root() — LVM ────────────────────────────────────────────────────

FINDMNT_LVM = json.dumps({
    "filesystems": [{
        "source": "/dev/mapper/vg0-root",
        "fstype": "btrfs",
        "options": "rw,subvol=/root-20250601",
    }]
})


class TestDetectRootLvm:
    def test_lvm_plain(self):
        def fake(*cmd):
            for key, val in responses:
                if cmd == key:
                    return val
            return ""
        return fake

    def test_lvm_plain(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_LVM),
            (("dmsetup", "table", "--target", "crypt", "vg0-root"), ""),
            (("lvs", "--noheadings", "-o", "vg_name,lv_name", "/dev/mapper/vg0-root"), "  vg0  root"),
            (("pvs", "--noheadings", "-o", "pv_name", "-S", "vg_name=vg0"), "  /dev/sda2"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["type"] == "lvm"
        assert info["root_arg"] == "/dev/mapper/vg0-root"
        assert info["luks_uuid"] is None

    def test_lvm_on_luks(self):
        responses = [
            (("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"), FINDMNT_LVM),
            (("dmsetup", "table", "--target", "crypt", "vg0-root"), ""),
            (("lvs", "--noheadings", "-o", "vg_name,lv_name", "/dev/mapper/vg0-root"), "  vg0  root"),
            (("pvs", "--noheadings", "-o", "pv_name", "-S", "vg_name=vg0"), "  /dev/mapper/crypt_pv"),
            (("dmsetup", "table", "--target", "crypt", "crypt_pv"), "0 999 crypt aes"),
            (("cryptsetup", "status", "crypt_pv"), "  device:  /dev/sda3"),
            (("blkid", "-s", "UUID", "-o", "value", "/dev/sda3"), "luks-pv-uuid"),
        ]
        with patch("rootdev.run", side_effect=_mock_run(responses)):
            info = detect_root()
        assert info["type"] == "luks+lvm"
        assert info["luks_name"] == "crypt_pv"
        assert info["luks_uuid"] == "luks-pv-uuid"
        assert info["root_arg"] == "/dev/mapper/vg0-root"


# ─── _detect_dm_type() directly ─────────────────────────────────────────────

class TestDetectDmType:
    def test_crypt_target(self):
        info = {"type": "plain", "luks_uuid": None, "luks_name": None, "root_arg": ""}

        def fake(*cmd):
            if cmd == ("dmsetup", "table", "--target", "crypt", "dm_root"):
                return "0 123 crypt aes"
            if cmd == ("cryptsetup", "status", "dm_root"):
                return "  device:  /dev/sda1"
            if cmd == ("blkid", "-s", "UUID", "-o", "value", "/dev/sda1"):
                return "uuid-abcd"
            return ""

        with patch("rootdev.run", side_effect=fake):
            _detect_dm_type("dm_root", info)

        assert info["type"] == "luks"
        assert info["luks_name"] == "dm_root"
        assert info["luks_uuid"] == "uuid-abcd"

    def test_neither_crypt_nor_lvm(self):
        info = {"type": "plain", "luks_uuid": None, "luks_name": None, "root_arg": ""}
        with patch("rootdev.run", return_value=""):
            _detect_dm_type("mystery", info)
        assert info["type"] == "plain"


# ─── build_cmdline() ────────────────────────────────────────────────────────

class TestBuildCmdline:
    def test_plain_btrfs(self):
        info = {
            "type": "plain",
            "root_arg": "UUID=aaaa-bbbb",
            "fstype": "btrfs",
            "subvol": "/root-old",
            "luks_uuid": None,
            "luks_name": None,
        }
        result = build_cmdline(info, "root-new")
        assert result == "root=UUID=aaaa-bbbb rootfstype=btrfs rootflags=subvol=/root-new"

    def test_luks(self):
        info = {
            "type": "luks",
            "root_arg": "/dev/mapper/root_crypt",
            "fstype": "btrfs",
            "subvol": "/root-old",
            "luks_uuid": "1111-2222",
            "luks_name": "root_crypt",
        }
        result = build_cmdline(info, "root-new")
        assert "rd.luks.name=1111-2222=root_crypt" in result
        assert "root=/dev/mapper/root_crypt" in result
        assert "rootfstype=btrfs" in result
        assert "rootflags=subvol=/root-new" in result

    def test_luks_plus_lvm(self):
        info = {
            "type": "luks+lvm",
            "root_arg": "/dev/mapper/vg0-root",
            "fstype": "btrfs",
            "subvol": "/root-old",
            "luks_uuid": "abcd-uuid",
            "luks_name": "crypt_pv",
        }
        result = build_cmdline(info, "root-new")
        assert "rd.luks.name=abcd-uuid=crypt_pv" in result
        assert "root=/dev/mapper/vg0-root" in result

    def test_subvol_without_leading_slash(self):
        info = {
            "type": "plain",
            "root_arg": "UUID=x",
            "fstype": "btrfs",
            "subvol": "root-old",
            "luks_uuid": None,
            "luks_name": None,
        }
        result = build_cmdline(info, "root-new")
        assert "rootflags=subvol=root-new" in result
        assert "/root-new" not in result

    def test_subvol_with_leading_slash(self):
        info = {
            "type": "plain",
            "root_arg": "UUID=x",
            "fstype": "btrfs",
            "subvol": "/root-old",
            "luks_uuid": None,
            "luks_name": None,
        }
        result = build_cmdline(info, "root-new")
        assert "rootflags=subvol=/root-new" in result

    def test_no_fstype(self):
        info = {
            "type": "plain",
            "root_arg": "UUID=x",
            "fstype": "",
            "subvol": "/root-old",
            "luks_uuid": None,
            "luks_name": None,
        }
        result = build_cmdline(info, "root-new")
        assert "rootfstype" not in result

    def test_luks_without_uuid_no_rd_luks(self):
        info = {
            "type": "luks",
            "root_arg": "/dev/mapper/root_crypt",
            "fstype": "btrfs",
            "subvol": "/root-old",
            "luks_uuid": None,
            "luks_name": "root_crypt",
        }
        result = build_cmdline(info, "root-new")
        assert "rd.luks" not in result
        assert "root=/dev/mapper/root_crypt" in result

    def test_empty_subvol_key(self):
        info = {
            "type": "plain",
            "root_arg": "UUID=x",
            "fstype": "btrfs",
            "luks_uuid": None,
            "luks_name": None,
        }
        result = build_cmdline(info, "snap-123")
        assert "rootflags=subvol=snap-123" in result

    def test_order(self):
        info = {
            "type": "luks",
            "root_arg": "/dev/mapper/rc",
            "fstype": "btrfs",
            "subvol": "/old",
            "luks_uuid": "U",
            "luks_name": "rc",
        }
        result = build_cmdline(info, "new")
        parts = result.split()
        assert parts[0].startswith("rd.luks.name=")
        assert parts[1].startswith("root=")
        assert parts[2].startswith("rootfstype=")
        assert parts[3].startswith("rootflags=")


# ─── main() CLI ─────────────────────────────────────────────────────────────

class TestMain:
    def test_no_args(self, capsys):
        with patch("sys.argv", ["rootdev.py"]):
            assert main() == 1
        assert "Usage" in capsys.readouterr().err

    def test_unknown_command(self, capsys):
        with patch("sys.argv", ["rootdev.py", "foobar"]):
            assert main() == 1
        assert "Unknown command" in capsys.readouterr().err

    def test_detect_success(self, capsys):
        fake_info = {
            "source": "/dev/sda2", "fstype": "btrfs", "subvol": "/root",
            "type": "plain", "luks_uuid": None, "luks_name": None,
            "root_arg": "UUID=xxx",
        }
        with patch("sys.argv", ["rootdev.py", "detect"]), \
             patch("rootdev.detect_root", return_value=fake_info):
            assert main() == 0
        out = json.loads(capsys.readouterr().out)
        assert out["source"] == "/dev/sda2"

    def test_detect_failure(self, capsys):
        with patch("sys.argv", ["rootdev.py", "detect"]), \
             patch("rootdev.detect_root", return_value={}):
            assert main() == 1
        assert "Failed" in capsys.readouterr().err

    def test_cmdline_no_subvol(self, capsys):
        with patch("sys.argv", ["rootdev.py", "cmdline"]):
            assert main() == 1
        assert "SUBVOL" in capsys.readouterr().err

    def test_cmdline_success(self, capsys):
        fake_info = {
            "source": "/dev/sda2", "fstype": "btrfs", "subvol": "/root-old",
            "type": "plain", "luks_uuid": None, "luks_name": None,
            "root_arg": "UUID=xxx",
        }
        with patch("sys.argv", ["rootdev.py", "cmdline", "root-new"]), \
             patch("rootdev.detect_root", return_value=fake_info):
            assert main() == 0
        out = capsys.readouterr().out.strip()
        assert "root=UUID=xxx" in out
        assert "rootflags=subvol=/root-new" in out

    def test_cmdline_detect_fails(self, capsys):
        with patch("sys.argv", ["rootdev.py", "cmdline", "snap"]), \
             patch("rootdev.detect_root", return_value={}):
            assert main() == 1

    def test_device_success(self, capsys):
        fake_info = {
            "source": "/dev/mapper/root_crypt", "fstype": "btrfs",
            "subvol": "/root", "type": "luks", "luks_uuid": "U",
            "luks_name": "root_crypt", "root_arg": "/dev/mapper/root_crypt",
        }
        with patch("sys.argv", ["rootdev.py", "device"]), \
             patch("rootdev.detect_root", return_value=fake_info):
            assert main() == 0
        assert capsys.readouterr().out.strip() == "/dev/mapper/root_crypt"

    def test_device_detect_fails(self, capsys):
        with patch("sys.argv", ["rootdev.py", "device"]), \
             patch("rootdev.detect_root", return_value={}):
            assert main() == 1


# ─── Integration-style: full detect→cmdline ─────────────────────────────────

class TestIntegration:
    """End-to-end with all run() calls mocked."""

    def test_luks_full_pipeline(self):
        findmnt_json = json.dumps({
            "filesystems": [{
                "source": "/dev/mapper/root_crypt[/root-20250601-120000]",
                "fstype": "btrfs",
                "options": "rw,noatime,compress=zstd:3,subvol=/root-20250601-120000",
            }]
        })

        def fake_run(*cmd):
            mapping = {
                ("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"): findmnt_json,
                ("dmsetup", "table", "--target", "crypt", "root_crypt"): "0 999 crypt aes",
                ("cryptsetup", "status", "root_crypt"):
                    "  type:  LUKS2\n  device:  /dev/nvme0n1p2\n",
                ("blkid", "-s", "UUID", "-o", "value", "/dev/nvme0n1p2"): "550e8400-dead-beef",
            }
            return mapping.get(cmd, "")

        with patch("rootdev.run", side_effect=fake_run):
            info = detect_root()

        assert info["type"] == "luks"
        assert info["luks_uuid"] == "550e8400-dead-beef"

        cmdline = build_cmdline(info, "root-20250602-090000")
        assert cmdline == (
            "rd.luks.name=550e8400-dead-beef=root_crypt "
            "root=/dev/mapper/root_crypt "
            "rootfstype=btrfs "
            "rootflags=subvol=/root-20250602-090000"
        )

    def test_plain_full_pipeline(self):
        findmnt_json = json.dumps({
            "filesystems": [{
                "source": "/dev/nvme0n1p2",
                "fstype": "btrfs",
                "options": "rw,noatime,subvol=/root-20250601",
            }]
        })

        def fake_run(*cmd):
            mapping = {
                ("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/"): findmnt_json,
                ("blkid", "-s", "UUID", "-o", "value", "/dev/nvme0n1p2"): "plain-uuid-1234",
            }
            return mapping.get(cmd, "")

        with patch("rootdev.run", side_effect=fake_run):
            info = detect_root()

        cmdline = build_cmdline(info, "root-20250602")
        assert cmdline == (
            "root=UUID=plain-uuid-1234 "
            "rootfstype=btrfs "
            "rootflags=subvol=/root-20250602"
        )
