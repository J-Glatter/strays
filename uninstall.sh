#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Strays.app"

if [[ -x "$APP/Contents/MacOS/Strays" ]]; then
  "$APP/Contents/MacOS/Strays" --unregister-login-item || true
fi
osascript -e 'quit app id "com.glatter.strays"' >/dev/null 2>&1 || pkill -x Strays || true
rm -rf "$APP"
[[ -L "$HOME/.local/bin/strays" ]] && rm "$HOME/.local/bin/strays"
python3 scripts/claude-hook.py uninstall || true
defaults delete com.glatter.strays >/dev/null 2>&1 || true
echo "✓ Strays removed (history and launch records stay in ~/Library/Application Support/Strays)"
