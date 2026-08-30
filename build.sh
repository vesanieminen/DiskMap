#!/bin/sh
set -eu

cd "$(dirname "$0")"
mkdir -p build/DiskMap.app/Contents/MacOS
mkdir -p build/DiskMap.app/Contents/Resources
mkdir -p build/ModuleCache

DEVELOPER_DIR="$(xcode-select -p)"
SDK="$DEVELOPER_DIR/SDKs/MacOSX15.sdk"
if [ ! -d "$SDK" ]; then
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

swiftc -parse-as-library -Osize -whole-module-optimization -swift-version 5 \
  -module-cache-path build/ModuleCache -sdk "$SDK" \
  -target "$(uname -m)-apple-macos15.0" \
  -framework AppKit Sources/main.swift \
  -o build/DiskMap.app/Contents/MacOS/DiskMap

strip -x build/DiskMap.app/Contents/MacOS/DiskMap
cp Info.plist build/DiskMap.app/Contents/Info.plist
cp Assets/DiskMap.icns build/DiskMap.app/Contents/Resources/DiskMap.icns

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" build/DiskMap.app >/dev/null
  echo "Signed with $SIGNING_IDENTITY"
else
  codesign --force --sign - build/DiskMap.app >/dev/null
  echo "Warning: ad-hoc signing makes macOS request privacy access again after code changes."
fi

echo "Built build/DiskMap.app"
du -sh build/DiskMap.app
