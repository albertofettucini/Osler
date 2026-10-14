#!/bin/bash
# Checks a release the way an installed Osler will meet it, before the feed
# points at it.
#
#   ./scripts/verify-release.sh 1.2.0 --local   # the dist/ files, before upload
#   ./scripts/verify-release.sh 1.2.0           # the uploaded assets; if all is
#                                               # well, writes ./appcast.xml
#
#   --feed <file>         check this feed instead of dist/appcast-<version>.xml
#                         (it is never promoted to ./appcast.xml)
#   --previous <zip|app>  take the signing key from this copy of the previous
#                         release instead of downloading it from GitHub
#
# It only ever downloads from GitHub. Uploading, tagging, committing and
# pushing stay with the maintainer.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="albertofettucini/Osler"
FEED_BASE="https://github.com/$REPO/releases/download"
FEED_URL="https://raw.githubusercontent.com/$REPO/main/appcast.xml"

usage() {
  echo "usage: $0 <version> [--local] [--feed <appcast.xml>] [--previous <zip|app>]" >&2
  exit 2
}

VERSION="${1:-}"
case "$VERSION" in ""|-*) usage ;; esac
shift
LOCAL=0
FEED=""
PREVIOUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1 ;;
    --feed) [ $# -ge 2 ] || usage; FEED="$2"; shift ;;
    --previous) [ $# -ge 2 ] || usage; PREVIOUS="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

DIST_ZIP="dist/Osler-$VERSION.zip"
DIST_DMG="dist/Osler-$VERSION.dmg"
DIST_FEED="dist/appcast-$VERSION.xml"
RECORD="dist/build-$VERSION.txt"
[ -n "$FEED" ] || FEED="$DIST_FEED"

# Downloads and extractions go to a private temp dir: anything under the
# iCloud-synced Desktop picks up attributes that would fail the checks below
# for reasons that have nothing to do with the release.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/osler-verify.XXXXXX")"
case "$WORK" in
  "$HOME/Desktop"*)
    echo "✗ The temp dir ($WORK) is under ~/Desktop; set TMPDIR to somewhere iCloud doesn't sync." >&2
    exit 1 ;;
esac
MOUNT="$WORK/mnt"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ] && ! { hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet; }; then
    echo "✗ Couldn't detach $MOUNT; detach it by hand, then delete $WORK." >&2
    return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAILED=$((FAILED + 1)); }
section() { echo; echo "▸ $*"; }
fatal() { echo "✗ $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d " " -f 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

need_gh() {
  command -v gh >/dev/null 2>&1 || fatal "gh (GitHub CLI) is needed to $1."
}

# ── The archive and installer to check ──────────────────────────────────────
if [ "$LOCAL" = 1 ]; then
  section "Checking the local files in dist/ (nothing of this release is downloaded)"
  ZIP="$DIST_ZIP"
  DMG="$DIST_DMG"
  [ -f "$ZIP" ] || fatal "$ZIP is missing — run ./scripts/make-release.sh $VERSION first."
  [ -f "$DMG" ] || fatal "$DMG is missing — run ./scripts/make-release.sh $VERSION first."
else
  need_gh "download the release"
  section "Downloading the v$VERSION assets users will get"
  mkdir -p "$WORK/download"
  gh release download "v$VERSION" -R "$REPO" -p "Osler-$VERSION.zip" -p "Osler-$VERSION.dmg" -D "$WORK/download" \
    || fatal "Couldn't download Osler-$VERSION.zip and Osler-$VERSION.dmg from release v$VERSION."
  ZIP="$WORK/download/Osler-$VERSION.zip"
  DMG="$WORK/download/Osler-$VERSION.dmg"
  [ -f "$ZIP" ] || fatal "Release v$VERSION has no Osler-$VERSION.zip."
  [ -f "$DMG" ] || fatal "Release v$VERSION has no Osler-$VERSION.dmg."
  for PAIR in "$ZIP|$DIST_ZIP" "$DMG|$DIST_DMG"; do
    GOT="${PAIR%%|*}"
    WANT="${PAIR#*|}"
    if [ ! -f "$WANT" ]; then
      bad "$WANT is missing, so the upload can't be compared with the build"
    elif [ "$(sha "$GOT")" = "$(sha "$WANT")" ]; then
      ok "$(basename "$GOT") is byte-for-byte the file in dist/"
    else
      bad "$(basename "$GOT") on GitHub differs from $WANT (sha256 $(sha "$GOT") vs $(sha "$WANT"))"
    fi
  done
fi
ZIP_LENGTH="$(stat -f %z "$ZIP")"

# ── The signing key installed copies hold ───────────────────────────────────
section "Finding the signing key of the release before v$VERSION"
PREV_SOURCE="$PREVIOUS"
if [ -z "$PREV_SOURCE" ]; then
  echo "  · Downloading the previous release's zip to read its key (pass --previous <zip|app> to skip this)"
  need_gh "find the previous release"
  PREV_TAG="$(gh release list -R "$REPO" --limit 50 --exclude-drafts --exclude-pre-releases \
    --json tagName --jq '.[].tagName' | grep -vxF "v$VERSION" | head -1 || true)"
  [ -n "$PREV_TAG" ] || fatal "No published release before v$VERSION to take the signing key from; pass --previous <zip|app>."
  mkdir -p "$WORK/previous"
  gh release download "$PREV_TAG" -R "$REPO" -p "Osler-${PREV_TAG#v}.zip" -D "$WORK/previous" \
    || fatal "Couldn't download Osler-${PREV_TAG#v}.zip from release $PREV_TAG."
  PREV_SOURCE="$WORK/previous/Osler-${PREV_TAG#v}.zip"
fi
case "$PREV_SOURCE" in
  *.zip)
    mkdir -p "$WORK/previous-app"
    ditto -x -k "$PREV_SOURCE" "$WORK/previous-app" || fatal "Couldn't extract $PREV_SOURCE."
    PREV_APP="$WORK/previous-app/Osler.app" ;;
  *.app) PREV_APP="$PREV_SOURCE" ;;
  *) fatal "--previous takes a release .zip or an Osler.app." ;;
