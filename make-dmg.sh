#!/bin/bash
set -euo pipefail

NAME="AutoFocusMonitor"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/$NAME.app"
DIST="$ROOT/dist"
DMG="$DIST/$NAME.dmg"
STAGE="$DIST/.dmg-staging"

"$ROOT/build.sh"

mkdir -p "$DIST"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "$NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG"

rm -rf "$STAGE"

echo
echo "DMG: $DMG"
ls -lh "$DMG"
