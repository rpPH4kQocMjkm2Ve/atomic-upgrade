"""Tests for lib/atomic/fstab.py"""

import os
from pathlib import Path

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'lib', 'atomic'))
from fstab import FstabEntry, update_fstab


class TestFstabEntryParse:
    def test_comment(self):
        e = FstabEntry.parse("# /dev/sda1\n")
        assert not e.is_data
        assert e.raw == "# /dev/sda1\n"

    def test_blank(self):
        e = FstabEntry.parse("\n")
        assert not e.is_data

    def test_empty_string(self):
        e = FstabEntry.parse("")
        assert not e.is_data

    def test_short_line(self):
        e = FstabEntry.parse("foo bar baz\n")
        assert not e.is_data

    def test_root_entry(self):
        e = FstabEntry.parse(
            "UUID=abcd-1234\t/\tbtrfs\trw,subvol=/root-20250101\t0 0\n"
        )
        assert e.is_data
        assert e.device == "UUID=abcd-1234"
        assert e.mountpoint == "/"
        assert e.fstype == "btrfs"
        assert "subvol=/root-20250101" in e.options

    def test_home_entry(self):
        e = FstabEntry.parse("UUID=xyz /home btrfs rw,subvol=home 0 0\n")
        assert e.is_data
        assert e.mountpoint == "/home"

    def test_missing_dump_passno(self):
        e = FstabEntry.parse("UUID=xxx / btrfs rw,subvol=root\n")
        assert e.is_data
        assert e.dump == "0"
        assert e.passno == "0"

    def test_spaces_separator(self):
        e = FstabEntry.parse("UUID=xxx  /  btrfs  rw,subvol=root  0  0\n")
        assert e.is_data
        assert e.mountpoint == "/"

    def test_many_options(self):
        e = FstabEntry.parse(
            "UUID=x / btrfs rw,noatime,compress=zstd,subvol=/root,space_cache=v2 0 0\n"
        )
        assert e.is_data
        assert "compress=zstd" in e.options
        assert "subvol=/root" in e.options


