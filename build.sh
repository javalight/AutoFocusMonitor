#!/bin/bash
set -euo pipefail

NAME="AutoFocusMonitor"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/$NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

swiftc -O \
    -target arm64-apple-macos12.0 \
    -o "$MACOS/$NAME" \
    "$ROOT"/Sources/*.swift \
    -framework Cocoa \
    -framework ApplicationServices

# Ad-hoc sign so AX permission survives across launches at the same path.
codesign --force --sign - --timestamp=none "$APP"

echo "Built: $APP"
echo
echo "Run:    open '$APP'"
echo "Or:     '$MACOS/$NAME'"
echo
echo "First launch will prompt for Accessibility permission."
echo "Grant it in: System Settings > Privacy & Security > Accessibility."
