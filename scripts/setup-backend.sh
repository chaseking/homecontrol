#!/bin/bash
# Creates backend/.venv with the backend's dependencies.
set -euo pipefail
cd "$(dirname "$0")/../backend"
if command -v uv >/dev/null; then
  uv venv --quiet --python 3.12 .venv 2>/dev/null || uv venv --quiet .venv
  uv pip install --quiet --python .venv/bin/python -r requirements.txt
else
  python3 -m venv .venv
  .venv/bin/pip install --quiet -r requirements.txt
fi
echo "backend venv ready: $(pwd)/.venv"
