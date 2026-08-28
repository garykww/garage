"""Tests for the macos_file_label core.

xattr I/O is mocked, so the suite runs on any OS (CI is Linux, where the
com.apple.* xattr namespace is not writable).
"""

from unittest import mock

import pytest

import macos_file_label as mfl


def finder_info(label_bits: int, extra_bits: int = 0) -> bytes:
    data = bytearray(b"\x00" * mfl.FINDER_INFO_SIZE)
    data[5] = 0xA5  # sentinel byte that must survive label edits
    data[mfl.LABEL_OFFSET] = (label_bits & mfl.LABEL_MASK) | extra_bits
    return bytes(data)


class TestLabelValue:
    @pytest.mark.parametrize(
        ("color", "expected"),
        [
            ("red", 1),
            ("orange", 2),
            ("yellow", 3),
            ("green", 4),
            ("blue", 5),
            ("purple", 6),
            ("gray", 7),
            ("grey", 7),
            ("RED", 1),
        ],
    )
    def test_known_colors(self, color, expected):
        assert mfl.label_value(color) == expected

    def test_unknown_color_raises(self):
        with pytest.raises(ValueError, match="unknown label color"):
            mfl.label_value("magenta")


class TestLabelName:
    def test_all_values(self):
        for value in range(8):
            assert mfl.label_name(value) in mfl._NAME_BY_VALUE.values()

    def test_gray_is_canonical(self):
        assert mfl.label_name(7) == "gray"


class TestEncodeLabel:
    def test_sets_label_bits(self):
        assert mfl.encode_label(b"", "blue")[mfl.LABEL_OFFSET] == 5

    def test_preserves_other_bytes(self):
        out = mfl.encode_label(finder_info(0), "orange")
        assert out[5] == 0xA5
        assert out[mfl.LABEL_OFFSET] == 2

    def test_preserves_high_bits_of_label_byte(self):
        out = mfl.encode_label(finder_info(0, extra_bits=0x10), "red")
        assert out[mfl.LABEL_OFFSET] == 0x11

    def test_truncates_long_input(self):
        out = mfl.encode_label(b"\xff" * 40, "green")
        assert len(out) == mfl.FINDER_INFO_SIZE
        assert out[mfl.LABEL_OFFSET] == (0xFF & ~mfl.LABEL_MASK) | 4

    def test_pads_short_input(self):
        out = mfl.encode_label(b"\x01", "yellow")
        assert len(out) == mfl.FINDER_INFO_SIZE
        assert out[mfl.LABEL_OFFSET] == 3


class TestDecodeLabel:
    @pytest.mark.parametrize(
        ("bits", "name"),
        [(0, "none"), (1, "red"), (3, "yellow"), (7, "gray")],
    )
    def test_values(self, bits, name):
        assert mfl.decode_label(finder_info(bits)) == name

    def test_ignores_high_bits(self):
        assert mfl.decode_label(finder_info(2, extra_bits=0x80)) == "orange"

    def test_none_for_missing_or_short(self):
        assert mfl.decode_label(None) == "none"
        assert mfl.decode_label(b"") == "none"
        assert mfl.decode_label(b"\x00" * 10) == "none"


class TestReadFinderInfo:
    def test_parses_hex_output(self):
        expected = finder_info(4)
        run = mock.Mock(
            return_value=mock.Mock(
                returncode=0, stdout=expected.hex() + "\n", stderr=""
            )
        )
        with mock.patch.object(mfl.subprocess, "run", run):
            assert mfl.read_finder_info("/tmp/x") == expected
        args = run.call_args[0][0]
        assert args == ["xattr", "-px", mfl.FINDER_INFO_ATTR, "/tmp/x"]

    def test_missing_attribute_returns_none(self):
        run = mock.Mock(
            return_value=mock.Mock(
                returncode=1, stdout="", stderr="xattr: No such xattr"
            )
        )
        with mock.patch.object(mfl.subprocess, "run", run):
            assert mfl.read_finder_info("/tmp/x") is None


class TestWriteFinderInfo:
    def test_writes_hex(self):
        data = finder_info(3)
        run = mock.Mock(
            return_value=mock.Mock(returncode=0, stdout="", stderr="")
        )
        with mock.patch.object(mfl.subprocess, "run", run):
            mfl.write_finder_info("/tmp/x", data)
        args = run.call_args[0][0]
        assert args == ["xattr", "-wx", mfl.FINDER_INFO_ATTR, data.hex(), "/tmp/x"]

    def test_raises_on_failure(self):
        run = mock.Mock(
            return_value=mock.Mock(
                returncode=1, stdout="", stderr="xattr: Operation not permitted"
            )
        )
        with mock.patch.object(mfl.subprocess, "run", run):
            with pytest.raises(mfl.LabelError, match="Operation not permitted"):
                mfl.write_finder_info("/tmp/x", b"\x00" * 32)


class TestHighLevel:
    def test_get_label_reads_color(self):
        with mock.patch.object(
            mfl, "read_finder_info", return_value=finder_info(6)
        ):
            assert mfl.get_label("/tmp/x") == "purple"

    def test_get_label_none_when_unset(self):
        with mock.patch.object(mfl, "read_finder_info", return_value=None):
            assert mfl.get_label("/tmp/x") == "none"

    def test_set_label_creates_attribute(self):
        with mock.patch.object(
            mfl, "read_finder_info", return_value=None
        ), mock.patch.object(mfl, "write_finder_info") as write:
            assert mfl.set_label("/tmp/x", "yellow") == "yellow"
        write.assert_called_once()
        path, data = write.call_args[0]
        assert path == "/tmp/x"
        assert len(data) == mfl.FINDER_INFO_SIZE
        assert data[mfl.LABEL_OFFSET] == 3

    def test_set_label_preserves_existing_bytes(self):
        with mock.patch.object(
            mfl, "read_finder_info", return_value=finder_info(1)
        ), mock.patch.object(mfl, "write_finder_info") as write:
            mfl.set_label("/tmp/x", "gray")
        data = write.call_args[0][1]
        assert data[5] == 0xA5
        assert data[mfl.LABEL_OFFSET] == 7

    def test_clear_label_zeroes_bits_only(self):
        with mock.patch.object(
            mfl, "read_finder_info", return_value=finder_info(5, extra_bits=0x40)
        ), mock.patch.object(mfl, "write_finder_info") as write:
            mfl.clear_label("/tmp/x")
        assert write.call_args[0][1][mfl.LABEL_OFFSET] == 0x40

    def test_clear_label_noop_when_unset(self):
        with mock.patch.object(
            mfl, "read_finder_info", return_value=None
        ), mock.patch.object(mfl, "write_finder_info") as write:
            mfl.clear_label("/tmp/x")
        write.assert_not_called()
