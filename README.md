# garage

A polyglot monorepo for throwaway prototypes and experiments.

Each top-level directory is a self-contained app in any language or framework.
No per-app configuration needed — create a folder and push.

## Structure

```
garage/
├── my-node-app/        # any language / framework
│   ├── package.json
│   └── ...
├── my-python-api/
│   ├── pyproject.toml
│   └── ...
├── my-go-service/
│   ├── go.mod
│   └── ...
└── ...
```

## Checking Out a Single App

To clone only one app folder without downloading the entire repo:

```bash
git clone --filter=blob:none --sparse https://github.com/garykww/garage.git
cd garage
git sparse-checkout set vllm
```

To add another app folder to an existing sparse checkout:

```bash
git sparse-checkout add another-app-name
```

To go back to a full checkout:

```bash
git sparse-checkout disable
```

## Adding a New App

1. Create a top-level folder (prefer kebab-case, no spaces).
2. Add your code.
3. Open a PR — CI detects and runs automatically. No workflow changes needed.

## CI / CD

GitHub Actions detects which app folder changed and runs its pipeline.

### Automatic Framework Detection

If the app folder does **not** contain a `ci.sh`, the pipeline inspects the folder
and runs standard build+test commands for the first matching framework:

| Detection file | Framework | Commands run |
|---|---|---|
| `ci.sh` | Custom | `bash ci.sh` |
| `package.json` | Node.js | `npm ci && npm test && npm run build` |
| `pyproject.toml` / `requirements.txt` / `setup.py` | Python | `pip install` + `pytest` |
| `go.mod` | Go | `go build ./... && go test ./...` |
| `Cargo.toml` | Rust | `cargo build && cargo test` |
| `pom.xml` | Java (Maven) | `mvn verify` |
| `build.gradle` / `build.gradle.kts` | Java (Gradle) | `./gradlew build` |
| `Makefile` | Generic | `make build \|\| make all \|\| make` |
| _(none)_ | Unknown | Lists directory contents, exits 0 |

### Custom CI (`ci.sh`)

Drop a `ci.sh` at your app root to fully control what runs:

```bash
#!/usr/bin/env bash
set -euo pipefail

docker build -t myapp .
docker run --rm myapp ./run-tests.sh
```

The script runs with the app folder as the working directory.
Exit 0 = success, non-zero = failure.

## PR Rules

- **One app per PR.** A PR touching more than one top-level app folder is
  automatically blocked by the `pr-scope-check` workflow.
- Changes to root-level files (`.gitignore`, `README.md`) and `.github/` are
  excluded from the scope check.
- To update multiple apps, open separate PRs — one per app.

## Workflows

| File | Trigger | Purpose |
|---|---|---|
| `.github/workflows/pr-scope-check.yml` | `pull_request` | Fails if PR touches > 1 app folder |
| `.github/workflows/app-ci.yml` | `pull_request`, `push → main` | Detects changed app and runs its CI |
