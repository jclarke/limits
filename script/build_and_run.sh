#!/usr/bin/env bash
# Builds Limits.app into dist/ and (by default) relaunches it.
#
#   script/build_and_run.sh          build and run from dist/
#   script/build_and_run.sh build    build only
#   script/build_and_run.sh install  build, copy to /Applications, and run
#
# Use `install` before turning on Launch at Login: macOS records the app's
# path when it registers, so a bundle that later moves stops launching.
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Limits"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONFIGURATION="${LIMITS_CONFIGURATION:-release}"

# A stable code signature is what lets macOS remember the user's "Always
# Allow" decision for a provider's Keychain item across rebuilds. Ad-hoc
# signing is enough for that as long as the bundle identifier is stable.
SIGNING_IDENTITY="${LIMITS_SIGNING_IDENTITY:--}"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"
BINARY="$(swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_BUNDLE"
# Quit any running copy first: replacing the bundle underneath a live process
# leaves it running stale code with a broken signature.
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# SwiftPM emits bundled resources (the provider brand marks) as a separate
# .bundle next to the binary. `Bundle.module` finds it in Contents/Resources.
BIN_DIR="$(swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR" --show-bin-path)"
for resource_bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$resource_bundle" ] || continue
  cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"
done
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
cp "$ROOT_DIR/Resources/Limits.icns" "$APP_BUNDLE/Contents/Resources/Limits.icns"

# Sparkle ships as a framework the app links against at runtime. The rpath set
# in Package.swift points here, and its XPC services must come along or the
# updater cannot install anything.
# Prefer the copy SwiftPM staged beside the binary — that is the one this
# build actually linked against — and fall back to the downloaded artifact.
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" -maxdepth 6 -name "Sparkle.framework" -type d | head -1)"
fi
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
else
  echo "warning: Sparkle.framework not found; run 'swift package resolve' first" >&2
fi

echo "==> Signing ($SIGNING_IDENTITY)"
# The hardened runtime turns on library validation, which refuses to load a
# framework whose signing identity differs from the app's. Ad-hoc signatures
# carry no team, so every ad-hoc build would fail to launch. Apply it only
# with a real identity — that is the case where it is required (notarization)
# and where the identities actually match.
# Written as a string rather than an array: macOS ships bash 3.2, where
# "${array[@]}" on an empty array counts as unbound under `set -u`.
SIGN_OPTIONS=""
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_OPTIONS="--options runtime"
fi

# Inside-out: nested code must be sealed before the bundle that contains it,
# or the outer signature is invalid the moment it is verified.
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  while IFS= read -r nested; do
    codesign --force $SIGN_OPTIONS --sign "$SIGNING_IDENTITY" --timestamp=none "$nested"
  done < <(find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" -maxdepth 4 \
    \( -name "*.xpc" -o -name "Autoupdate" -o -name "Updater.app" \))
  codesign --force $SIGN_OPTIONS --sign "$SIGNING_IDENTITY" --timestamp=none \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
codesign --force $SIGN_OPTIONS --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"

if [[ "$MODE" == "install" ]]; then
  INSTALLED="/Applications/$APP_NAME.app"
  echo "==> Installing to $INSTALLED"
  rm -r "$INSTALLED" 2>/dev/null || true
  cp -R "$APP_BUNDLE" "$INSTALLED"
  open "$INSTALLED"
  echo "Limits installed to /Applications and running in the menu bar."
elif [[ "$MODE" == "run" ]]; then
  echo "==> Launching"
  open "$APP_BUNDLE"
  echo "Limits is running in the menu bar."
else
  echo "Built $APP_BUNDLE"
fi
