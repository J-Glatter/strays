#!/usr/bin/env bash
# Build from source and install Strays for this user. No sudo needed.
#   ./install.sh          asks before adding the Claude Code hook
#   ./install.sh --yes    adds it without asking
# Puts Strays.app in ~/Applications, links the `strays` CLI into ~/.local/bin,
# and launches it (it registers itself to open at login on first run).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Strays builds from source and needs Apple's command line tools."
  echo "Run: xcode-select --install   (then re-run ./install.sh)"
  exit 1
fi

./scripts/build-app.sh

DEST="$HOME/Applications"
APP="$DEST/Strays.app"
mkdir -p "$DEST"

if pgrep -xq Strays; then
  echo "→ quitting running copy"
  osascript -e 'quit app id "com.glatter.strays"' >/dev/null 2>&1 || pkill -x Strays || true
  sleep 1
fi

rm -rf "$APP"
cp -R build/Strays.app "$APP"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/Strays" "$HOME/.local/bin/strays"
# So `strays --update` knows where to pull and rebuild from.
defaults write com.glatter.strays sourcePath "$(pwd)"

# Claude Code hook: when a session ends, note what it leaves running so Strays can tell you.
if [[ -d "$HOME/.claude" ]] && ! python3 scripts/claude-hook.py status >/dev/null 2>&1; then
  answer="y"
  if [[ "${1:-}" != "--yes" && -t 0 ]]; then
    read -r -p "Add Claude Code hooks (tell new sessions what's already running; report what ended ones leave behind)? [Y/n] " answer
  fi
  if [[ ! "$answer" =~ ^[Nn] ]]; then
    python3 scripts/claude-hook.py install
  fi
fi

open "$APP"
echo "✓ installed $APP — look for the paw print in the menu bar"
echo "✓ CLI: ~/.local/bin/strays"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  (add ~/.local/bin to PATH to run 'strays' from anywhere)" ;;
esac
