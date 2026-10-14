#!/bin/bash
# Builds a release: a notarisation-free, signature-verified update package.
#
#   ./scripts/make-release.sh 1.2.0 "$(cat dist/notes-1.2.0.html)"
#
# Produces, under dist/:
#   Osler-<version>.zip      the update Sparkle downloads
#   Osler-<version>.dmg      the friendly installer for a first-time user
#   appcast-<version>.xml    the feed, with the zip's EdDSA signature
#   build-<version>.txt      the commit and working-tree diff it was built from
#
# It uploads, tags and publishes nothing, and it never writes ./appcast.xml:
# installed copies read that file, so it only changes once
# scripts/verify-release.sh has checked the archive users will download.
#
# The private signing key never appears here: sign_update reads it from the
# maintainer's Keychain and prints only a signature. For a dry run with a
# throwaway key, set SPARKLE_ED_KEY_FILE (sign_update --ed-key-file) and
# SPARKLE_PUBLIC_KEY (read by package-app.sh) together.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version> [release notes]" >&2
  exit 2
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ \"$VERSION\" isn't a version like 1.2.0." >&2
  exit 2
fi
case "$NOTES" in
  *"]]>"*)
    echo "✗ The release notes can't contain ]]> (it would end the feed's CDATA)." >&2
    exit 2 ;;
esac

REPO="albertofettucini/Osler"
APP="Osler.app"
DIST="dist"
FEED_BASE="https://github.com/$REPO/releases/download"

# ── Never cut a published version again ────────────────────────────────────
# Rebuilding 1.1.0 after it shipped put a new zip's signature in the feed,
# and every installed copy was then offered an update that couldn't verify.
# A published version's feed is fixed by editing the XML, never by a rebuild.
if ! command -v gh >/dev/null 2>&1; then
  echo "✗ gh (GitHub CLI) is needed to check that v$VERSION isn't published yet." >&2
  exit 1
fi
if GH_OUT="$(gh release view "v$VERSION" -R "$REPO" --json tagName 2>&1)"; then
  echo "✗ v$VERSION is already published. Fix the feed by editing appcast.xml, or cut a new version." >&2
  exit 1
fi
case "$GH_OUT" in
  *"release not found"*) ;;
  *)
    echo "✗ Couldn't check whether v$VERSION is already published:" >&2
    echo "$GH_OUT" >&2
    exit 1 ;;
esac

# ── The build record has to cover everything that gets built ───────────────
# `git diff HEAD` doesn't see untracked files, so a build that used one
# couldn't be matched to a commit later.
UNTRACKED="$(git ls-files --others --exclude-standard)"
if [ -n "$UNTRACKED" ]; then
  echo "✗ These files aren't tracked, so $DIST/build-$VERSION.txt couldn't account for them:" >&2
  echo "$UNTRACKED" | sed 's/^/    /' >&2
  echo "  Track them (git add -N is enough) or move them out of the repo; release notes can live in $DIST/." >&2
  exit 1
fi

SIGN_TOOL="$(find .build/artifacts -type f -name sign_update -not -path '*old_dsa*' | head -1)"
if [ -z "$SIGN_TOOL" ]; then
  echo "✗ sign_update not found — run 'swift package resolve' first." >&2
  exit 1
fi

tree_digest() { git diff HEAD --binary | shasum -a 256 | cut -d " " -f 1; }

# The bundle carries the version, so build it with this one.
echo "▸ Building $APP $VERSION…"
sed -i '' "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" scripts/package-app.sh
BUILT_FROM="$(git rev-parse HEAD)"
BUILT_DIFF="$(tree_digest)"
./scripts/package-app.sh >/dev/null
if [ "$(git rev-parse HEAD)" != "$BUILT_FROM" ] || [ "$(tree_digest)" != "$BUILT_DIFF" ] \
   || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "✗ The tree changed while the app was building, so the build can't be matched to it. Run this again." >&2
  exit 1
fi

