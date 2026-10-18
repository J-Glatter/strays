#!/usr/bin/env bash
# Builds build/Strays.app (ad-hoc signed). UNIVERSAL=1 builds arm64 + x86_64 (needs full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "→ rendering app icon"
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

echo "→ swift build (release)"
swift build -c release --product Strays ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

APP=build/Strays.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Strays" "$APP/Contents/MacOS/Strays"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The app's Settings menu runs this to set up the Claude Code hook.
cp scripts/claude-hook.py "$APP/Contents/Resources/claude-hook.py"

# Ad-hoc signature: enough to run locally and register as a login item.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP"
