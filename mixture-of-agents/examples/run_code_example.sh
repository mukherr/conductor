#!/usr/bin/env bash
# Example: code generation + review loop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../conductor.sh" \
  --mode code \
  --task "Build a small Python CLI 'csv2json' that reads a CSV file path as an argument and prints JSON to stdout. Include argument parsing, error handling for a missing file, and a pytest test." \
  --workspace "$HERE/../workspace-code" \
  --max-iterations 4
