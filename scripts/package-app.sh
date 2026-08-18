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
VERSION="1.1.0"
# Sparkle: where the app looks for new versions, and the key that proves an
# update really came from this project. The private half lives only in the
# maintainer's Keychain — see scripts/make-release.sh.
FEED_URL="https://raw.githubusercontent.com/albertofettucini/Osler/main/appcast.xml"
# Public half only — safe to commit. It's what lets an installed copy refuse
# an update that wasn't signed with the matching private key.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-ebQJqPEUVaCSBjFbDSjs7iiXRylBjtQBoro+qwR8UKo=}"
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
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
# -X: drop extended attributes already present on the built binary.
cp -X "$BUILD_DIR/Osler" "$STAGE/Contents/MacOS/$APP_NAME"

# ── Sparkle ─────────────────────────────────────────────────────────────────
# SwiftPM links the framework but never embeds it, so a bundle built this way
# would die at launch with a dyld error. Copy it in and teach the executable
# to look beside itself.
SPARKLE_FW="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "✗ Sparkle.framework not found — run 'swift package resolve' first." >&2
  exit 1
fi
echo "▸ Embedding Sparkle…"
cp -R "$SPARKLE_FW" "$STAGE/Contents/Frameworks/"
xattr -cr "$STAGE/Contents/Frameworks/Sparkle.framework"
# Harmless if the rpath is already there (a rebuilt binary may carry it).
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$STAGE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
# Belt and braces: strip whatever attributes the temp stage did pick up.
xattr -cr "$STAGE"
# Nested code must be signed before the bundle that contains it, or the outer
# signature seals a framework that then fails its own check.
codesign --force --sign - --timestamp=none \
  "$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
  "$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
  "$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
  "$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$STAGE/Contents/Frameworks/Sparkle.framework"
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
