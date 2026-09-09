#!/usr/bin/env bash
#
# Conductor orchestrator.
#
# Default pipeline (unchanged): alternates two CLIs in a loop:
#   1. GENERATION  -> Claude Code   (`claude -p ... --dangerously-skip-permissions`)
#   2. REVIEW      -> Codex         (`codex exec ...`)
#
# Up-front SPEC stage (Kiro CLI Spec mode): a headless `kiro-cli chat` session
# driven with `/spec new <name>` generates the spec artifacts under
# .kiro/specs/<name>/, which are collected into one spec/plan that both the
# generator and reviewer then work against.
#   --spec        -> ALWAYS run the spec stage.
#   (no --spec)   -> an LLM classifies the task (and the current workspace, if
#                    one is present) as COMPLEX or SIMPLE, and runs the spec
#                    stage only for COMPLEX tasks; SIMPLE tasks go straight to
#                    the classic Claude+Codex generate->review loop.
#
# Codex runs only after Claude Code finishes; the next generation runs only
# after Codex finishes. The loop repeats until the reviewer approves
# (VERDICT: APPROVED) or --max-iterations is reached. Every step's exit code
# is checked, and a failed CLI aborts the run.
#
# Works for two use cases (selected with --mode):
#   code  -> code generation followed by code review
#   docs  -> document generation followed by document review
#
# Tasks can target an existing repository with --repo (a local path or a git
# URL to clone); the agents then read and modify that repo in place, which suits
# feature requests and bug fixes.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---- defaults ------------------------------------------------------------
MODE=""
TASK=""
TASK_FILE=""
WORKSPACE_ARG=""
REPO=""
MAX_ITERS=5
MAX_ITERS_SET=0
RESUME_ID=""
START_ITER=1
SPEC_MODE=0
CLAUDE_MODEL=""
CODEX_MODEL=""
KIRO_EFFORT=""
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
KIRO_BIN="${KIRO_BIN:-kiro-cli}"

usage() {
  cat <<'EOF'
Conductor: Claude Code (generate) + Codex (review), looped.
Optional Kiro CLI spec/plan stage up front for complex tasks (--spec).

Usage:
  ./conductor.sh --mode <code|docs> --task "<what to build>" [options]
  ./conductor.sh --mode <code|docs> --task-file <path>       [options]

Required:
  --mode <code|docs>       Use case: code generation or document generation.
  --task "<text>"          The task description (or use --task-file).
  --task-file <path>       Read the task description from a file.

Options:
  --repo <path|git-url>    Work inside an existing repository. A local path is
                           used in place; a git URL is cloned into runs/. The
                           agents read and modify this repo directly (good for
                           feature requests / bug fixes). Overrides --workspace.
  --workspace <dir>        Output directory the agents write to / review.
                           Default: ./workspace-<mode>. Ignored when --repo set.
  --spec                   Always run the Kiro spec/plan stage. Without --spec,
                           an LLM decides per task (using the task text and the
                           current workspace, if present) whether to run it.
  --resume <run-id>        Resume a previous run (the runs/ subdirectory
                           basename, e.g. code-20260904-212128). Reuses that
                           run's spec.md, workspace, and feedback.txt and
                           continues the generate->review loop from the next
                           cycle. Mutually exclusive with --mode, --task,
                           --task-file, --repo, and --workspace (all recovered
                           from the run's run.json manifest). --max-iterations
                           may be supplied to raise the original budget.
  --max-iterations <n>     Max generate->review cycles before giving up. Default: 5
  --claude-model <name>    Override Claude model (passed as --model).
  --codex-model <name>     Override Codex model (passed as -m).
  --kiro-effort <level>    Kiro reasoning effort for the spec stage
                           (low|medium|high|xhigh|max; passed as --effort).
  -h, --help               Show this help.

Environment:
  CLAUDE_BIN / CODEX_BIN / KIRO_BIN
                           Override the CLI binaries
                           (default: claude / codex / kiro-cli).

Exit status:
  0  reviewer approved within the iteration budget
  1  budget exhausted without approval (artifacts still produced)
  >1 a CLI step failed (see logs under runs/)
EOF
}

# ---- arg parsing ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)           MODE="${2:-}"; shift 2;;
    --task)           TASK="${2:-}"; shift 2;;
    --task-file)      TASK_FILE="${2:-}"; shift 2;;
    --repo)           REPO="${2:-}"; shift 2;;
    --workspace)      WORKSPACE_ARG="${2:-}"; shift 2;;
    --spec)           SPEC_MODE=1; shift;;
    --resume)         RESUME_ID="${2:-}"; shift 2;;
    --max-iterations) MAX_ITERS="${2:-}"; MAX_ITERS_SET=1; shift 2;;
    --claude-model)   CLAUDE_MODEL="${2:-}"; shift 2;;
    --codex-model)    CODEX_MODEL="${2:-}"; shift 2;;
    --kiro-effort)    KIRO_EFFORT="${2:-}"; shift 2;;
    -h|--help)        usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)";;
  esac