esac
[ -d "$PREV_APP" ] || fatal "No Osler.app in $PREV_SOURCE."
KEY="$(plist "$PREV_APP" SUPublicEDKey)"
[ -n "$KEY" ] || fatal "The previous release ($PREV_SOURCE) has no SUPublicEDKey."
echo "  · $(plist "$PREV_APP" CFBundleShortVersionString) from $PREV_SOURCE: SUPublicEDKey $KEY"

# ── The feed ────────────────────────────────────────────────────────────────
section "Checking the feed ($FEED)"
cat "$FEED" > "$WORK/feed.xml" 2>/dev/null || fatal "Can't read $FEED."
if xmllint --noout "$WORK/feed.xml" 2>"$WORK/xmllint.err"; then
  ok "it parses"
else
  bad "it doesn't parse: $(head -1 "$WORK/xmllint.err")"
fi
# --recover reads what it can from a broken feed, so the remaining checks
# still say what else is wrong with it.
xp() { xmllint --recover --xpath "string($1)" "$WORK/feed.xml" 2>/dev/null || true; }
ITEMS="$(xmllint --recover --xpath 'count(//item)' "$WORK/feed.xml" 2>/dev/null || echo 0)"
[ "$ITEMS" = 1 ] && ok "one item" || bad "$ITEMS items, expected exactly 1"
F_VERSION="$(xp '//item/*[local-name()="version"]')"
F_SHORT="$(xp '//item/*[local-name()="shortVersionString"]')"
F_URL="$(xp '//item/enclosure/@url')"
F_LENGTH="$(xp '//item/enclosure/@length')"
F_SIGNATURE="$(xp '//item/enclosure/@*[local-name()="edSignature"]')"
[ "$F_VERSION" = "$VERSION" ] && ok "sparkle:version $F_VERSION" \
  || bad "sparkle:version is \"$F_VERSION\", expected $VERSION"
[ "$F_SHORT" = "$VERSION" ] && ok "sparkle:shortVersionString $F_SHORT" \
  || bad "sparkle:shortVersionString is \"$F_SHORT\", expected $VERSION"
WANT_URL="$FEED_BASE/v$VERSION/Osler-$VERSION.zip"
[ "$F_URL" = "$WANT_URL" ] && ok "enclosure points at $F_URL" \
  || bad "enclosure url is \"$F_URL\", expected $WANT_URL"
[ "$F_LENGTH" = "$ZIP_LENGTH" ] && ok "enclosure length $F_LENGTH matches the zip" \
  || bad "enclosure length is \"$F_LENGTH\" but the zip is $ZIP_LENGTH bytes"
