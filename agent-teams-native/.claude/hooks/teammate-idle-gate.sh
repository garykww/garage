#!/usr/bin/env bash
# TeammateIdle gate: don't let a teammate go idle while go vet is unhappy.
# Exiting 2 sends the vet output back to the teammate and keeps it working.
# Deliberately gentler than the TaskCompleted gate — it fires for every
# teammate, including ones (security-auditor) that never edit code, so it
# only checks static analysis, not the full test suite.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1

if ! out=$(go vet ./... 2>&1); then
  echo "go vet ./... reports problems. Address them (or flag them to the lead if they're outside your module) before going idle:" >&2
  echo "$out" >&2
  exit 2
fi

exit 0
