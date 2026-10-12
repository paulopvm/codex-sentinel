#!/bin/bash
# Build both architectures without requiring Xcode's xcbuild, then create a ZIP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for ARCH in arm64 x86_64; do
  if [[ "$ARCH" == "arm64" ]]; then BUILD_PATH=".build/apple-silicon"; else BUILD_PATH=".build/intel"; fi
  swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path "$BUILD_PATH"
done
ARM_BIN="$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/apple-silicon --show-bin-path)"
INTEL_BIN="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/intel --show-bin-path)"
APP_PATH="$ROOT/dist/release/Codex Sentinel.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp Info.plist "$APP_PATH/Contents/Info.plist"
lipo -create "$ARM_BIN/CodexSentinel" "$INTEL_BIN/CodexSentinel" -output "$APP_PATH/Contents/MacOS/CodexSentinel"
chmod 755 "$APP_PATH/Contents/MacOS/CodexSentinel"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
# Ad-hoc signing ensures binary integrity; it is NOT Developer ID or notarization.
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/CodexSentinel" -verify_arch arm64 x86_64
plutil -lint "$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
ARCHIVE="Codex-Sentinel-$VERSION-universal.zip"
rm -f "$ROOT/dist/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ROOT/dist/$ARCHIVE"
(cd "$ROOT/dist" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Release: $ROOT/dist/$ARCHIVE"
echo "Ad-hoc signed only. Apple notarization and Developer ID are not configured."
