#!/bin/bash
# Creates backend/.venv (if needed) and installs the backend's dependencies. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/../backend"
if command -v uv >/dev/null; then
  [ -x .venv/bin/python ] || { uv venv --quiet --python 3.12 .venv 2>/dev/null || uv venv --quiet .venv; }
  uv pip install --quiet --python .venv/bin/python -r requirements.txt
else
  [ -x .venv/bin/python ] || python3 -m venv .venv
  .venv/bin/pip install --quiet -r requirements.txt
fi
echo "backend venv ready: $(pwd)/.venv"
