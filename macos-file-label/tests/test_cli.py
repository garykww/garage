"""Tests for the macos_file_label CLI."""

from pathlib import Path
from unittest import mock

import pytest

import macos_file_label as mfl
from macos_file_label import cli


class TestListColors:
    def test_lists_colors(self, capsys):
        assert cli.main(["--list"]) == 0
        out = capsys.readouterr().out
        for color in ("red", "orange", "yellow", "green", "blue", "purple", "gray"):
            assert color in out


class TestShowLabel:
    def test_prints_current_label(self, capsys):
        with mock.patch.object(
            cli.mfl, "get_label", return_value="green"
        ), mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x"]) == 0
        assert capsys.readouterr().out.strip() == "green"


class TestSetLabel:
    def test_sets_color(self, capsys):
        with mock.patch.object(
            cli.mfl, "set_label", return_value="red"
        ), mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "red"]) == 0
        out = capsys.readouterr()
        assert out.out.strip() == "red"

    def test_color_is_case_insensitive(self, capsys):
        with mock.patch.object(cli.mfl, "set_label", return_value="blue") as set_label, \
             mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "BLUE"]) == 0
        set_label.assert_called_once_with(Path("/tmp/x"), "blue")

    def test_clear_alias_none(self, capsys):
        with mock.patch.object(cli.mfl, "clear_label") as clear, \
             mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "none"]) == 0
        clear.assert_called_once_with(Path("/tmp/x"))
        assert capsys.readouterr().out.strip() == "none"

    def test_unknown_color_exits_2(self, capsys):
        with mock.patch.object(
            cli.mfl,
            "set_label",
            side_effect=ValueError("unknown label color 'magenta'"),
        ), mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "magenta"]) == 2
        assert "unknown label color" in capsys.readouterr().err

    def test_xattr_failure_exits_1(self, capsys):
        with mock.patch.object(
            cli.mfl, "set_label", side_effect=mfl.LabelError("denied")
        ), mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "red"]) == 1
        assert "denied" in capsys.readouterr().err

    def test_missing_xattr_tool_exits_1(self, capsys):
        with mock.patch.object(
            cli.mfl, "set_label", side_effect=FileNotFoundError("xattr")
        ), mock.patch.object(cli.Path, "exists", return_value=True):
            assert cli.main(["/tmp/x", "red"]) == 1
        assert "macOS only" in capsys.readouterr().err


class TestMissingPath:
    def test_no_path_argument(self, capsys):
        assert cli.main([]) == 2
        assert "required: path" in capsys.readouterr().err

    def test_exits_1(self, capsys):
        with mock.patch.object(cli.Path, "exists", return_value=False):
            assert cli.main(["/nope", "red"]) == 1
        assert "does not exist" in capsys.readouterr().err

    def test_show_also_validates_path(self, capsys):
        with mock.patch.object(cli.Path, "exists", return_value=False):
            assert cli.main(["/nope"]) == 1
