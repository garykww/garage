from harness.tools.bash import bash


def test_stdout():
    assert bash(command="echo hello") == "hello"


def test_exit_code_reported_not_raised():
    out = bash(command="exit 3")
    assert "(exit code 3)" in out


def test_stderr_captured():
    out = bash(command="echo oops >&2")
    assert "oops" in out


def test_no_output():
    assert bash(command="true") == "(no output)"


def test_fresh_process_no_state():
    bash(command="export MARKER=1")
    assert "MARKER" not in bash(command="env | grep MARKER || echo unset")
