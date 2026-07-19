import pytest

from harness.tools.files import edit_file, read_file, write_file


@pytest.fixture
def f(tmp_path):
    p = tmp_path / "sample.txt"
    p.write_text("alpha\nbeta\ngamma\nbeta\n")
    return p


def test_read_whole_file(f):
    assert read_file(path=str(f)) == "alpha\nbeta\ngamma\nbeta\n"


def test_read_offset_limit(f):
    assert read_file(path=str(f), offset=2, limit=2) == "beta\ngamma\n"


def test_read_range_past_eof(f):
    assert "no lines in range" in read_file(path=str(f), offset=99)


def test_read_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        read_file(path=str(tmp_path / "nope.txt"))


def test_write_creates_parent_dirs(tmp_path):
    target = tmp_path / "a" / "b" / "new.txt"
    out = write_file(path=str(target), content="hello")
    assert target.read_text() == "hello" and "5 characters" in out


def test_edit_unique_match(f):
    edit_file(path=str(f), old_string="gamma", new_string="delta")
    assert f.read_text() == "alpha\nbeta\ndelta\nbeta\n"


def test_edit_not_found(f):
    with pytest.raises(ValueError, match="not found"):
        edit_file(path=str(f), old_string="zeta", new_string="x")


def test_edit_ambiguous(f):
    with pytest.raises(ValueError, match="2 times"):
        edit_file(path=str(f), old_string="beta", new_string="x")


def test_edit_identical_strings_rejected(f):
    with pytest.raises(ValueError, match="identical"):
        edit_file(path=str(f), old_string="alpha", new_string="alpha")


def test_edit_replaces_only_once_even_with_context(f):
    edit_file(path=str(f), old_string="alpha\nbeta", new_string="alpha\nBETA")
    assert f.read_text() == "alpha\nBETA\ngamma\nbeta\n"
