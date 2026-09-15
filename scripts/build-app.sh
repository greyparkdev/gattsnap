#!/bin/bash
# Builds gattsnap into a signed .app bundle.
#
# Both pieces are load-bearing and neither alone is enough (docs/platform-notes.md §1):
#   - the .app wrapper gives TCC an Info.plist to read a usage description from
#   - a real signing identity gives TCC a stable identity, so the Bluetooth
#     grant survives rebuilds instead of re-prompting on every cdhash change
#
# gattsnap re-execs itself disclaimed at runtime, which is the third piece.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${GATTSNAP_CONFIG:-release}"
APP="gattsnap.app"
BUNDLE_ID="dev.gattsnap.cli"

# Any valid identity works: TCC keys on (bundle id, team id), not on the cert.
# Ad-hoc signing has no stable identity and stalls at notDetermined — verified
# in M1 — so a real identity is required rather than merely preferred.
IDENTITY="${GATTSNAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 -E 'Developer ID Application|Apple Development' | awk '{print $2}')}"

if [ -z "$IDENTITY" ]; then
  echo "error: no codesigning identity found." >&2
  echo "       Set GATTSNAP_SIGN_IDENTITY, or see docs/platform-notes.md §1 for why" >&2
  echo "       ad-hoc signing does not work for Bluetooth access." >&2
  exit 1
fi

swift build -c "$CONFIG" --product gattsnap
BIN="$(swift build -c "$CONFIG" --product gattsnap --show-bin-path)/gattsnap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/gattsnap"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>gattsnap</string>
	<key>CFBundleExecutable</key><string>gattsnap</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSUIElement</key><true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>gattsnap captures the GATT attribute table of a Bluetooth Low Energy peripheral so firmware changes can be diffed.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime "$APP"

cat <<EOF

built: $APP/Contents/MacOS/gattsnap

Run it through the bundle path, not .build — TCC resolves the usage description
from the containing bundle:

  ./$APP/Contents/MacOS/gattsnap capture --name <substring> --profile <label> --out snapshot.json

The first run raises a Bluetooth permission prompt. On a headless CI runner
there is no one to answer it; that needs an MDM-deployed PPPC profile granting
kTCCServiceBluetoothAlways to $BUNDLE_ID. See docs/platform-notes.md §1.
EOF