if [ -z "$F_SIGNATURE" ]; then
  bad "the enclosure has no sparkle:edSignature"
elif ED_OUT="$(swift scripts/verify-ed25519.swift "$ZIP" "$F_SIGNATURE" "$KEY" 2>&1)"; then
  ok "edSignature is valid for the zip under the previous release's key"
else
  bad "edSignature check failed: $ED_OUT"
fi

# ── The apps inside ─────────────────────────────────────────────────────────
record_value() { [ -f "$RECORD" ] && awk -v k="$1" '$1 == k { print $2 }' "$RECORD" || true; }
R_SPARKLE="$(record_value sparkle)"
check_app() {
  local LABEL="$1" APP="$2"
  if [ ! -d "$APP" ]; then
    bad "$LABEL: no Osler.app"
    return
  fi
  local V SV APP_KEY APP_FEED DIRT
  V="$(plist "$APP" CFBundleVersion)"
  SV="$(plist "$APP" CFBundleShortVersionString)"
  [ "$V" = "$VERSION" ] && ok "$LABEL: CFBundleVersion $V" \
    || bad "$LABEL: CFBundleVersion is \"$V\", expected $VERSION"
  [ "$SV" = "$VERSION" ] && ok "$LABEL: CFBundleShortVersionString $SV" \
    || bad "$LABEL: CFBundleShortVersionString is \"$SV\", expected $VERSION"
  APP_KEY="$(plist "$APP" SUPublicEDKey)"
  [ "$APP_KEY" = "$KEY" ] && ok "$LABEL: SUPublicEDKey matches the previous release" \
    || bad "$LABEL: SUPublicEDKey is \"$APP_KEY\", but installed copies hold $KEY"
  APP_FEED="$(plist "$APP" SUFeedURL)"
  [ "$APP_FEED" = "$FEED_URL" ] && ok "$LABEL: SUFeedURL is the project feed" \
    || bad "$LABEL: SUFeedURL is \"$APP_FEED\", expected $FEED_URL"
  if codesign --verify --deep --strict "$APP" 2>"$WORK/codesign.err"; then
    ok "$LABEL: strict code signature OK"
  else
    bad "$LABEL: strict code signature fails: $(tr '\n' ' ' < "$WORK/codesign.err")"
  fi
  if [ -n "$R_SPARKLE" ]; then
    local SPARKLE_PLIST="$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" APP_SPARKLE
    APP_SPARKLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SPARKLE_PLIST" 2>/dev/null || true)"
    [ "$APP_SPARKLE" = "$R_SPARKLE" ] && ok "$LABEL: Sparkle $APP_SPARKLE, as recorded" \
      || bad "$LABEL: embeds Sparkle \"$APP_SPARKLE\", but the build recorded $R_SPARKLE"
  fi
  DIRT="$(xattr -r "$APP" 2>/dev/null | grep -E 'com\.apple\.(FinderInfo|ResourceFork|fileprovider)' || true)"
  if [ -z "$DIRT" ]; then
    ok "$LABEL: no FinderInfo, resource fork or fileprovider attributes"
  else
    bad "$LABEL: $(echo "$DIRT" | wc -l | tr -d ' ') stray attributes, e.g. $(echo "$DIRT" | head -1)"
  fi
}
# `|| true` throughout: under set -e a failing substitution would end the
# script silently instead of reporting the failure below.
cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' || true; }

section "Checking the app in the zip (extracted with ditto, as Sparkle does)"
TOP="$(zipinfo -1 "$ZIP" 2>/dev/null | cut -d / -f 1 | sort -u | tr '\n' ' ' || true)"
[ "$TOP" = "Osler.app " ] && ok "the zip holds Osler.app and nothing else" \
  || bad "the zip's top level is \"$TOP\", expected just Osler.app"
mkdir -p "$WORK/zip"
if ditto -x -k "$ZIP" "$WORK/zip"; then
  check_app "zip" "$WORK/zip/Osler.app"
else
  bad "ditto couldn't extract the zip"
fi