done

# RESUME_START_VERDICT records the last_verdict recovered from the manifest so
# the resumed loop's first generation prompt keeps the reused feedback in play.
RESUME_START_VERDICT=""

# ---- validation & run setup ----------------------------------------------
# Two paths: a fresh run (no --resume) validates the CLI-supplied task and
# creates a new timestamped run directory; a resumed run (--resume <run-id>)
# rehydrates all of that state from the previous run's run.json manifest and
# continues its loop from the next cycle.
if [[ -z "$RESUME_ID" ]]; then
  # ---- fresh run ---------------------------------------------------------
  [[ -n "$MODE" ]] || { usage; die "Missing --mode"; }
  [[ "$MODE" == "code" || "$MODE" == "docs" ]] || die "--mode must be 'code' or 'docs'"

  if [[ -n "$TASK_FILE" ]]; then
    [[ -f "$TASK_FILE" ]] || die "--task-file not found: $TASK_FILE"
    TASK="$(cat "$TASK_FILE")"
  fi
  [[ -n "$TASK" ]] || die "Provide a task with --task or --task-file"

  [[ "$MAX_ITERS" =~ ^[1-9][0-9]*$ ]] || die "--max-iterations must be a positive integer"

  if [[ -n "$KIRO_EFFORT" ]]; then
    [[ "$KIRO_EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]] \
      || die "--kiro-effort must be one of: low|medium|high|xhigh|max"
  fi

  require_cmd "$CLAUDE_BIN"
  require_cmd "$CODEX_BIN"

  GEN_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_generate.md"
  REVIEW_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_review.md"
  SPEC_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_spec.md"
  [[ -f "$GEN_PROMPT_FILE"    ]] || die "Missing prompt template: $GEN_PROMPT_FILE"
  [[ -f "$REVIEW_PROMPT_FILE" ]] || die "Missing prompt template: $REVIEW_PROMPT_FILE"

  RUN_ID="$(date +%Y%m%d-%H%M%S)"
  RUN_LABEL="$MODE-$RUN_ID"
  RUN_DIR="$SCRIPT_DIR/runs/$RUN_LABEL"
  mkdir -p "$RUN_DIR"

  # ---- resolve the working directory (repo vs. workspace) --------------
  if [[ -n "$REPO" ]]; then
    [[ -n "$WORKSPACE_ARG" ]] && warn "--repo given; ignoring --workspace."
    if [[ "$REPO" =~ ^(https?|git|ssh):// || "$REPO" == git@* || "$REPO" == *.git ]]; then
      require_cmd git
      WORKSPACE="$RUN_DIR/repo"
      log "Cloning repo: $REPO"
      git clone "$REPO" "$WORKSPACE" || die "git clone failed: $REPO"
    else
      [[ -d "$REPO" ]] || die "--repo not found (not a directory or recognized git URL): $REPO"
      WORKSPACE="$REPO"
    fi
  else
    WORKSPACE="${WORKSPACE_ARG:-$SCRIPT_DIR/workspace-$MODE}"
    mkdir -p "$WORKSPACE"
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"

  # Kiro's `/spec` command writes its artifacts under .kiro/specs/<name>/ in
  # the working directory. We drive it with a run-scoped spec name, then
  # collect those artifacts into SPEC_FILE for the downstream prompts.
  SPEC_NAME="conductor-$MODE-$RUN_ID"
  SPEC_DIR="$WORKSPACE/.kiro/specs/$SPEC_NAME"
  SPEC_FILE="$RUN_DIR/spec.md"   # populated only if the Kiro spec stage runs
  FEEDBACK_FILE="$RUN_DIR/feedback.txt"
  START_ITER=1

  log "Mode:        $MODE"
  log "Workspace:   $WORKSPACE${REPO:+  (repo)}"
  log "Max cycles:  $MAX_ITERS"
  log "Spec stage:  $([[ "$SPEC_MODE" -eq 1 ]] && echo 'forced (--spec)' || echo 'auto (LLM decides)')"
  log "Run logs:    $RUN_DIR"
else
  # ---- resumed run -------------------------------------------------------
  # --resume recovers everything from the manifest; supplying any of the
  # state-defining flags would be ambiguous, so reject them outright.
  conflicts=()
  [[ -n "$MODE"          ]] && conflicts+=(--mode)
  [[ -n "$TASK"          ]] && conflicts+=(--task)
  [[ -n "$TASK_FILE"     ]] && conflicts+=(--task-file)
  [[ -n "$REPO"          ]] && conflicts+=(--repo)
  [[ -n "$WORKSPACE_ARG" ]] && conflicts+=(--workspace)
  [[ "${#conflicts[@]}" -eq 0 ]] \
    || die "--resume cannot be combined with: ${conflicts[*]} (all recovered from run.json)"

  if [[ -n "$KIRO_EFFORT" ]]; then
    [[ "$KIRO_EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]] \
      || die "--kiro-effort must be one of: low|medium|high|xhigh|max"
  fi

  RUN_LABEL="$RESUME_ID"
  RUN_ID="$RESUME_ID"
  RUN_DIR="$SCRIPT_DIR/runs/$RESUME_ID"
  [[ -d "$RUN_DIR" ]] || die "--resume: run directory not found: $RUN_DIR"
  MANIFEST_FILE="$RUN_DIR/run.json"
  [[ -f "$MANIFEST_FILE" ]] || die "--resume: manifest not found: $MANIFEST_FILE"

  MODE="$(manifest_get "$MANIFEST_FILE" mode)"
  WORKSPACE="$(manifest_get "$MANIFEST_FILE" workspace)"
  TASK="$(manifest_get "$MANIFEST_FILE" task)"
  REPO="$(manifest_get "$MANIFEST_FILE" repo)"
  local_spec="$(manifest_get "$MANIFEST_FILE" spec)"
  FEEDBACK_FILE="$(manifest_get "$MANIFEST_FILE" feedback)"
  [[ -n "$FEEDBACK_FILE" ]] || FEEDBACK_FILE="$RUN_DIR/feedback.txt"
  last_completed_cycle="$(manifest_get "$MANIFEST_FILE" last_completed_cycle)"
  RESUME_START_VERDICT="$(manifest_get "$MANIFEST_FILE" last_verdict)"
  manifest_max="$(manifest_get "$MANIFEST_FILE" max_iterations)"

  [[ "$MODE" == "code" || "$MODE" == "docs" ]] \
    || die "--resume: manifest has an invalid mode: '$MODE'"
  [[ "$last_completed_cycle" =~ ^[0-9]+$ ]] \
    || die "--resume: manifest last_completed_cycle is not a non-negative integer: '$last_completed_cycle'"

  # --max-iterations on the resume invocation overrides the recorded budget.
  if [[ "$MAX_ITERS_SET" -eq 1 ]]; then
    [[ "$MAX_ITERS" =~ ^[1-9][0-9]*$ ]] || die "--max-iterations must be a positive integer"
  else
    MAX_ITERS="$manifest_max"
    [[ "$MAX_ITERS" =~ ^[1-9][0-9]*$ ]] \
      || die "--resume: manifest max_iterations is not a positive integer: '$MAX_ITERS'"
  fi

  require_cmd "$CLAUDE_BIN"
  require_cmd "$CODEX_BIN"

  GEN_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_generate.md"
  REVIEW_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_review.md"
  SPEC_PROMPT_FILE="$SCRIPT_DIR/prompts/${MODE}_spec.md"
  [[ -f "$GEN_PROMPT_FILE"    ]] || die "Missing prompt template: $GEN_PROMPT_FILE"
  [[ -f "$REVIEW_PROMPT_FILE" ]] || die "Missing prompt template: $REVIEW_PROMPT_FILE"

  [[ -d "$WORKSPACE" ]] || die "--resume: recorded workspace no longer exists: $WORKSPACE"

  # Reuse the recorded spec.md (append_context tests it with -s); if the
  # original run produced no spec, point SPEC_FILE at a path that will not
  # exist so no spec context is injected.
  SPEC_FILE="${local_spec:-$RUN_DIR/spec.md}"
  SPEC_NAME="conductor-$MODE-$RUN_ID"
  SPEC_DIR="$WORKSPACE/.kiro/specs/$SPEC_NAME"

  START_ITER=$((last_completed_cycle + 1))

  log "Resuming:    $RESUME_ID"
  log "Mode:        $MODE"
  log "Workspace:   $WORKSPACE${REPO:+  (repo)}"
  log "Spec reused: $([[ -s "$SPEC_FILE" ]] && echo "yes ($SPEC_FILE)" || echo 'no')"
  log "Last cycle:  $last_completed_cycle (verdict: ${RESUME_START_VERDICT:-none})"
  log "Start cycle: $START_ITER"
  log "Max cycles:  $MAX_ITERS"
  log "Run logs:    $RUN_DIR"

  # Terminal-state guards: nothing to resume.
  if [[ "$RESUME_START_VERDICT" == "APPROVED" ]]; then
    log "Run already ended APPROVED — nothing to resume."
    exit 0
  fi
  if [[ "$START_ITER" -gt "$MAX_ITERS" ]]; then
    die "Iteration budget already exhausted (last_completed_cycle=$last_completed_cycle >= max_iterations=$MAX_ITERS). Raise it with --max-iterations to resume."
  fi
fi

# ---- LLM complexity classifier -------------------------------------------
# When --spec is not given, an LLM decides whether the task warrants the spec
# stage. It sees the task and, when a workspace/repo is present, a compact
# snapshot of its files so codebase size/shape can inform the decision.
workspace_snapshot() {
  local files
  files="$( { git -C "$WORKSPACE" ls-files 2>/dev/null || find "$WORKSPACE" -maxdepth 3 -type f 2>/dev/null; } \
            | grep -v '/\.git/' | head -n 200 )"
  [[ -n "$files" ]] && printf '%s' "$files"
}

build_complexity_prompt() {
  cat <<EOF
You are a task-complexity classifier for a $MODE automation pipeline. Decide
whether the task warrants an up-front spec/plan (COMPLEX) or can go straight to
generation and review (SIMPLE).

COMPLEX = multi-step; touches multiple files/modules; needs design or
architectural decisions; a refactor, migration, integration, or new feature; or
scope that is broad or ambiguous.
SIMPLE = a small, localized, well-scoped change such as a typo fix, a one-line
change, a single small function, or a trivial edit.

Task:
$TASK
EOF
  local snap; snap="$(workspace_snapshot)"
  if [[ -n "$snap" ]]; then
    printf '\nCurrent workspace files (context; larger/established codebases lean COMPLEX):\n%s\n' "$snap"
  fi
  printf '\nRespond with EXACTLY one line, nothing else:\nCOMPLEXITY: COMPLEX\nor\nCOMPLEXITY: SIMPLE\n'
}

# Echoes the model's raw answer on stdout; logs full output to <logfile>.
assess_complexity_llm() {
  local logfile="$1"
  local prompt; prompt="$(build_complexity_prompt)"
  local -a cmd=("$CLAUDE_BIN" -p "$prompt" --add-dir "$WORKSPACE")
  [[ -n "$CLAUDE_MODEL" ]] && cmd+=(--model "$CLAUDE_MODEL")
  log "▶ LLM complexity check: ${cmd[0]} -p <prompt>"
  local out rc
  set +e
  out="$("${cmd[@]}" 2>>"$logfile")"
  rc=$?
  set -e
  printf '%s\n' "$out" >>"$logfile"
  printf '%s' "$out"
  return $rc
}

# ---- run.json manifest ---------------------------------------------------
# Persist enough state to resume the run: recovered by the --resume branch
# above. `spec` is the empty string when no spec stage produced a spec.md.
persist_manifest() {
  local last_cycle="$1" verdict="$2" approved_bool="$3"
  local spec_val=""
  [[ -s "$SPEC_FILE" ]] && spec_val="$SPEC_FILE"
  write_manifest "$RUN_DIR/run.json" \
    run_id "$RUN_LABEL" \
    mode "$MODE" \
    workspace "$WORKSPACE" \
    spec "$spec_val" \
    feedback "$FEEDBACK_FILE" \
    task "$TASK" \
    task_is_file false \
    repo "$REPO" \
    max_iterations "$MAX_ITERS" \
    last_completed_cycle "$last_cycle" \
    last_verdict "$verdict" \
    approved "$approved_bool" \
    updated_at "$(_ts)"
}

# ---- prompt builders -----------------------------------------------------
# Shared trailer appended to generation and review prompts: the repo context
# (if any) and the approved spec (if the Kiro stage produced one).
append_context() {
  if [[ -n "$REPO" ]]; then
    printf '\n## Repository context\nYou are working inside an EXISTING repository at: %s\n' "$WORKSPACE"
    printf 'Implement the task by modifying the existing code in place, following the\n'
    printf 'repository'"'"'s conventions. Do not scaffold a new standalone project and do not\n'
    printf 'create commits — leave your changes in the working tree.\n'
  fi
  if [[ -s "$SPEC_FILE" ]]; then
    printf '\n## Approved spec / plan (follow it; treat its acceptance criteria as required)\n'
    cat "$SPEC_FILE"
  fi
}

# The generation prompt = static instructions + the task + repo/spec context +
# (from cycle 2 on) the reviewer's feedback from the previous cycle.
build_generation_prompt() {
  local iter="$1" feedback_file="$2"
  cat "$GEN_PROMPT_FILE"
  printf '\n\n## Workspace\nWrite all output files under this directory: %s\n' "$WORKSPACE"
  printf '\n## Task\n%s\n' "$TASK"
  append_context
  if [[ "$iter" -gt 1 && -s "$feedback_file" ]]; then
    printf '\n## Reviewer feedback from the previous cycle (address every point)\n'
    cat "$feedback_file"
  fi
}

build_review_prompt() {
  cat "$REVIEW_PROMPT_FILE"
  printf '\n\n## Original task\n%s\n' "$TASK"
  printf '\n## What to review\nReview the files under: %s\n' "$WORKSPACE"
  append_context
}

# The spec prompt drives Kiro's built-in Spec mode. We pass `/spec new <name>`
# as the session input so Kiro switches into Spec mode and generates its
# artifacts under .kiro/specs/<name>/. Because we run headless (--no-interactive)
# there are no Ctrl+X phase checkpoints, so we instruct Kiro to pick the spec
# type itself and drive the workflow through every phase without pausing.
build_spec_prompt() {
  printf '/spec new %s\n' "$SPEC_NAME"
  cat "$SPEC_PROMPT_FILE"
  printf '\n\n## How to run\n'
  printf 'You are in a non-interactive session: there are no checkpoints to pause at.\n'
  printf 'Choose the appropriate spec type yourself (Feature for new work, Bug for a\n'
  printf 'fix, Quick Spec for a small change) and drive the spec workflow through\n'
  printf 'every phase to completion without asking clarifying questions. Make\n'
  printf 'reasonable assumptions and record them in the spec.\n'
  printf 'Write the artifacts only to .kiro/specs/%s/ (their default location).\n' "$SPEC_NAME"
  printf 'Do not modify any other files and do not run/execute the tasks.\n'
  if [[ -n "$REPO" ]]; then
    printf '\n## Repository context\nYour working directory is an existing repository at: %s\n' "$WORKSPACE"
    printf 'Analyze the real code and make the spec specific to it.\n'
  fi
  printf '\n## Task\n%s\n' "$TASK"
}

# After Kiro finishes, gather every markdown artifact it wrote under
# .kiro/specs/<name>/ (requirements.md, design.md, tasks.md, ...) into the
# single SPEC_FILE the downstream generate/review prompts consume.
collect_spec_artifacts() {
  [[ -d "$SPEC_DIR" ]] || return 1
  local -a specs=()
  while IFS= read -r f; do specs+=("$f"); done \
    < <(find "$SPEC_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  [[ "${#specs[@]}" -gt 0 ]] || return 1
  {
    printf '# Spec: %s\n\n' "$SPEC_NAME"
    printf '_Generated by Kiro Spec mode; sources: %s_\n' "$SPEC_DIR"
    local f
    for f in "${specs[@]}"; do
      printf '\n\n---\n\n## %s\n\n' "$(basename "$f")"
      cat "$f"
    done
  } > "$SPEC_FILE"
}

# ---- agent runners -------------------------------------------------------
run_claude() {
  local prompt="$1" logfile="$2"
  local -a cmd=(
    "$CLAUDE_BIN" -p "$prompt"
    --dangerously-skip-permissions
    --add-dir "$WORKSPACE"
  )
  [[ -n "$CLAUDE_MODEL" ]] && cmd+=(--model "$CLAUDE_MODEL")
  # Run from the workspace so edits land in the repo / output dir.
  ( cd "$WORKSPACE" && run_step "Claude Code (generate)" "$logfile" "${cmd[@]}" )
}

run_codex() {
  local prompt="$1" logfile="$2" last_msg="$3"
  local -a cmd=(
    "$CODEX_BIN" exec
    --cd "$WORKSPACE"
    --skip-git-repo-check
    --sandbox read-only
    --output-last-message "$last_msg"
  )
  [[ -n "$CODEX_MODEL" ]] && cmd+=(-m "$CODEX_MODEL")
  cmd+=("$prompt")
  run_step "Codex (review)" "$logfile" "${cmd[@]}"
}

# Kiro headless: no --cwd flag, so we launch it from the workspace directory.
# --trust-all-tools is required because there is no interactive approval.
run_kiro_spec() {
  local prompt="$1" logfile="$2"
  local -a cmd=(
    "$KIRO_BIN" chat
    --no-interactive
    --trust-all-tools
  )
  [[ -n "$KIRO_EFFORT" ]] && cmd+=(--effort "$KIRO_EFFORT")
  cmd+=("$prompt")
  ( cd "$WORKSPACE" && run_step "Kiro (spec/plan)" "$logfile" "${cmd[@]}" )
}

# ---- spec stage (Kiro) ---------------------------------------------------
# Runs once, before the loop. Always when --spec is set; otherwise only when an
# LLM classifies the task as COMPLEX. Skipped entirely on resume — the spec is
# reused as-is from the previous run.
run_spec=0
if [[ -n "$RESUME_ID" ]]; then
  log "Resume: skipping the spec stage; reusing the prior run's spec (if any)."
elif [[ "$SPEC_MODE" -eq 1 ]]; then
  log "Spec forced on (--spec) -> running Kiro spec/plan stage."
  run_spec=1
else
  log "No --spec: asking an LLM whether a spec stage is warranted..."
  verdict="$(assess_complexity_llm "$RUN_DIR/complexity.log" || true)"
  if grep -qiE 'COMPLEXITY:[[:space:]]*COMPLEX' <<<"$verdict"; then
    log "LLM judged the task COMPLEX -> running Kiro spec/plan stage."
    run_spec=1
  elif grep -qiE 'COMPLEXITY:[[:space:]]*SIMPLE' <<<"$verdict"; then
    log "LLM judged the task SIMPLE -> skipping Kiro; using Claude+Codex only."
  else
    warn "Could not parse a complexity verdict; defaulting to skip Kiro. See $RUN_DIR/complexity.log"
  fi
fi

if [[ "$run_spec" -eq 1 ]]; then
  [[ -f "$SPEC_PROMPT_FILE" ]] || die "Missing prompt template: $SPEC_PROMPT_FILE"
  require_cmd "$KIRO_BIN"
  spec_prompt="$(build_spec_prompt)"
  if ! run_kiro_spec "$spec_prompt" "$RUN_DIR/spec.log"; then
    die "Kiro spec stage failed. See $RUN_DIR/spec.log"
  fi
  if ! collect_spec_artifacts; then
    die "Kiro produced no spec artifacts under $SPEC_DIR (see $RUN_DIR/spec.log)"
  fi
  log "Spec collected from $SPEC_DIR -> $SPEC_FILE"
fi

# ---- the loop ------------------------------------------------------------
# A fresh run starts with an empty feedback file and records an initial manifest
# (last_completed_cycle=0) so even a crash before cycle 1 leaves a resumable
# run. A resumed run keeps the prior feedback.txt so the first cycle addresses
# the last reviewer's requested changes.
if [[ -z "$RESUME_ID" ]]; then
  : > "$FEEDBACK_FILE"
  persist_manifest 0 "" false
fi

approved=0
iter="$START_ITER"
while [[ "$iter" -le "$MAX_ITERS" ]]; do
  log "================= CYCLE $iter / $MAX_ITERS ================="

  # --- 1. Generation (Claude Code) ---
  gen_prompt="$(build_generation_prompt "$iter" "$FEEDBACK_FILE")"
  if ! run_claude "$gen_prompt" "$RUN_DIR/cycle$iter-generate.log"; then
    die "Generation step failed on cycle $iter. See $RUN_DIR/cycle$iter-generate.log"
  fi

  # --- 2. Review (Codex) — runs only after generation finished ---
  last_msg="$RUN_DIR/cycle$iter-review-verdict.txt"
  review_prompt="$(build_review_prompt)"
  if ! run_codex "$review_prompt" "$RUN_DIR/cycle$iter-review.log" "$last_msg"; then
    die "Review step failed on cycle $iter. See $RUN_DIR/cycle$iter-review.log"
  fi
  [[ -s "$last_msg" ]] || die "Reviewer produced no verdict message: $last_msg"

  # --- 3. Interpret the verdict ---
  if grep -qiE '^[[:space:]]*VERDICT:[[:space:]]*APPROVED' "$last_msg"; then
    approved=1
    log "Reviewer APPROVED on cycle $iter."
    persist_manifest "$iter" APPROVED true
    break
  fi

  log "Reviewer requested changes on cycle $iter. Feeding feedback back to Claude Code."
  cp "$last_msg" "$FEEDBACK_FILE"
  persist_manifest "$iter" CHANGES_REQUESTED false
  iter=$((iter + 1))
done

# ---- outcome -------------------------------------------------------------
echo
if [[ "$approved" -eq 1 ]]; then
  log "SUCCESS ✅  Approved after $iter cycle(s)."
  log "Artifacts: $WORKSPACE"
  log "Logs:      $RUN_DIR"
  exit 0
else
  warn "STOPPED ⚠️  Reached max iterations ($MAX_ITERS) without approval."
  warn "Artifacts (last generation) are still in: $WORKSPACE"
  warn "Logs: $RUN_DIR"
  exit 1
fi
