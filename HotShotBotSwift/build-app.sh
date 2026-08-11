#!/bin/sh
# Wraps the SPM-built executable in a minimal .app bundle and code-signs it.
#
# Why this exists: macOS's Local Network privacy permission (the TCC gate that governs
# outgoing connections to LAN IPs, e.g. the Panasonic camera) is bundle-based — it's granted
# per CFBundleIdentifier, tied to an Info.plist declaring NSLocalNetworkUsageDescription. A
# bare `swift build`/`swift run` executable has no bundle at all, so the OS has nothing to
# attach the permission to and silently denies local-network access rather than prompting for
# it (URLSession then reports the misleading "Internet connection appears to be offline").
# Wrapping in a real (even unsigned/ad-hoc-signed) .app bundle gives the OS something to grant
# permission to and makes the actual permission prompt appear on first launch.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="HotShotBotSwift"
BIN_PATH=".build/debug/${APP_NAME}"
if [ "$CONFIG" = "release" ]; then
  BIN_PATH=".build/release/${APP_NAME}"
fi

if [ ! -f "$BIN_PATH" ]; then
  echo "Binary not found at $BIN_PATH — run 'swift build' (or 'swift build -c release') first." >&2
  exit 1
fi

APP_BUNDLE=".build/${APP_NAME}.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1

echo "Built $APP_BUNDLE"
echo "Launch with: open \"$APP_BUNDLE\""
