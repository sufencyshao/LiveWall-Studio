#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT_DIR/script/package.py"
if [[ "${1:-}" != '--build-only' ]]; then
  pkill -x LiveWall || true
  open "$ROOT_DIR/dist/LiveWall.app" --args --show-settings
fi
