#!/bin/bash
# Builds a release: a notarisation-free, signature-verified update package.
#
#   ./scripts/make-release.sh 1.2.0 "What changed in this one."
#
# Produces, under dist/:
#   Osler-<version>.zip   the update Sparkle downloads
#   Osler-<version>.dmg   the friendly installer for a first-time user
#   appcast.xml           the feed, with the zip's EdDSA signature
#
# The private signing key never appears here: sign_update reads it from the
# maintainer's Keychain and prints only a signature.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version> [release notes]" >&2
  exit 2
fi

APP="Osler.app"
DIST="dist"
FEED_BASE="https://github.com/albertofettucini/Osler/releases/download"
SIGN_TOOL="$(find .build/artifacts -type f -name sign_update -not -path '*old_dsa*' | head -1)"
if [ -z "$SIGN_TOOL" ]; then
  echo "✗ sign_update not found — run 'swift package resolve' first." >&2
  exit 1
fi

# The bundle carries the version, so build it with this one.
echo "▸ Building $APP $VERSION…"
sed -i '' "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" scripts/package-app.sh
./scripts/package-app.sh >/dev/null

mkdir -p "$DIST"
ZIP="$DIST/Osler-$VERSION.zip"
DMG="$DIST/Osler-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

# ── The update archive ──────────────────────────────────────────────────────
# ditto keeps the bundle's symlinks and signature intact; plain `zip` doesn't.
echo "▸ Zipping for Sparkle…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── The friendly installer ──────────────────────────────────────────────────
echo "▸ Building the DMG…"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TXT'
Osler — installing

1) Drag Osler onto the Applications folder.

2) Open Applications, RIGHT-CLICK Osler and choose "Open", then click
   "Open" again in the dialog that appears.

   That's only needed the first time. macOS shows it because this app isn't
   signed with a paid Apple developer account — nothing is wrong with it.

   No "Open" option? System Settings > Privacy & Security, scroll down, and
   click "Open Anyway" next to Osler.

3) Pick a template and press Run. Your own API keys go in Settings > API Keys,
   or install Ollama to run local models with no key at all.

github.com/albertofettucini/Osler
TXT
hdiutil create -volname "Osler" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

# ── Sign the update and write the feed ──────────────────────────────────────
echo "▸ Signing the update…"
# sign_update prints BOTH sparkle:edSignature="…" and length="…" — emitting
# our own length as well produced a duplicate attribute, which is a hard XML
# parse error, which meant Sparkle could never read the feed at all.
SIGNATURE_LINE="$("$SIGN_TOOL" "$ZIP")"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Osler</title>
    <link>https://raw.githubusercontent.com/albertofettucini/Osler/main/appcast.xml</link>
    <description>Updates for Osler.</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${NOTES:-See the release notes on GitHub.}]]></description>
      <enclosure url="$FEED_BASE/v$VERSION/Osler-$VERSION.zip"
                 type="application/octet-stream"
                 $SIGNATURE_LINE />
    </item>
  </channel>
</rss>
XML

echo
echo "✓ $ZIP"
echo "✓ $DMG"
echo "✓ appcast.xml (points at $FEED_BASE/v$VERSION/)"
echo
echo "Next: create the GitHub release tagged v$VERSION with both files attached,"
echo "then commit appcast.xml — Sparkle reads it from the main branch."
