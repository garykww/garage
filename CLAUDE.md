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

| Detection file | Language | Commands |
|---|---|---|
| `ci.sh` | Custom | `bash ci.sh` |
| `package.json` | Node.js | install (lock-file-aware) → `npm test --if-present` → `npm run build --if-present` |
| `pyproject.toml` / `requirements.txt` / `setup.py` | Python | venv → install deps → `pytest --tb=short` (unittest fallback) |
| `go.mod` | Go | `go build ./... && go test ./...` |
| `Cargo.toml` | Rust | `cargo build && cargo test` |
| `pom.xml` | Maven | `mvn --no-transfer-progress verify` |
| `build.gradle` / `build.gradle.kts` | Gradle | `./gradlew build` (falls back to `gradle build`) |
| `Makefile` / `makefile` / `GNUmakefile` | Generic | `make build \|\| make all \|\| make` |
| _(none of the above)_ | Unknown | logs `ls -la`, exits 0 |

#### Node.js — lock-file behavior

| Lock file | Installer |
|---|---|
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` (pnpm bootstrapped via npm) |
| _(none)_ | `npm install` |

#### Python — venv and extras

CI creates `.venv/` inside the app folder and activates it before installing.

- `pyproject.toml` → `pip install -e ".[dev]"`, fallback to `pip install -e .`
- `requirements.txt` → `pip install -r requirements.txt` (+ `requirements-dev.txt` if present)
- `setup.py` only → `pip install -e .`
- Test runner: `pytest --tb=short`, fallback to `unittest discover`

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

## .gitignore Scope

These paths are git-ignored across all apps — never commit them and skip them when reading source:

| Category | Ignored paths |
|---|---|
| OS artifacts | `.DS_Store`, `._*`, `Thumbs.db` |
| Editor / IDE | `.vscode/`, `.idea/`, `*.swp`, `*~` |
| Node.js | `node_modules/`, `.next/`, `.nuxt/`, `.cache/`, debug logs |
| Python | `__pycache__/`, `.venv/`, `venv/`, `env/`, `*.egg-info/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/` |
| Go | `/go/bin/` |
| Rust | `target/` |
| Java | `*.class`, `*.jar`, `.gradle/` |
| Build outputs | `dist/`, `build/` |
| Secrets | `.env`, `.env.*` (except `.env.example`), `*.pem`, `*.key` |

## Branch Naming

Branches follow the pattern `claude/<kebab-description>-<5-char-id>`.
Example: `claude/add-claude-documentation-rv8YO`.

Use this format when creating branches. The suffix prevents collisions between concurrent sessions.

## Tips for Claude

- When creating a new app, only create files inside that app's folder.
- Never modify another app's files in the same branch/PR.
- If asked to add CI for a specific language not in the auto-detection list, add a `ci.sh` inside that app folder — do **not** edit `.github/workflows/app-ci.yml` unless adding a new language to the global detection logic.
- The `pr-scope-check` workflow will block you if you accidentally touch multiple app folders in one commit chain.
- Python CI creates `.venv/` inside the app folder automatically — do not commit it (already gitignored).
- For Node.js apps using pnpm or yarn, commit the lock file (`pnpm-lock.yaml` or `yarn.lock`) to get a frozen deterministic install in CI.
- An app with no recognized build file is not a CI failure — the workflow logs the directory and exits 0. Add `ci.sh` or a standard build file for real CI.
