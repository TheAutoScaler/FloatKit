#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
log="$(mktemp /tmp/floatkit-sharpness-mutation.XXXXXX)"
trap 'rm -f "$log"' EXIT

set +e
FLOATKIT_TEST_FORCE_CAPTURE_SCALE=1 \
FLOATKIT_TEST_REQUIRED_CAPTURE_SCALE=2 \
./run-regression-tests.sh >"$log" 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    echo "FAIL: forced 1x capture incorrectly passed the 2x sharpness requirement"
    cat "$log"
    exit 1
fi
if ! rg -q 'post-zoom titlebar or Retina capture failed' "$log"; then
    echo "FAIL: mutation failed for an unrelated reason"
    cat "$log"
    exit 1
fi

echo "PASS: forced 1x capture was rejected by the Retina sharpness regression"
