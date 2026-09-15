#!/usr/bin/env bash
# Builds Limits.app into dist/ and (by default) relaunches it.
#
#   script/build_and_run.sh          build, install and run
#   script/build_and_run.sh build    build only
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

echo "==> Signing ($SIGNING_IDENTITY)"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE" 2>/dev/null

if [[ "$MODE" == "run" ]]; then
  echo "==> Launching"
  open "$APP_BUNDLE"
  echo "Limits is running in the menu bar."
else
  echo "Built $APP_BUNDLE"
fi
