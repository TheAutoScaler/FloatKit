#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$project_dir/build"
app_dir="$build_dir/FloatKit.app"
executable="$app_dir/Contents/MacOS/FloatKit"
new_executable="$executable.new"
if [ -n "${FLOATKIT_CODESIGN_IDENTITY:-}" ]; then
	signing_identity=$FLOATKIT_CODESIGN_IDENTITY
elif security find-identity -v -p codesigning 2>/dev/null \
	| grep -F '"FloatKit Local Code Signing"' >/dev/null; then
	signing_identity="FloatKit Local Code Signing"
elif security find-identity -v -p codesigning 2>/dev/null \
	| grep -F '"WindowTools Local Code Signing"' >/dev/null; then
	# Preserve seamless local builds on the development Mac after the rename.
	# New Macs create the FloatKit identity with setup-code-signing.sh.
	signing_identity="WindowTools Local Code Signing"
else
	signing_identity="FloatKit Local Code Signing"
fi

trap 'status=$?; rm -f "$new_executable"; exit "$status"' EXIT

mkdir -p "$app_dir/Contents/MacOS"

swiftc \
	"$project_dir/Sources/FloatKit/BreezeKeepAboveIcon.swift" \
	"$project_dir/Sources/FloatKit/main.swift" \
	-o "$new_executable" \
	-module-cache-path "/private/tmp/io.github.theautoscaler.floatkit-module-cache" \
	-framework AppKit \
	-framework ApplicationServices \
	-framework AVFoundation \
	-framework Carbon \
	-framework ScreenCaptureKit

mv "$new_executable" "$executable"

cp "$project_dir/FloatKit-Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "$signing_identity" "$app_dir"

echo "$app_dir"
