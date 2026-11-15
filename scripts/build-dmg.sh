#!/bin/bash
# Builds build/Headroom-<version>.dmg: a universal (Apple silicon + Intel) Headroom.app next to an
# Applications shortcut, ready to drag and drop.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.3}"
export VERSION
UNIVERSAL=1 scripts/build-app.sh

STAGING="build/dmg"
DMG="build/Headroom-$VERSION.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Headroom.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Headroom" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
hdiutil verify "$DMG" >/dev/null

echo "Built $DMG"
