from pathlib import Path

from harness.prompt import build_system_prompt


def test_contains_environment_facts():
    p = build_system_prompt(Path("/some/dir"))
    assert "/some/dir" in p
    assert "fresh shell" in p
    assert "20" in p  # the date made it in


def test_relative_workdir_resolved():
    assert str(Path.cwd()) in build_system_prompt(".")


def test_project_notes_appended():
    p = build_system_prompt("/w", project_notes="Always use tabs.")
    assert "AGENTS.md" in p and "Always use tabs." in p


def test_empty_project_notes_omitted():
    assert "AGENTS.md" not in build_system_prompt("/w", project_notes="  \n")
