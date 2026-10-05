#!/bin/sh
# Builds a universal Exitpilot.app into build/ and zips it for release.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Exitpilot

APP=build/Exitpilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Exitpilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature; not notarized.
codesign --force --deep --sign - "$APP"

(cd build && rm -f Exitpilot.zip && ditto -c -k --keepParent Exitpilot.app Exitpilot.zip)
echo "Built $APP and build/Exitpilot.zip"
