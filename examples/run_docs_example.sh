#!/usr/bin/env bash
# Example: document generation + review loop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../conductor.sh" \
  --mode docs \
  --task "Write a concise onboarding guide (README-style Markdown) for a fictional REST API 'PetStore' covering authentication with API keys, the /pets endpoints (list, get, create), pagination, and error codes." \
  --workspace "$HERE/../workspace-docs" \
  --max-iterations 4
