"""The bash tool: run a shell command, fresh process per call (ADR 0006)."""

from __future__ import annotations

import subprocess

from .registry import tool

TIMEOUT_SECONDS = 60


@tool(
    description=(
        "Run a shell command and return its output. Each call runs in a fresh "
        "shell: cd and environment variables do not persist between calls — "
        "use absolute paths or chain commands with &&. Commands time out "
        f"after {TIMEOUT_SECONDS} seconds."
    ),
    parameters={
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "The shell command to execute.",
            },
        },
        "required": ["command"],
    },
)
def bash(command: str) -> str:
    try:
        proc = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return f"error: command timed out after {TIMEOUT_SECONDS}s: {command}"

    parts = []
    if proc.stdout:
        parts.append(proc.stdout.rstrip("\n"))
    if proc.stderr:
        parts.append(f"stderr:\n{proc.stderr.rstrip()}" if parts else proc.stderr.rstrip("\n"))
    if proc.returncode != 0:
        parts.append(f"(exit code {proc.returncode})")
    return "\n".join(parts) if parts else "(no output)"
