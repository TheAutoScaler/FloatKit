#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="/Applications/FloatKit Visual Oracle.app"
oracle="$app/Contents/MacOS/FloatKitVisualOracle"
launcher="$project_dir/visual-oracle.sh"

if [ "${FLOATKIT_REINSTALL_VISUAL_ORACLE:-0}" = 1 ] || [ ! -x "$oracle" ]; then
  "$project_dir/build-visual-oracle.sh"
  /usr/bin/ditto "$project_dir/build/FloatKit Visual Oracle.app" "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"

if ! "$launcher" status; then
  "$launcher" request || true
  /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  echo "Enable FloatKit Visual Oracle in Screen & System Audio Recording, then rerun this script."
  exit 2
fi

echo "FloatKit Visual Oracle is installed and authorized."
