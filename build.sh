#!/bin/bash
# ClawnPet ビルドスクリプト
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClawnPet.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  Sources/ClawnPet/*.swift \
  -o "$APP/Contents/MacOS/ClawnPet" \
  -framework AppKit

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built: $APP"
