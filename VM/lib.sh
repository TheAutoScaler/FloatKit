#!/bin/bash

set -euo pipefail

vm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # Used by scripts that source this library.
floatkit_dir="$(cd "$vm_dir/.." && pwd)"
# shellcheck source=FloatKit/VM/config.sh
source "$vm_dir/config.sh"

require_tart() {
    if ! command -v tart >/dev/null 2>&1; then
        echo "Tart is not installed. Run FloatKit/VM/bootstrap.sh first." >&2
        exit 1
    fi
}

vm_exists() {
    tart list --quiet 2>/dev/null | awk '{print $1}' | grep -Fxq "$1"
}

wait_for_agent() {
    local name="$1"
    local runner_pid="${2:-}"
    local deadline=$((SECONDS + FLOATKIT_TART_TIMEOUT))
    until tart exec "$name" /usr/bin/true >/dev/null 2>&1; do
        if [[ -n "$runner_pid" ]] && ! kill -0 "$runner_pid" 2>/dev/null; then
            echo "Tart exited before guest agent became available for $name." >&2
            return 1
        fi
        if ((SECONDS >= deadline)); then
            echo "Timed out waiting for Tart guest agent in $name." >&2
            return 1
        fi
        sleep 2
    done
}

stop_vm() {
    local name="$1"
    tart stop "$name" >/dev/null 2>&1 || true
}
