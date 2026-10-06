#!/usr/bin/env bash
# Install dist/TokenBar.app into ~/Applications (launch at login needs a stable location) and restart it.
#
#   scripts/bundle.sh && scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/dist/TokenBar.app"
DEST="$HOME/Applications/TokenBar.app"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC not found; run scripts/bundle.sh first" >&2
  exit 1
fi

# Quit a running instance gracefully, then make sure it is gone.
if pgrep -x TokenBar >/dev/null 2>&1; then
  osascript -e 'tell application id "dev.tokenbar.TokenBar" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x TokenBar >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x TokenBar 2>/dev/null || true
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
open "$DEST"
echo "Installed and started $DEST"
