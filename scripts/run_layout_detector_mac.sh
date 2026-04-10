#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${LAYOUT_VENV:-$HOME/layout-venv}"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$ROOT_DIR/services/layout-detector/requirements.txt"

export PADDLE_PDX_MODEL_SOURCE="${PADDLE_PDX_MODEL_SOURCE:-BOS}"
export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK="${PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK:-True}"
export LAYOUT_HOST="${LAYOUT_HOST:-0.0.0.0}"
export LAYOUT_PORT="${LAYOUT_PORT:-23081}"
export LAYOUT_DEVICE="${LAYOUT_DEVICE:-cpu}"
export LAYOUT_MODEL_NAME="${LAYOUT_MODEL_NAME:-PP-DocLayoutV2}"

exec "$VENV_DIR/bin/gunicorn" \
  --workers 1 \
  --threads 4 \
  --timeout 120 \
  --bind "${LAYOUT_HOST}:${LAYOUT_PORT}" \
  --chdir "$ROOT_DIR/services/layout-detector" \
  "app:app"
