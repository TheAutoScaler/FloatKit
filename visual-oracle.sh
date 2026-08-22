#!/bin/bash
set -euo pipefail

app="/Applications/FloatKit Visual Oracle.app"
result="$(mktemp /tmp/floatkit-visual-oracle-result.XXXXXX)"
trap 'rm -f "$result"' EXIT

[[ -x "$app/Contents/MacOS/FloatKitVisualOracle" ]] || {
  echo "FloatKit Visual Oracle is not installed" >&2
  exit 1
}

set +e
/usr/bin/open -n -g "$app" --args "$@" --result "$result"
open_status=$?
set -e

if [[ "$open_status" -eq 0 ]]; then
  for _ in $(seq 1 600); do
    [[ -s "$result" ]] && break
    sleep 0.05
  done
fi

response="$(cat "$result" 2>/dev/null || true)"
if [[ "$open_status" -ne 0 || "$response" != ok:* ]]; then
  [[ -z "$response" ]] || echo "$response" >&2
  exit 1
fi
echo "${response#ok: }"
