#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir="$project_dir/build/FloatKit Visual Oracle.app"
executable="$app_dir/Contents/MacOS/FloatKitVisualOracle"
if [ -n "${FLOATKIT_CODESIGN_IDENTITY:-}" ]; then
  identity=$FLOATKIT_CODESIGN_IDENTITY
elif security find-identity -v -p codesigning 2>/dev/null \
  | grep -F '"FloatKit Local Code Signing"' >/dev/null; then
  identity="FloatKit Local Code Signing"
elif security find-identity -v -p codesigning 2>/dev/null \
  | grep -F '"WindowTools Local Code Signing"' >/dev/null; then
  identity="WindowTools Local Code Signing"
else
  identity="FloatKit Local Code Signing"
fi

mkdir -p "$app_dir/Contents/MacOS"
xcrun swiftc \
  -parse-as-library \
  "$project_dir/Tests/VisualOracle/main.swift" \
  -o "$executable" \
  -module-cache-path /private/tmp/io.github.theautoscaler.floatkit-visual-oracle-module-cache \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework ImageIO \
  -framework ScreenCaptureKit \
  -framework UniformTypeIdentifiers
cp "$project_dir/Tests/VisualOracle/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "$identity" "$app_dir"
echo "$app_dir"
