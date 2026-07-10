"""Milestone 4 gate: the agent can make a code change (ADR 0007, 0008).

- edit_only_bugfix: no bash in the registry, so the fix must go through
  read_file/edit_file — exercises the string-replace path. Graded by
  running the fixed code mechanically in the test.
- fix_until_tests_pass: full toolset; the agent must run the test file,
  read the failure, fix the source, and re-run. Graded by the test file
  exiting 0 afterwards.
"""

import subprocess
import sys

import pytest

from harness.tools.bash import bash
from harness.tools.files import FILE_TOOLS

BUGGY_FIB = '''\
def fib(n):
    """Return the n-th Fibonacci number (fib(0)=0, fib(1)=1)."""
    if n < 2:
        return n
    return fib(n - 1) - fib(n - 2)
'''

BUGGY_SLUG = '''\
def slugify(title):
    """Lowercase, words joined by single hyphens, no leading/trailing hyphens."""
    return title.replace(" ", "-")
'''

SLUG_TESTS = '''\
from slug import slugify

assert slugify("Hello World") == "hello-world", slugify("Hello World")
assert slugify("  A  B  ") == "a-b", slugify("  A  B  ")
print("all tests passed")
'''


def run_python(*args, cwd):
    return subprocess.run([sys.executable, *args], cwd=cwd, capture_output=True, text=True, timeout=30)


def test_edit_only_bugfix(agent_factory, tmp_path):
    (tmp_path / "fib.py").write_text(BUGGY_FIB)
    agent = agent_factory(FILE_TOOLS)  # no bash: must use read_file/edit_file
    result = agent.run(
        f"The function in {tmp_path}/fib.py has a bug — it does not match its "
        "docstring. Find and fix it with the smallest possible edit."
    )
    assert result.stop_reason == "done", result
    check = run_python("-c", "from fib import fib; assert fib(10) == 55; print('ok')", cwd=tmp_path)
    assert check.returncode == 0, check.stderr
    # the fix must have gone through edit_file, not a rewrite
    edits = [m for m in agent.messages if m["role"] == "tool" and m["content"].startswith("edited")]
    assert edits, "expected at least one successful edit_file call"


def test_fix_until_tests_pass(agent_factory, tmp_path):
    (tmp_path / "slug.py").write_text(BUGGY_SLUG)
    (tmp_path / "test_slug.py").write_text(SLUG_TESTS)
    agent = agent_factory([bash, *FILE_TOOLS], max_turns=12)
    result = agent.run(
        f"cd is not persistent, work with absolute paths. Run "
        f"`python3 {tmp_path}/test_slug.py` — it fails. Fix {tmp_path}/slug.py "
        "(not the tests) until the tests pass, and confirm by re-running them."
    )
    assert result.stop_reason == "done", result
    check = run_python("test_slug.py", cwd=tmp_path)
    assert check.returncode == 0, f"stdout={check.stdout} stderr={check.stderr}"
    assert "assert" in (tmp_path / "test_slug.py").read_text(), "tests must not be gutted"