section "Checking the app in the DMG (mounted read-only)"
mkdir -p "$MOUNT"
if hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet "$DMG"; then
  MOUNTED=1
  check_app "DMG" "$MOUNT/Osler.app"
  [ -f "$MOUNT/Read me first.txt" ] && ok "DMG: Read me first.txt is there" \
    || bad "DMG: Read me first.txt is missing"
  [ -L "$MOUNT/Applications" ] && ok "DMG: Applications shortcut is there" \
    || bad "DMG: Applications shortcut is missing"
  ZIP_CD="$(cdhash "$WORK/zip/Osler.app")"
  DMG_CD="$(cdhash "$MOUNT/Osler.app")"
  if [ -n "$ZIP_CD" ] && [ "$ZIP_CD" = "$DMG_CD" ]; then
    ok "the zip and the DMG carry the same build (CDHash $ZIP_CD)"
  else
    bad "the zip and the DMG carry different builds (CDHash \"$ZIP_CD\" vs \"$DMG_CD\")"
  fi
  hdiutil detach "$MOUNT" -quiet && MOUNTED=0
else
  bad "hdiutil couldn't mount the DMG"
fi

# ── Provenance ──────────────────────────────────────────────────────────────
section "Checking the build record ($RECORD)"
if [ ! -f "$RECORD" ]; then
  bad "$RECORD is missing, so nothing ties this build to a commit"
else
  R_HEAD="$(awk '$1 == "head" { print $2 }' "$RECORD")"
  R_DIFF="$(awk '$1 == "diff-sha256" { print $2 }' "$RECORD")"
  R_RESOLVED="$(record_value resolved-sha256)"
  if [ -z "$R_SPARKLE" ] || [ -z "$R_RESOLVED" ]; then
    bad "$RECORD doesn't say which Sparkle was built in; rebuild with ./scripts/make-release.sh $VERSION"
  elif [ ! -f Package.resolved ]; then
    bad "Package.resolved is missing, so the Sparkle that was built in can't be confirmed"
  elif [ "$(sha Package.resolved)" = "$R_RESOLVED" ]; then
    ok "Package.resolved is the one the build used (Sparkle $R_SPARKLE)"
  else
    bad "Package.resolved changed since the build (Sparkle $R_SPARKLE was built in); rebuild"
  fi
  if [ -z "$R_HEAD" ] || [ -z "$R_DIFF" ]; then
    bad "$RECORD has no head or diff-sha256 line"
  elif [ "$LOCAL" = 1 ]; then
    # Before the release commit: the tree must be exactly what was built.
    NOW_HEAD="$(git rev-parse HEAD)"
    NOW_DIFF="$(git diff HEAD --binary | shasum -a 256 | cut -d " " -f 1)"
    [ "$NOW_HEAD" = "$R_HEAD" ] && ok "HEAD is still $R_HEAD" \
      || bad "HEAD is $NOW_HEAD, but the build was made from $R_HEAD; rebuild"
    [ "$NOW_DIFF" = "$R_DIFF" ] && ok "the working tree is still the one that was built" \
      || bad "the working tree changed since the build; rebuild"
    UNTRACKED="$(git ls-files --others --exclude-standard)"
    [ -z "$UNTRACKED" ] && ok "no untracked files" \
      || bad "untracked files the build record can't cover: $(echo "$UNTRACKED" | tr '\n' ' ')"
  elif ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    bad "there's no local tag v$VERSION to compare with the build"
  elif ! git cat-file -e "$R_HEAD^{commit}" 2>/dev/null; then
    bad "the build was made from $R_HEAD, which this repo doesn't have"
  else
    # After it: the tag must hold exactly the built tree.
    TAG_DIFF="$(git diff "$R_HEAD" "v$VERSION" --binary 2>/dev/null | shasum -a 256 | cut -d " " -f 1 || true)"
    [ "$TAG_DIFF" = "$R_DIFF" ] && ok "tag v$VERSION holds exactly the tree that was built" \
      || bad "tag v$VERSION doesn't hold the tree that was built (from $R_HEAD plus the recorded diff)"
  fi
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
echo
if [ "$FAILED" -gt 0 ]; then
  echo "✗ $FAILED check(s) failed. ./appcast.xml was not touched."
  exit 1
fi
if [ "$LOCAL" = 1 ]; then
  echo "✓ The local release files check out. Nothing was uploaded and ./appcast.xml was not touched."
elif [ "$FEED" != "$DIST_FEED" ]; then
  echo "✓ All checks passed. ./appcast.xml was not touched: only $DIST_FEED is ever promoted."
else
  cp "$DIST_FEED" appcast.xml
  echo "Verified — commit appcast.xml"
fi
