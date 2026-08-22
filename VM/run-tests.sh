#!/bin/bash

set -euo pipefail
# shellcheck source=FloatKit/VM/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_tart
oracle_app="/Applications/FloatKit Visual Oracle.app"
oracle_bin="$oracle_app/Contents/MacOS/FloatKitVisualOracle"
oracle_launcher="$floatkit_dir/visual-oracle.sh"

if [[ "${FLOATKIT_SKIP_VISUAL:-0}" != 1 ]]; then
    if [[ ! -x "$oracle_bin" ]]; then
        echo "FloatKit Visual Oracle is not installed. Run ./install-visual-oracle.sh." >&2
        exit 1
    fi
fi

if ! vm_exists "$FLOATKIT_TART_BASE"; then
    echo "Base VM $FLOATKIT_TART_BASE is missing. Run VM/bootstrap.sh." >&2
    exit 1
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
test_vm="floatkit-test-$run_id"
artifact_dir="$vm_dir/artifacts/$run_id"
runner_pid=""

cleanup() {
    stop_vm "$test_vm"
    if [[ -n "$runner_pid" ]]; then
        wait "$runner_pid" 2>/dev/null || true
    fi
    tart delete "$test_vm" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$artifact_dir"
tart clone "$FLOATKIT_TART_BASE" "$test_vm"

front_pid="$(/usr/bin/osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true' 2>/dev/null || true)"

/usr/bin/caffeinate -dimsu tart run "$test_vm" \
    --no-audio \
    --no-clipboard \
    --dir="floatkit:$floatkit_dir:ro" \
    --dir="artifacts:$artifact_dir" \
    >"$artifact_dir/tart.log" 2>&1 &
runner_pid=$!

# A real graphical framebuffer is required for compositor screenshots. Keep
# Tart rendering behind the user's current application: hiding, minimising, or
# moving it offscreen causes WindowServer to discard the framebuffer.
for _ in $(seq 1 30); do
    if /usr/bin/osascript -e "tell application \"System Events\" to tell first process whose unix id is $runner_pid to get window 1" >/dev/null 2>&1; then
        screen_right="$(/usr/bin/osascript -e 'tell application "Finder" to get item 3 of bounds of window of desktop' 2>/dev/null || echo 1440)"
        /usr/bin/osascript -e "tell application \"System Events\" to tell first process whose unix id is $runner_pid to set position of window 1 to {$((screen_right - 2)), 0}" >/dev/null 2>&1 || true
        break
    fi
    sleep 0.05
done
if [[ -n "$front_pid" ]]; then
    /usr/bin/osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $front_pid to true" >/dev/null 2>&1 || true
fi

wait_for_agent "$test_vm" "$runner_pid"

set +e
(
    set -o pipefail
    tart exec "$test_vm" /usr/bin/env \
        "FLOATKIT_SKIP_VISUAL=${FLOATKIT_SKIP_VISUAL:-0}" \
        "FLOATKIT_SKIP_CORE=${FLOATKIT_SKIP_CORE:-0}" \
        "FLOATKIT_SKIP_GENERIC_VISUAL=${FLOATKIT_SKIP_GENERIC_VISUAL:-0}" \
        "FLOATKIT_SKIP_CORE=${FLOATKIT_SKIP_CORE:-0}" /bin/bash \
        "/Volumes/My Shared Files/floatkit/VM/guest/run-tests.sh" \
        "/Volumes/My Shared Files/floatkit" \
        "/Volumes/My Shared Files/artifacts" \
        2>&1 | tee "$artifact_dir/guest.log"
    printf '%s\n' "${PIPESTATUS[0]}" > "$artifact_dir/guest.status"
) &
test_pid=$!

while kill -0 "$test_pid" 2>/dev/null; do
    for request in "$artifact_dir"/capture-*.request; do
        [[ -e "$request" ]] || continue
        capture_name="$(basename "$request" .request)"
        output="$artifact_dir/${capture_name#capture-}-full.png"
        if [[ ! -s "$output" ]]; then
            # Do not launch the host oracle before the VM's functional phase.
            # Even a background permission probe perturbs WindowServer focus
            # enough to make the real hover/control exercise intermittent.
            # The first requested capture still fails closed if permission is
            # unavailable, without contaminating the preceding stress test.
            if ! "$oracle_launcher" capture --pid "$runner_pid" --output "$output" \
                >>"$artifact_dir/oracle.log" 2>&1; then
                printf 'capture failed: pid=%s output=%s\n' "$runner_pid" "$output" \
                    >>"$artifact_dir/oracle.log"
            fi
        fi
        /bin/mv "$request" "$request.done" 2>/dev/null || true
    done
    sleep 0.05
done
wait "$test_pid"
test_status="$(cat "$artifact_dir/guest.status" 2>/dev/null || echo 1)"
set -e

if [[ "$test_status" -ne 0 ]]; then
    echo "FloatKit VM tests failed. Artifacts: $artifact_dir" >&2
    exit "$test_status"
fi

echo "FloatKit VM tests passed. Artifacts: $artifact_dir"
