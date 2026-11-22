#!/usr/bin/env bash
# Wraps the packaged OpenToolbox.app in a drag-to-Applications disk image.
#
# Usage: scripts/make-dmg.sh [version]
# Input:  .build/release-app/dist/OpenToolbox.app (from scripts/package-app.sh)
# Output: .build/release-app/dist/OpenToolbox-<version>-macOS-universal.dmg (+ .sha256)
#
# It does not rebuild the app, so the disk image holds exactly the app that is in the zip.
set -euo pipefail

VERSION="${1:-0.1.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/release-app"
DIST="$WORK/dist"
APP="$DIST/OpenToolbox.app"
STAGE="$WORK/dmg-stage"
DMG_NAME="OpenToolbox-$VERSION-macOS-universal.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found; run scripts/package-app.sh first" >&2
    exit 1
fi

rm -rf "$STAGE" "$DIST/$DMG_NAME" "$DIST/$DMG_NAME.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/OpenToolbox.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create -volname "OpenToolbox $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DIST/$DMG_NAME"
rm -rf "$STAGE"
hdiutil verify "$DIST/$DMG_NAME"

echo "==> Checking the app inside the disk image"
MOUNT="$(mktemp -d "$WORK/mount.XXXXXX")"
cleanup() {
    hdiutil detach "$MOUNT" -quiet || true
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DIST/$DMG_NAME" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT/OpenToolbox.app"
diff -r "$APP" "$MOUNT/OpenToolbox.app"
echo "App in the disk image matches $APP"

(cd "$DIST" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" && cat "$DMG_NAME.sha256")
echo "==> Done: $DIST/$DMG_NAME"
