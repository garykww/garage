#!/usr/bin/env bash
# TaskCompleted quality gate: a task may only be marked complete while the
# whole module builds and every test passes. Exiting 2 blocks the
# completion and feeds stderr back to the agent as instructions — this is
# the enforced version of the honor-system rule in the sibling
# subagent-teams app ("verify the report references a passing test").
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1

if ! out=$(go build ./... 2>&1); then
  echo "Blocked: go build ./... is failing. Fix the build before marking this task complete." >&2
  echo "$out" >&2
  exit 2
fi

if ! out=$(go test ./... 2>&1); then
  echo "Blocked: go test ./... is failing. Make the suite green before marking this task complete." >&2
  echo "$out" >&2
  exit 2
fi

exit 0
