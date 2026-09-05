# shellcheck shell=bash
# Shared helpers for the Conductor orchestrator.
# Sourced by conductor.sh — not meant to be executed directly.

# ---- logging -------------------------------------------------------------

_ts()   { date +"%Y-%m-%d %H:%M:%S"; }

log()   { printf '%s [Conductor] %s\n'  "$(_ts)" "$*" >&2; }
warn()  { printf '%s [Conductor][WARN] %s\n' "$(_ts)" "$*" >&2; }
die()   { printf '%s [Conductor][ERROR] %s\n' "$(_ts)" "$*" >&2; exit 1; }

# ---- CLI availability ----------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found on PATH: $1"
}

# ---- run + capture -------------------------------------------------------
# run_step <label> <logfile> <cmd...>
# Streams the command's combined output to <logfile> (tee'd to stderr),
# and returns the command's real exit code. Never aborts the caller — the
# caller decides what to do with a non-zero status.
run_step() {
  local label="$1"; shift
  local logfile="$1"; shift
  log "▶ $label: $*"
  set +e
  # PIPESTATUS preserves the command's exit code through the tee pipe.
  "$@" > >(tee -a "$logfile" >&2) 2>&1
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -eq 0 ]]; then
    log "✔ $label finished (exit 0)"
  else
    warn "✖ $label FAILED (exit $rc)"
  fi
  return $rc
}

# ---- run.json manifest (pure bash + coreutils, no extra dependencies) ----
# The manifest is a flat JSON object recording enough state to resume a run.
# Written by the orchestrator only; agents never read or write it.

# json_escape <string> -> escaped string (no surrounding quotes) on stdout.
# Escapes backslash, double-quote, tab, carriage return and newline so the
# value can be embedded inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslash first
  s="${s//\"/\\\"}"   # double-quote
  s="${s//$'\t'/\\t}" # tab
  s="${s//$'\r'/\\r}" # carriage return
  s="${s//$'\n'/\\n}" # newline
  printf '%s' "$s"
}

# write_manifest <file> <k1> <v1> <k2> <v2> ...
# Emits a flat JSON object. Values matching an integer (^-?[0-9]+$) or a boolean
# (true|false) are written unquoted; everything else is JSON-escaped and quoted.
# Writes to <file>.tmp then mv's into place so a crash cannot leave a truncated
# manifest.
write_manifest() {
  local file="$1"; shift
  local tmp="$file.tmp"
  local first=1 key val
  {
    printf '{\n'
    while [[ $# -gt 0 ]]; do
      key="$1"; val="$2"; shift 2
      [[ $first -eq 1 ]] || printf ',\n'
      first=0
      if [[ "$val" =~ ^-?[0-9]+$ || "$val" == "true" || "$val" == "false" ]]; then
        printf '  "%s": %s' "$key" "$val"
      else
        printf '  "%s": "%s"' "$key" "$(json_escape "$val")"
      fi
    done
    printf '\n}\n'
  } > "$tmp"
  mv "$tmp" "$file"
}

# manifest_get <file> <key> -> raw (unescaped) value on stdout, empty if absent.
# Reverses the minimal escaping json_escape applies. Always exits 0 (a missing
# file or key yields an empty string) so it is safe under `set -euo pipefail`.
manifest_get() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 0
  # Match:  "key": <value>  where value is a quoted string, number, or boolean.
  line="$(grep -m1 -E "^[[:space:]]*\"$key\"[[:space:]]*:" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  # Strip the "key": prefix and any trailing comma.
  val="${line#*:}"
  val="${val#"${val%%[![:space:]]*}"}"   # ltrim
  val="${val%,}"
  val="${val%"${val##*[![:space:]]}"}"   # rtrim
  if [[ "$val" == \"*\" ]]; then
    val="${val#\"}"; val="${val%\"}"
    # Reverse json_escape (backslash last).
    val="${val//\\n/$'\n'}"
    val="${val//\\r/$'\r'}"
    val="${val//\\t/$'\t'}"
    val="${val//\\\"/\"}"
    val="${val//\\\\/\\}"
  fi
  printf '%s' "$val"
}
