#!/usr/bin/env bash
# Builds an unsigned (ad-hoc signed) universal OpenToolbox.app and a release zip.
#
# Usage: scripts/package-app.sh [version] [build-number]
# Output: .build/release-app/dist/OpenToolbox-<version>-macOS-universal.zip and .dmg (+ .sha256 each)
#
# Runs on macOS with Xcode 16 or later. The app is ad-hoc signed only, so on first
# launch users approve it in System Settings → Privacy & Security → Open Anyway.
set -euo pipefail

VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
BUNDLE_ID="io.github.letterxbox.OpenToolbox"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/release-app"
DERIVED="$WORK/DerivedData"
DIST="$WORK/dist"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$DIST/OpenToolbox.app"
ZIP_NAME="OpenToolbox-$VERSION-macOS-universal.zip"

rm -rf "$WORK"
mkdir -p "$DIST"

echo "==> Building Release (arm64 + x86_64)"
xcodebuild \
    -scheme OpenToolbox \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    build

# SwiftPM resource bundles must be found inside the app. The generated accessors
# have to look in Bundle.main.resourceURL (Contents/Resources); otherwise the app
# would crash on its first localized string.
echo "==> Checking resource bundle accessors"
accessors=()
while IFS= read -r file; do accessors+=("$file"); done < <(
    find "$DERIVED/Build/Intermediates.noindex" -path '*Release*' -name resource_bundle_accessor.swift)
if [ "${#accessors[@]}" -lt 2 ]; then
    echo "error: expected resource accessors for OpenToolboxCore and OpenToolboxApp, found ${#accessors[@]}" >&2
    exit 1
fi
for file in "${accessors[@]}"; do
    if ! grep -q 'Bundle.main.resourceURL' "$file"; then
        echo "error: $file does not look in Bundle.main.resourceURL" >&2
        exit 1
    fi
done

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$PRODUCTS/OpenToolbox" "$APP/Contents/MacOS/OpenToolbox"
bundles=0
for bundle in "$PRODUCTS"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
    bundles=$((bundles + 1))
done
if [ "$bundles" -lt 2 ]; then
    echo "error: expected at least 2 resource bundles in $PRODUCTS, found $bundles" >&2
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>OpenToolbox</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>OpenToolbox</string>
    <key>CFBundleDisplayName</key><string>OpenToolbox</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>OpenToolbox contributors. Licensed under GPL-3.0.</string>
    <key>NSDesktopFolderUsageDescription</key><string>OpenToolbox opens files you choose and writes results to the output folder you pick.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>OpenToolbox opens files you choose and writes results to the output folder you pick.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>OpenToolbox opens files you choose and writes results to the output folder you pick.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>OpenToolbox opens files you choose on external drives.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>OpenToolbox opens files you choose on network drives.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Architectures and deployment target"
lipo -archs "$APP/Contents/MacOS/OpenToolbox"
for arch in arm64 x86_64; do
    echo "-- $arch"
    vtool -arch "$arch" -show-build "$APP/Contents/MacOS/OpenToolbox" | grep -E 'platform|minos'
done

echo "==> Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"
(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" && cat "$ZIP_NAME.sha256")

echo "==> Done: $DIST/$ZIP_NAME"

"$ROOT/scripts/make-dmg.sh" "$VERSION"