class TestReplaceSubvol:
    def test_with_leading_slash(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=/root-old 0 0\n")
        assert e.replace_subvol("root-old", "root-new")
        assert "subvol=/root-new" in e.options

    def test_without_leading_slash(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=root-old 0 0\n")
        assert e.replace_subvol("root-old", "root-new")
        assert "subvol=root-new" in e.options
        assert "/root-new" not in e.options

    def test_old_has_slash_input_without(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=/root-old 0 0\n")
        assert e.replace_subvol("root-old", "root-new")
        assert "subvol=/root-new" in e.options

    def test_input_has_slash_fstab_without(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=root-old 0 0\n")
        assert e.replace_subvol("/root-old", "root-new")
        assert "subvol=root-new" in e.options

    def test_no_match(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=/root-other 0 0\n")
        assert not e.replace_subvol("root-old", "root-new")

    def test_preserves_other_options(self):
        e = FstabEntry.parse(
            "UUID=x / btrfs rw,noatime,subvol=/root-old,compress=zstd 0 0\n"
        )
        e.replace_subvol("root-old", "root-new")
        opts = e.options.split(",")
        assert "rw" in opts
        assert "noatime" in opts
        assert "compress=zstd" in opts
        assert "subvol=/root-new" in opts

    def test_comment_line(self):
        e = FstabEntry.parse("# subvol=root-old\n")
        assert not e.replace_subvol("root-old", "root-new")

    def test_format_unchanged_returns_raw(self):
        raw = "UUID=x /home btrfs rw,subvol=home 0 0\n"
        e = FstabEntry.parse(raw)
        assert e.format() == raw

    def test_format_modified_uses_tabs(self):
        e = FstabEntry.parse("UUID=x / btrfs rw,subvol=root-old 0 0\n")
        e.replace_subvol("root-old", "root-new")
        formatted = e.format()
        assert "root-new" in formatted
        assert "\t" in formatted

    def test_tagged_subvol(self):
        e = FstabEntry.parse(
            "UUID=x / btrfs rw,subvol=/root-20250220-141710-pre-nvidia 0 0\n"
        )
        assert e.replace_subvol(
            "root-20250220-141710-pre-nvidia",
            "root-20250221-010551"
        )
        assert "subvol=/root-20250221-010551" in e.options


class TestUpdateFstab:
    def test_basic_replacement(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,subvol=/root-old 0 0\n"
            "UUID=y /home btrfs rw,subvol=home 0 0\n"
        )
        assert update_fstab(str(path), "root-old", "root-new")
        text = path.read_text()
        assert "root-new" in text
        assert "subvol=home" in text

    def test_backup_created(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text("UUID=x / btrfs rw,subvol=root-old 0 0\n")
        update_fstab(str(path), "root-old", "root-new")
        bak = tmp_path / "fstab.bak"
        assert bak.exists()
        assert "root-old" in bak.read_text()

    def test_no_root_entry(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text("UUID=y /home btrfs rw,subvol=home 0 0\n")
        assert not update_fstab(str(path), "root-old", "root-new")

    def test_subvol_not_found(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text("UUID=x / btrfs rw,subvol=/root-other 0 0\n")
        assert not update_fstab(str(path), "root-old", "root-new")

    def test_preserves_comments(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text(
            "# root filesystem\n"
            "UUID=x / btrfs rw,subvol=root-old 0 0\n"
            "\n"
            "# home\n"
            "UUID=y /home btrfs rw,subvol=home 0 0\n"
        )
        update_fstab(str(path), "root-old", "root-new")
        text = path.read_text()
        assert "# root filesystem" in text
        assert "# home" in text

    def test_preserves_blank_lines(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,subvol=root-old 0 0\n"
            "\n"
            "UUID=y /home btrfs rw,subvol=home 0 0\n"
        )
        update_fstab(str(path), "root-old", "root-new")
        lines = path.read_text().splitlines(keepends=True)
        assert sum(1 for l in lines if l.strip() == "") >= 1

    def test_nonexistent_file(self):
        assert not update_fstab("/nonexistent/fstab", "old", "new")

    def test_permissions_preserved(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text("UUID=x / btrfs rw,subvol=root-old 0 0\n")
        path.chmod(0o644)
        update_fstab(str(path), "root-old", "root-new")
        assert path.stat().st_mode & 0o7777 == 0o644

    def test_home_subvol_untouched(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,subvol=/root-old 0 0\n"
            "UUID=x /home btrfs rw,subvol=/home 0 0\n"
        )
        assert update_fstab(str(path), "root-old", "root-new")
        text = path.read_text()
        assert "subvol=/root-new" in text
        assert "subvol=/home" in text

    def test_real_fstab(self, tmp_path):
        path = tmp_path / "fstab"
        path.write_text(
            "# /etc/fstab: static file system information.\n"
            "#\n"
            "# <file system> <mount point> <type> <options> <dump> <pass>\n"
            "\n"
            "UUID=ABCD-1234 /efi vfat rw,relatime,fmask=0022,dmask=0022 0 2\n"
            "UUID=aaaa-bbbb / btrfs rw,noatime,compress=zstd:3,ssd,subvol=/root-20250220-141710 0 0\n"
            "UUID=aaaa-bbbb /home btrfs rw,noatime,compress=zstd:3,ssd,subvol=/home 0 0\n"
            "UUID=aaaa-bbbb /var/log btrfs rw,noatime,compress=zstd:3,ssd,subvol=/log 0 0\n"
            "UUID=aaaa-bbbb /var/cache btrfs rw,noatime,compress=zstd:3,ssd,subvol=/cache 0 0\n"
            "tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0\n"
        )
        assert update_fstab(str(path), "root-20250220-141710", "root-20250221-010551")
        text = path.read_text()
        assert "subvol=/root-20250221-010551" in text
        assert "subvol=/home" in text
        assert "subvol=/log" in text
        assert "subvol=/cache" in text
        assert "root-20250220-141710" not in text
        assert "ABCD-1234" in text
        assert "tmpfs" in text

    # ── subvolid= detection (diff: fstab.py error diagnostics) ──

    def test_subvolid_without_subvol_returns_false(self, tmp_path):
        """Root entry uses subvolid= but no subvol= → update fails."""
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,noatime,subvolid=256 0 0\n"
        )
        assert not update_fstab(str(path), "root-old", "root-new")

    def test_subvolid_without_subvol_error_message(self, tmp_path, capsys):
        """Error message specifically mentions subvolid= problem."""
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,noatime,subvolid=256 0 0\n"
        )
        update_fstab(str(path), "root-old", "root-new")
        err = capsys.readouterr().err
        assert "subvolid=" in err
        assert "subvol=" in err

    def test_subvolid_with_subvol_works(self, tmp_path):
        """Both subvolid= and subvol= present → normal replacement succeeds."""
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,subvolid=256,subvol=/root-old 0 0\n"
        )
        assert update_fstab(str(path), "root-old", "root-new")
        text = path.read_text()
        assert "root-new" in text

    def test_subvol_mismatch_without_subvolid_generic_error(self, tmp_path, capsys):
        """Root has subvol= but wrong name, no subvolid= → generic error."""
        path = tmp_path / "fstab"
        path.write_text(
            "UUID=x / btrfs rw,subvol=/root-other 0 0\n"
        )
        update_fstab(str(path), "root-old", "root-new")
        err = capsys.readouterr().err
        assert "subvol=root-old not found" in err
        # Must NOT mention subvolid since there is none
        assert "subvolid=" not in err
