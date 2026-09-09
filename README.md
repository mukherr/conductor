# Conductor

A small orchestrator that pairs **three different CLI agents** — an optional
up-front spec/plan stage feeding a generate→review loop:

| Phase       | Tool          | Command used                                                        |
|-------------|---------------|---------------------------------------------------------------------|
| Spec/plan (optional) | **Kiro CLI** | `kiro-cli chat --no-interactive --trust-all-tools "/spec new <name> …"` |
| Generation  | **Claude Code** | `claude -p "<prompt>" --dangerously-skip-permissions --add-dir <ws>` |
| Review      | **Codex**       | `codex exec --cd <ws> --skip-git-repo-check --sandbox read-only -o <verdict>` |

An optional **spec stage** runs first (see [Spec stage](#spec-stage-kiro)):
Kiro's built-in Spec mode turns the task into requirements/design/tasks
artifacts that are collected into a single `spec.md` and fed to both later
agents. Then Codex reviews **only after** Claude Code finishes, and the next
generation runs **only after** Codex finishes. The loop repeats until the
reviewer approves or the iteration budget is hit. Every CLI's exit code is
checked, and any failed step aborts the run.

It supports two use cases via `--mode`:

1. **`code`** — code generation followed by code review.
2. **`docs`** — document generation followed by document review.

## How the loop works

```
 task ─▶ [ optional Kiro spec/plan stage ] ─▶ spec.md ─┐
                                                       │ (feeds every cycle)
        ┌──────────────────────────────────────────────▼┐
        │  cycle N (N = 1..max-iterations)             │
        │                                              │
        │  1. Claude Code generates/edits files  ─────┼─▶ (exit 0? else abort)
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

The CLIs must be installed, on your `PATH`, and authenticated:

```bash
claude --version     # Claude Code (generation)
codex --version      # Codex (review)
kiro-cli --version   # Kiro CLI (spec stage — only needed when a spec runs)
```

Verify auth by running each once interactively if needed (`claude`, `codex`,
`kiro-cli`). This repo shells out to whatever `claude` / `codex` / `kiro-cli`
resolve to (override with the `CLAUDE_BIN` / `CODEX_BIN` / `KIRO_BIN` env vars).
Kiro is required only when the spec stage actually runs — for simple tasks that
skip it, `claude` and `codex` alone are enough.

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

# Force the Kiro spec/plan stage up front (otherwise auto-decided per task)
./conductor.sh --mode code \
  --task "Design and build a rate limiter service with tests." \
  --spec --kiro-effort high
```

Run `./conductor.sh --help` for all flags.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--mode <code\|docs>` | Use case (required). | — |
| `--task "<text>"` | Task description. | — |
| `--task-file <path>` | Read task from a file (alternative to `--task`). | — |
| `--repo <path\|git-url>` | Work inside an existing repo (local path in place; git URL cloned into `runs/`). Overrides `--workspace`. | — |
| `--workspace <dir>` | Where agents write / review. Ignored when `--repo` set. | `./workspace-<mode>` |
| `--spec` | Always run the Kiro spec/plan stage (see below). | auto |
| `--kiro-effort <level>` | Kiro reasoning effort for the spec stage (`low\|medium\|high\|xhigh\|max`, passed as `--effort`). | CLI default |
| `--resume <run-id>` | Resume a previous run from the next cycle (see below). | — |
| `--max-iterations <n>` | Max generate→review cycles. | `5` |
| `--claude-model <name>` | Passed to `claude --model`. | CLI default |
| `--codex-model <name>` | Passed to `codex exec -m`. | CLI default |

Environment: `CLAUDE_BIN`, `CODEX_BIN`, `KIRO_BIN` override the binaries.

### Spec stage (Kiro)

Before the loop, Conductor can run an up-front **spec/plan stage** with the
[Kiro CLI](https://kiro.dev). It launches a headless `kiro-cli chat` session in
the workspace and drives Kiro's built-in **Spec mode** (`/spec new <name>`),
which writes artifacts (`requirements.md`, `design.md`, `tasks.md`, …) under
`.kiro/specs/<name>/`. Conductor collects every markdown artifact into a single
`spec.md` in the run directory, and both the generation and review prompts
consume it so Claude and Codex work against the same agreed plan.

When it runs:

- **`--spec`** — always run the spec stage.
- **auto (default)** — an LLM classifies the task (using the task text and the
  current workspace, if present) as `SIMPLE` or `COMPLEX`; the spec stage runs
  only for `COMPLEX` tasks. If no verdict can be parsed, it is skipped.
- **`--resume`** — the spec stage never re-runs; the prior run's `spec.md` is
  reused as-is.

Because the session is headless (`--no-interactive --trust-all-tools`), Kiro
picks the spec type itself, drives every phase without pausing, and writes only
to `.kiro/specs/<name>/` — it does not execute the tasks. Tune its reasoning
budget with `--kiro-effort`. If Kiro fails or produces no artifacts, the run
aborts (see `runs/<run>/spec.log`).

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
  - `spec.log` — Kiro spec-stage output (only when the spec stage runs)
  - `spec.md` — collected Kiro spec artifacts fed to both agents (only when the
    spec stage runs)
  - `complexity.log` — LLM complexity verdict (only in auto mode)
  - `cycleN-generate.log` — Claude Code output
  - `cycleN-review.log` — Codex output
  - `cycleN-review-verdict.txt` — reviewer's final message (contains `VERDICT:`)
  - `feedback.txt` — feedback carried into the next cycle
  - `run.json` — resume manifest (mode, workspace, spec, `last_completed_cycle`,
    `last_verdict`, …), rewritten every cycle and consumed by `--resume`

## Customizing behavior

Prompt templates live in `prompts/` — edit them to change how each agent
behaves:

- `code_spec.md`, `code_generate.md`, `code_review.md`
- `docs_spec.md`, `docs_generate.md`, `docs_review.md`

(The `*_spec.md` templates drive the Kiro spec stage for each mode.)

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
