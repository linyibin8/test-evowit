#!/usr/bin/env bash
set -euo pipefail

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen --version
  exit 0
fi

if [ -x "${HOME}/.local/bin/xcodegen" ]; then
  "${HOME}/.local/bin/xcodegen" --version
  exit 0
fi

if [ -x "${HOME}/bin/xcodegen" ]; then
  "${HOME}/bin/xcodegen" --version
  exit 0
fi

BIN_DIR="${HOME}/bin"
mkdir -p "${BIN_DIR}"

TMP_JSON="$(mktemp)"
TMP_ZIP="$(mktemp -t xcodegen).zip"

curl --http1.1 --retry 3 --retry-all-errors -fsSL "https://api.github.com/repos/yonaskolb/XcodeGen/releases/latest" -o "${TMP_JSON}"

DOWNLOAD_URL="$(python3 - "${TMP_JSON}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for asset in data.get("assets", []):
    url = asset.get("browser_download_url", "")
    if url.endswith(".zip"):
        print(url)
        break
else:
    raise SystemExit("Unable to find XcodeGen zip asset")
PY
)"

curl --http1.1 --retry 3 --retry-all-errors -fsSL "${DOWNLOAD_URL}" -o "${TMP_ZIP}"
unzip -qo "${TMP_ZIP}" -d "${BIN_DIR}"
mkdir -p "${HOME}/.local/bin"
XCODEGEN_SOURCE="$(find "${BIN_DIR}" -path '*/xcodegen' -type f | head -n 1)"
if [ -z "${XCODEGEN_SOURCE}" ]; then
  echo "Unable to locate xcodegen binary after extraction" >&2
  exit 1
fi
chmod +x "${XCODEGEN_SOURCE}"
cp "${XCODEGEN_SOURCE}" "${HOME}/.local/bin/xcodegen"
export PATH="${HOME}/.local/bin:${HOME}/bin/bin:${PATH}"
"${HOME}/.local/bin/xcodegen" --version
