#!/bin/bash
# Packages Osler into a double-clickable Osler.app.
#
#   ./scripts/package-app.sh              # build + bundle into ./Osler.app
#   ./scripts/package-app.sh --desktop    # …and copy to ~/Desktop
#
# Icon: put your logo at assets/AppIcon.png (1024x1024 PNG). If it doesn't
# exist, a placeholder is rendered so the bundle always has an icon.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Osler"
BUNDLE_ID="com.osler.app"
VERSION="0.1.0"
BUILD_DIR=".build/release"
APP="$APP_NAME.app"

echo "▸ Building release binary…"
swift build -c release --product Osler >/dev/null

echo "▸ Assembling $APP…"
# Stage OUTSIDE the repo: the repo lives under ~/Desktop, which iCloud/File
# Provider stamps with extended attributes (com.apple.provenance,
# com.apple.fileprovider.*) between steps — xattr -cr can't remove them all
# (provenance is SIP-protected) and codesign then rejects the bundle as
# "detritus". A private temp dir never gets stamped; sign there, copy last.
STAGE="$(mktemp -d)/$APP"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
# -X: drop extended attributes already present on the built binary.
cp -X "$BUILD_DIR/Osler" "$STAGE/Contents/MacOS/$APP_NAME"

# ── Icon ────────────────────────────────────────────────────────────────────
# assets/AppIcon.png (the logo) becomes a symbol-only icon: Vision lifts the
# subject off its background, so only the mark itself shows on the Desktop.
if [ -f "assets/AppIcon.png" ]; then
  echo "▸ Extracting the symbol from assets/AppIcon.png (background removed)…"
  ICON_SRC="$(mktemp -d)/AppIcon-symbol.png"
  swift scripts/extract-symbol-icon.swift assets/AppIcon.png "$ICON_SRC" >/dev/null
else
  echo "▸ No assets/AppIcon.png — rendering placeholder icon…"
  mkdir -p assets
  swift scripts/render-placeholder-icon.swift assets/AppIcon-placeholder.png >/dev/null
  ICON_SRC="assets/AppIcon-placeholder.png"
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  DOUBLE=$((SIZE * 2))
  sips -z "$SIZE" "$SIZE" "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z "$DOUBLE" "$DOUBLE" "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"

# ── Info.plist ──────────────────────────────────────────────────────────────
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
# Belt and braces: strip whatever attributes the temp stage did pick up.
xattr -cr "$STAGE"
codesign --force --deep --sign - "$STAGE"

# Signed bundle → repo copy (and Desktop). Attributes stamped on the copies
# AFTER signing don't invalidate the signature — only signing-time detritus does.
rm -rf "$APP"
cp -R "$STAGE" "$APP"

if [ "${1:-}" = "--desktop" ]; then
  echo "▸ Copying to ~/Desktop…"
  rm -rf "$HOME/Desktop/$APP"
  cp -R "$STAGE" "$HOME/Desktop/$APP"
fi

echo "✓ $APP ready$( [ "${1:-}" = "--desktop" ] && echo " (also on ~/Desktop)" )"