# Everything below happens in a private temp dir. The repo copy of the app
# sits on an iCloud-synced Desktop, which stamps FinderInfo and fileprovider
# attributes on it after signing, and a strict signature check rejects those.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/osler-release.XXXXXX")"
case "$WORK" in
  "$HOME/Desktop"*)
    echo "✗ The temp dir ($WORK) is under ~/Desktop; set TMPDIR to somewhere iCloud doesn't sync." >&2
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# ── A clean copy to ship ────────────────────────────────────────────────────
echo "▸ Copying the app to a clean stage…"
CLEAN="$WORK/clean/$APP"
mkdir -p "$WORK/clean"
ditto --norsrc --noextattr "$APP" "$CLEAN"
xattr -cr "$CLEAN"
if xattr -r "$CLEAN" 2>/dev/null | grep -E 'com\.apple\.(FinderInfo|ResourceFork|fileprovider)'; then
  echo "✗ The clean copy still carries the attributes above; not shipping it." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$CLEAN"; then
  echo "✗ The clean copy fails a strict signature check; not shipping it." >&2
  exit 1
fi

mkdir -p "$DIST"
ZIP="$DIST/Osler-$VERSION.zip"
DMG="$DIST/Osler-$VERSION.dmg"
FEED="$DIST/appcast-$VERSION.xml"
RECORD="$DIST/build-$VERSION.txt"
rm -f "$ZIP" "$DMG" "$FEED" "$RECORD"

# ── The update archive ──────────────────────────────────────────────────────
# ditto keeps the bundle's symlinks and signature intact; plain `zip` doesn't.
# No resource forks or extended attributes go in: the bundle needs none.
echo "▸ Zipping for Sparkle…"
ditto -c -k --norsrc --noextattr --keepParent "$CLEAN" "$ZIP"

# ── The friendly installer ──────────────────────────────────────────────────
echo "▸ Building the DMG…"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$CLEAN" "$STAGE/$APP"
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
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  SIGNATURE_LINE="$("$SIGN_TOOL" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$ZIP")"
else
  SIGNATURE_LINE="$("$SIGN_TOOL" "$ZIP")"
fi
SIGNATURE_PATTERN='^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$'
ZIP_LENGTH="$(stat -f %z "$ZIP")"
if ! [[ "$SIGNATURE_LINE" =~ $SIGNATURE_PATTERN ]] \
   || [[ "$SIGNATURE_LINE" != *" length=\"$ZIP_LENGTH\"" ]]; then
  echo "✗ sign_update printed something unexpected for a $ZIP_LENGTH-byte zip:" >&2
  echo "  $SIGNATURE_LINE" >&2
  exit 1
fi
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$FEED" <<XML
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
if ! xmllint --noout "$FEED"; then
  echo "✗ $FEED doesn't parse." >&2
  exit 1
fi

# ── What it was built from ──────────────────────────────────────────────────
ZIP_SHA="$(shasum -a 256 "$ZIP" | cut -d " " -f 1)"
DMG_SHA="$(shasum -a 256 "$DMG" | cut -d " " -f 1)"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$RECORD" <<TXT
# Osler $VERSION was built from this commit plus this working-tree diff.
# Before committing, both must still match:
#   git rev-parse HEAD
#   git diff HEAD --binary | shasum -a 256
# scripts/verify-release.sh $VERSION --local checks this for you.
version $VERSION
head $BUILT_FROM
diff-sha256 $BUILT_DIFF
zip-sha256 $ZIP_SHA
dmg-sha256 $DMG_SHA
built $BUILT_AT
TXT

echo
echo "✓ $ZIP"
echo "✓ $DMG"
echo "✓ $FEED (points at $FEED_BASE/v$VERSION/)"
echo "✓ $RECORD"
echo
echo "Next: test, gönder, commit + tag, gh release create, ./scripts/verify-release.sh $VERSION, then commit appcast.xml."
echo
echo "Nothing has been uploaded or tagged. By hand, in this order:"
echo "  1. ./scripts/verify-release.sh $VERSION --local   (now, and again right before committing)"
echo "  2. Commit everything except appcast.xml, then: git tag v$VERSION && git push origin main v$VERSION"
echo "  3. gh release create v$VERSION $ZIP $DMG --title \"Osler $VERSION\" --notes-file $DIST/release-notes-$VERSION.md"
echo "  4. ./scripts/verify-release.sh $VERSION   (checks the uploaded files, then writes ./appcast.xml)"
echo "  5. git commit -m \"Sparkle: offer $VERSION\" appcast.xml && git push origin main"
