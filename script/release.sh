#!/usr/bin/env bash
# Cuts a release: bumps the version, builds, publishes to GitHub Releases and
# updates the Sparkle appcast so running copies find it.
#
#   script/release.sh 1.1.0                     build, notarize, publish
#   script/release.sh 1.1.0 --dry-run           everything except push/publish
#   script/release.sh 1.1.0 --allow-unnotarized skip notarization (see below)
#
# Requires `gh` authenticated, and the Sparkle private key in the login
# keychain (created once by script/generate_sparkle_keys.sh).
set -euo pipefail

VERSION="${1:-}"
MODE="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: script/release.sh <version> [--dry-run]" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Limits"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$ROOT_DIR/dist-releases"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
APPCAST="$ROOT_DIR/appcast.xml"
REPO="jclarke/limits"

# Notarization credentials come from .env, which is gitignored.
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"
  set +a
fi
SPARKLE_BIN="$(find "$ROOT_DIR/.build/artifacts" -maxdepth 6 -type d -name bin -path "*Sparkle*" | head -1)"

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "error: Sparkle tools missing — run 'swift package resolve' first" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "error: working tree is dirty; commit before releasing" >&2
  exit 1
fi

# CFBundleVersion must increase monotonically — Sparkle compares it, not the
# marketing string — so it is derived from the tag rather than hand-managed.
BUILD_NUMBER="$(printf '%d%02d%02d' $(echo "$VERSION" | tr '.' ' '))"

echo "==> Version $VERSION (build $BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

echo "==> Building"
"$ROOT_DIR/script/build_and_run.sh" build >/dev/null

echo "==> Verifying signature"
# A Developer ID signature is what lets someone open the download without
# Gatekeeper blocking it, so a release must never go out ad-hoc signed by
# accident.
SIGN_INFO="$(codesign -dvv "$DIST_DIR/$APP_NAME.app" 2>&1)"
if grep -q "Signature=adhoc" <<<"$SIGN_INFO"; then
  echo "error: app is ad-hoc signed. Install the Developer ID certificate, or" >&2
  echo "       set LIMITS_SIGNING_IDENTITY, before cutting a release." >&2
  exit 1
fi
codesign --verify --deep --strict "$DIST_DIR/$APP_NAME.app"
echo "    $(grep '^Authority=' <<<"$SIGN_INFO" | head -1)"

echo "==> Packaging"
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
rm -f "$ARCHIVE"
# ditto rather than zip: it preserves the symlinks and extended attributes a
# signed bundle needs, and a zip that breaks the signature fails to install
# only on the user's machine, where it is hardest to diagnose.
ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/$APP_NAME.app" "$ARCHIVE"

echo "==> Notarizing"
# Without notarization Gatekeeper still refuses a download on first open, even
# with a valid Developer ID. The ticket is stapled to the app so it verifies
# offline, which means re-packaging afterwards.
#
# `notarytool submit --wait` exits 0 even when Apple returns Invalid, so the
# status has to be checked before stapling.
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  SUBMIT_JSON="$(xcrun notarytool submit "$ARCHIVE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait \
    --output-format json)"
  STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$SUBMIT_JSON")"
  SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$SUBMIT_JSON")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization $STATUS${SUBMISSION_ID:+ (id $SUBMISSION_ID)}" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
      xcrun notarytool log "$SUBMISSION_ID" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" >&2 || true
    fi
    exit 1
  fi
  # Staple the app, not the archive: the ticket has to travel inside the
  # bundle so it verifies on a machine that is offline when first opened.
  xcrun stapler staple "$DIST_DIR/$APP_NAME.app"
  rm -f "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/$APP_NAME.app" "$ARCHIVE"
  xcrun stapler validate "$DIST_DIR/$APP_NAME.app"
  echo "    stapled and re-packaged"
elif [[ "$MODE" == "--allow-unnotarized" ]]; then
  echo "    warning: shipping UNNOTARIZED — users need right-click → Open." >&2
else
  echo "error: notarization credentials missing." >&2
  echo "       Set APPLE_ID, APPLE_TEAM_ID and APPLE_APP_SPECIFIC_PASSWORD in .env," >&2
  echo "       or re-run with --allow-unnotarized." >&2
  exit 1
fi

echo "==> Signing update and regenerating appcast"
# generate_appcast signs each archive with the private key from the keychain
# and writes the enclosure URLs pointing at the GitHub release assets.
# It stamps every file with this release's prefix, so older zips would 404
# unless their URLs are rewritten to the tag they were actually published on.
# Deltas are new files and stay on this release.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  -o "$APPCAST" \
  "$RELEASE_DIR"

python3 - "$APPCAST" "$REPO" <<'PY'
import re, sys
from pathlib import Path
appcast, repo = Path(sys.argv[1]), sys.argv[2]
text = appcast.read_text()
prefix = rf"https://github.com/{re.escape(repo)}/releases/download/v[^/\"<>]+/Limits-"
text, n = re.subn(
    prefix + r"([0-9]+\.[0-9]+\.[0-9]+)\.zip",
    rf"https://github.com/{repo}/releases/download/v\1/Limits-\1.zip",
    text,
)
appcast.write_text(text)
print(f"    rewrote {n} zip enclosure URL(s) onto their own tags")
PY

if [[ "$MODE" == "--dry-run" ]]; then
  echo "Dry run: built $ARCHIVE and updated $APPCAST; nothing pushed."
  exit 0
fi

echo "==> Committing version bump and appcast"
git -C "$ROOT_DIR" add "$INFO_PLIST" "$APPCAST"
git -C "$ROOT_DIR" commit -m "Release $VERSION"
git -C "$ROOT_DIR" tag "v$VERSION"

echo "==> Publishing to GitHub"
# Order matters here, and getting it wrong is not obvious:
#
#   1. Push the tag alone. `gh release create` would otherwise create it
#      itself, pointing at whatever the remote branch happens to be — the
#      commit *before* the version bump — and then refuse the later tag push
#      as already existing.
#   2. Create the release from that tag, with the archive attached.
#   3. Only then push main, so the appcast goes live after the download it
#      points at, never before.
git -C "$ROOT_DIR" push origin "refs/tags/v$VERSION"
# Deltas are generated next to the zip and must ship on this release;
# generate_appcast already pointed their enclosure URLs here.
shopt -s nullglob
gh release create "v$VERSION" "$ARCHIVE" "$RELEASE_DIR"/*.delta \
  --repo "$REPO" \
  --title "Limits $VERSION" \
  --verify-tag \
  --generate-notes
git -C "$ROOT_DIR" push origin main

echo "Released $VERSION — https://github.com/$REPO/releases/tag/v$VERSION"
