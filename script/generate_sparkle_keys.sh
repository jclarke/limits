#!/usr/bin/env bash
# Creates the Sparkle signing key, once per release machine.
#
# The private half is stored in the login keychain and must never be committed
# or shared; the public half goes in Resources/Info.plist as SUPublicEDKey.
# Losing it means existing installs can no longer verify updates, so back up
# the keychain item before reinstalling macOS.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$(find "$ROOT_DIR/.build/artifacts" -maxdepth 6 -type d -name bin -path "*Sparkle*" | head -1)"
[[ -x "$BIN/generate_keys" ]] || { echo "run 'swift package resolve' first" >&2; exit 1; }
exec "$BIN/generate_keys" "$@"
