# CLAUDE.md — garage

## Repo Purpose

This is a polyglot monorepo for throwaway prototypes and experiments.
Each top-level directory is one self-contained app in any language or framework.

## Structure Rules

- **One folder = one app.** Never put shared code in the root or in a shared library folder unless it is itself treated as an app.
- **Folder naming:** kebab-case, descriptive, no spaces. Example: `image-resize-api`, `csv-diff-tool`.
- **Each folder is fully self-contained.** No cross-folder imports or dependencies.

## Adding a New App

1. Create a top-level folder.
2. Put all code inside it.
3. Open a PR — CI runs automatically.

Do **not** touch `.github/workflows/` when adding an app. The workflows are language-agnostic.

## CI Conventions

### Custom CI (`ci.sh`)

Place a `ci.sh` at the root of an app folder to fully control what runs in CI.
The script runs with that folder as the working directory. Must exit 0 on success.

```bash
#!/usr/bin/env bash
set -euo pipefail
npm ci
npm test
```

### Auto-detection (no `ci.sh`)

The `app-ci` workflow fingerprints the folder and runs the standard build/test
command for the first match, in this priority:

| File | Language | Commands |
|---|---|---|
| `ci.sh` | Custom | `bash ci.sh` |
| `package.json` | Node.js | `npm ci && npm test && npm run build` |
| `pyproject.toml` / `requirements.txt` / `setup.py` | Python | `pip install` + `pytest` |
| `go.mod` | Go | `go build ./... && go test ./...` |
| `Cargo.toml` | Rust | `cargo build && cargo test` |
| `pom.xml` | Maven | `mvn verify` |
| `build.gradle` / `build.gradle.kts` | Gradle | `./gradlew build` |
| `Makefile` | Generic | `make build \|\| make all \|\| make` |

## PR Rules

- **One app per PR.** The `pr-scope-check` workflow blocks any PR that modifies
  files in more than one top-level app folder.
- `.github/` changes and root-level file edits (`.gitignore`, `README.md`) are
  exempt from the scope check and can be combined freely.

## Workflows

| File | When it runs | What it does |
|---|---|---|
| `.github/workflows/pr-scope-check.yml` | Every PR to `main` | Fails if > 1 app folder is touched |
| `.github/workflows/app-ci.yml` | PRs to `main` + push to `main` | Detects changed app → runs its CI |

## Tips for Claude

- When creating a new app, only create files inside that app's folder.
- Never modify another app's files in the same branch/PR.
- If asked to add CI for a specific language not in the auto-detection list, add a `ci.sh` inside that app folder — do **not** edit `.github/workflows/app-ci.yml` unless adding a new language to the global detection logic.
- The `pr-scope-check` workflow will block you if you accidentally touch multiple app folders in one commit chain.
