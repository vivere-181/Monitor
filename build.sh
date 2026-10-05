#!/bin/bash
# Builds build/Monitor.app (arm64, Apple Silicon). Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Monitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -wmo -target arm64-apple-macos13.0 \
    -import-objc-header Sources/Bridge.h \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Monitor"
strip -x "$APP/Contents/MacOS/Monitor"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swiftc -O scripts/make_icon.swift -o build/make_icon
    build/make_icon build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    rm -rf build/AppIcon.iconset build/make_icon
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    pkill -x Monitor 2>/dev/null || true
    rm -rf /Applications/Monitor.app
    cp -R "$APP" /Applications/
    open /Applications/Monitor.app
    echo "Installed to /Applications/Monitor.app"
fi
