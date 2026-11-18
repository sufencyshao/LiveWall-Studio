#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./script/build-renderer.sh
python3 script/package.py
