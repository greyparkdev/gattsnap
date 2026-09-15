#!/bin/bash
# Rebuild the M1 spike and re-sign the .app wrapper.
# The .app wrapper + a signing identity are both load-bearing — see
# docs/platform-notes.md, "The macOS CLI Bluetooth permission problem".
set -euo pipefail
cd "$(dirname "$0")"

# Any valid identity works; TCC keys on (bundle id, team id), not the cert.
IDENTITY="${GATTSNAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 'Apple Development' | awk '{print $2}')}"

swift build "$@"
mkdir -p blespike.app/Contents/MacOS
cp .build/debug/blespike blespike.app/Contents/MacOS/blespike
codesign --force --sign "$IDENTITY" \
  --identifier dev.gattsnap.blespike --options runtime blespike.app
echo "built + signed: ./blespike.app/Contents/MacOS/blespike"
echo "NOTE: always pass --disclaim when running from a shell."
