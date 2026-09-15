#!/usr/bin/env bash
# Cuts a release: bumps the version, builds, publishes to GitHub Releases and
# updates the Sparkle appcast so running copies find it.
#
#   script/release.sh 1.1.0            build, publish, update appcast
#   script/release.sh 1.1.0 --dry-run  do everything except push and publish
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

echo "==> Packaging"
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
rm -f "$ARCHIVE"
# ditto rather than zip: it preserves the symlinks and extended attributes a
# signed bundle needs, and a zip that breaks the signature fails to install
# only on the user's machine, where it is hardest to diagnose.
ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/$APP_NAME.app" "$ARCHIVE"

echo "==> Signing update and regenerating appcast"
# generate_appcast signs each archive with the private key from the keychain
# and writes the enclosure URLs pointing at the GitHub release assets.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  -o "$APPCAST" \
  "$RELEASE_DIR"

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
gh release create "v$VERSION" "$ARCHIVE" \
  --repo "$REPO" \
  --title "Limits $VERSION" \
  --verify-tag \
  --generate-notes
git -C "$ROOT_DIR" push origin main

echo "Released $VERSION — https://github.com/$REPO/releases/tag/v$VERSION"
