# Conductor

A small orchestrator that pairs **two different CLI agents** in a
generate→review loop:

| Phase       | Tool          | Command used                                                        |
|-------------|---------------|---------------------------------------------------------------------|
| Generation  | **Claude Code** | `claude -p "<prompt>" --dangerously-skip-permissions --add-dir <ws>` |
| Review      | **Codex**       | `codex exec --cd <ws> --skip-git-repo-check --sandbox read-only -o <verdict>` |

Codex reviews **only after** Claude Code finishes. The next generation runs
**only after** Codex finishes. The loop repeats until the reviewer approves or
the iteration budget is hit. Every CLI's exit code is checked, and any failed
step aborts the run.

It supports two use cases via `--mode`:

1. **`code`** — code generation followed by code review.
2. **`docs`** — document generation followed by document review.

## How the loop works

```
        ┌─────────────────────────────────────────────┐
        │  cycle N (N = 1..max-iterations)             │
        │                                              │
 task ─▶ │  1. Claude Code generates/edits files  ─────┼─▶ (exit 0? else abort)
        │              │                               │
        │              ▼                               │
        │  2. Codex reviews the files ────────────────┼─▶ (exit 0? else abort)
        │              │                               │
        │              ▼                               │
        │  3. Read verdict line:                       │
        │     VERDICT: APPROVED ───────────────────────┼─▶ done ✅ (exit 0)
        │     VERDICT: CHANGES_REQUESTED               │
        │        └─ feedback fed into next cycle ──────┼─▶ loop
        └─────────────────────────────────────────────┘
   budget exhausted without approval ───────────────────▶ exit 1
```

- **Success/finish detection.** Each step's real exit code is captured
  (`0` = success). A non-zero exit aborts the whole run with a non-zero status.
  The reviewer additionally emits a machine-readable `VERDICT:` line that the
  loop greps to decide APPROVED vs. CHANGES_REQUESTED.
- **Feedback passing.** On `CHANGES_REQUESTED`, the reviewer's full message is
  saved and appended to the next generation prompt so Claude Code fixes exactly
  what was flagged.

## Prerequisites

Both CLIs must be installed, on your `PATH`, and authenticated:

```bash
claude --version   # Claude Code
codex --version    # Codex
```

Verify auth by running each once interactively if needed (`claude`, `codex`).
This repo shells out to whatever `claude` / `codex` resolve to (override with
the `CLAUDE_BIN` / `CODEX_BIN` env vars).

> ⚠️ `--dangerously-skip-permissions` lets Claude Code run tools (including file
> writes and shell) without prompting. Run this only in a directory/environment
> you trust. Codex runs the review in `--sandbox read-only` so it cannot modify
> your files.

## Usage

```bash
# Code use case
./conductor.sh --mode code \
  --task "Build a Python CLI that converts CSV to JSON, with tests." \
  --workspace ./workspace-code \
  --max-iterations 5

# Docs use case
./conductor.sh --mode docs \
  --task "Write an onboarding guide for a REST API with auth and pagination." \
  --workspace ./workspace-docs

# Task from a file
./conductor.sh --mode code --task-file ./my-task.md
```

Run `./conductor.sh --help` for all flags.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--mode <code\|docs>` | Use case (required). | — |
| `--task "<text>"` | Task description. | — |
| `--task-file <path>` | Read task from a file (alternative to `--task`). | — |
| `--workspace <dir>` | Where agents write / review. | `./workspace-<mode>` |
| `--resume <run-id>` | Resume a previous run from the next cycle (see below). | — |
| `--max-iterations <n>` | Max generate→review cycles. | `5` |
| `--claude-model <name>` | Passed to `claude --model`. | CLI default |
| `--codex-model <name>` | Passed to `codex exec -m`. | CLI default |

Environment: `CLAUDE_BIN`, `CODEX_BIN` override the binaries.

### Resuming a run

Every cycle writes a `run.json` manifest into the run directory recording the
run's `mode`, `workspace`, `spec` path, `last_completed_cycle`, and
`last_verdict`. If a run stops before approval, resume it with its run-id (the
`runs/` subdirectory basename):

```bash
./conductor.sh --resume code-20260904-212128
```

This reuses that run's `spec.md`, workspace, and `feedback.txt`, and continues
the generate→review loop from the cycle **after** the last one that completed
(`last_completed_cycle + 1`). The spec stage never re-runs on resume — the
existing spec is reused as-is.

- `--resume` is mutually exclusive with `--mode`, `--task`, `--task-file`,
  `--repo`, and `--workspace` (all recovered from the manifest); supplying any
  of them aborts.
- The original `max_iterations` is honored unless you pass `--max-iterations`
  on the resume invocation to raise the budget.
- Resuming a run that already ended `APPROVED` is a no-op success (exit 0).
- Resuming a run whose budget is already exhausted exits 1 unless
  `--max-iterations` raises it.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Reviewer approved within the iteration budget. |
| `1`  | Budget exhausted without approval (artifacts still produced). |
| `>1` | A CLI step failed — see the logs. |

## Output layout

- **Artifacts** land in the workspace (`--workspace`).
- **Logs & verdicts** land in `runs/<mode>-<timestamp>/`:
  - `cycleN-generate.log` — Claude Code output
  - `cycleN-review.log` — Codex output
  - `cycleN-review-verdict.txt` — reviewer's final message (contains `VERDICT:`)
  - `feedback.txt` — feedback carried into the next cycle
  - `run.json` — resume manifest (mode, workspace, spec, `last_completed_cycle`,
    `last_verdict`, …), rewritten every cycle and consumed by `--resume`

## Customizing behavior

Prompt templates live in `prompts/` — edit them to change how each agent
behaves:

- `code_generate.md`, `code_review.md`
- `docs_generate.md`, `docs_review.md`

## Repository layout

```
conductor/
├── conductor.sh        # the orchestrator loop
├── lib/common.sh       # logging + exit-code capture helpers
├── prompts/            # generation & review prompt templates
├── examples/           # ready-to-run example invocations
├── runs/               # per-run logs & verdicts (gitignored)
└── README.md
```
