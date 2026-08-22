#!/bin/bash

set -euo pipefail
# shellcheck source=FloatKit/VM/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_tart

while IFS= read -r name; do
    [[ "$name" == floatkit-test-* ]] || continue
    stop_vm "$name"
    tart delete "$name"
done < <(tart list --quiet | awk '{print $1}')

if [[ "${1:-}" == "--base" ]] && vm_exists "$FLOATKIT_TART_BASE"; then
    stop_vm "$FLOATKIT_TART_BASE"
    tart delete "$FLOATKIT_TART_BASE"
fi

echo "Removed disposable FloatKit Tart VMs${1:+ and the base VM}."
