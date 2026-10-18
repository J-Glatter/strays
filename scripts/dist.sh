#!/usr/bin/env bash
# Universal zip for Macs without developer tools. The recipient runs:
#   unzip Strays-<version>.zip -d ~/Applications && xattr -dr com.apple.quarantine ~/Applications/Strays.app
# (It's ad-hoc signed, not notarized, so Gatekeeper blocks it until the quarantine flag is cleared.)
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 ./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
mkdir -p dist
ZIP="dist/Strays-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Strays.app "$ZIP"
echo "✓ $ZIP ($(lipo -archs build/Strays.app/Contents/MacOS/Strays))"
