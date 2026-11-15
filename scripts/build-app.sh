#!/bin/bash
# Builds build/Headroom.app: a release build of the Swift package wrapped in an app bundle.
#
#   scripts/build-app.sh                 # build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh     # Apple silicon + Intel
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.3}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.headroom.mac}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product Headroom ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product Headroom ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Headroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Headroom" "$APP/Contents/MacOS/Headroom"
cp Sources/Headroom/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" \
    Sources/Headroom/Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signing ("-") is enough to run locally and register the login item.
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
