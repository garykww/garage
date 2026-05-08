# ai-agent-personas

A collection of reusable AI agent personas for common software engineering roles. Each persona is defined as a standalone `agent.md` system prompt covering role, responsibilities, output structure, rules, and an example prompt.

## Personas

| Folder | Role |
|---|---|
| `architect/` | Designs system structure, evaluates trade-offs, writes ADRs |
| `code-reviewer/` | Reviews PRs for correctness, clarity, and test coverage |
| `debugger/` | Investigates failures and proposes targeted root-cause fixes |
| `devops-engineer/` | Builds CI/CD pipelines, IaC, and observability systems |
| `documentation-writer/` | Writes READMEs, API references, and runbooks |
| `onboarding-assistant/` | Guides new engineers through an unfamiliar codebase |
| `performance-engineer/` | Profiles bottlenecks and applies measured optimizations |
| `refactoring-specialist/` | Improves code structure without changing behavior |
| `security-auditor/` | Audits code for vulnerabilities with severity ratings and remediations |
| `test-engineer/` | Designs and writes unit, integration, and end-to-end tests |

## Usage

Each `agent.md` is self-contained. Copy its contents into the system prompt of any AI agent or chat session to activate that persona.

```
ai-agent-personas/
└── <persona-name>/
    └── agent.md    ← paste this into your system prompt
```

The root `personas.json` provides a machine-readable index of all personas with metadata (description, responsibilities, tone, example prompt) for programmatic use.

## Structure of each agent.md

- **Role** — one-paragraph definition of what this agent does
- **Responsibilities** — concrete tasks the agent is expected to perform
- **Tone & Style** — how it communicates and structures its output
- **Rules** — explicit constraints on behavior
- **Example Prompt** — a ready-to-use prompt to invoke the persona
