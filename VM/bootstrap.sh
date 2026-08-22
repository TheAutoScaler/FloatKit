#!/bin/bash

set -euo pipefail
# shellcheck source=FloatKit/VM/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Tart macOS guests require an Apple Silicon host." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required to install Tart." >&2
    exit 1
fi

if ! command -v tart >/dev/null 2>&1; then
    brew tap openai/tools
    brew trust --formula openai/tools/tart
    brew trust --formula openai/tools/softnet
    brew install openai/tools/tart
fi

if ! vm_exists "$FLOATKIT_TART_BASE"; then
    echo "Downloading and cloning $FLOATKIT_TART_IMAGE as $FLOATKIT_TART_BASE..."
    tart clone "$FLOATKIT_TART_IMAGE" "$FLOATKIT_TART_BASE"
fi

if [[ "${FLOATKIT_TART_KEEP_CACHE:-0}" != "1" ]]; then
    tart prune --entries caches --space-budget 0
fi

tart set "$FLOATKIT_TART_BASE" \
    --cpu "$FLOATKIT_TART_CPUS" \
    --memory "$FLOATKIT_TART_MEMORY_MB" \
    --display "$FLOATKIT_TART_DISPLAY"

echo "Tart and the FloatKit base image are ready."
echo "Run: $vm_dir/run-tests.sh"
