#!/bin/bash

set -euo pipefail

source_dir="${1:?source directory is required}"
artifact_dir="${2:?artifact directory is required}"
work_dir="$HOME/FloatKit-VM-Test"

rm -rf "$work_dir"
mkdir -p "$work_dir" "$artifact_dir"
/usr/bin/ditto "$source_dir" "$work_dir"
cd "$work_dir"

cleanup() {
    /usr/bin/pkill -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit' 2>/dev/null || true
}
trap cleanup EXIT

FLOATKIT_CODESIGN_IDENTITY=- ./build-app.sh
sudo /bin/rm -rf /Applications/FloatKit.app
sudo /usr/bin/ditto build/FloatKit.app /Applications/FloatKit.app
"$work_dir/VM/guest/grant-tcc.sh"

set +e
if [[ "${FLOATKIT_SKIP_CORE:-0}" == 1 ]]; then
    core_status=0
    printf '%s\n' 'SKIP: functional suite disabled for this visual-oracle diagnostic run' >"$artifact_dir/regression.log"
else
    FLOATKIT_CODESIGN_IDENTITY=- \
    ./run-regression-tests.sh >"$artifact_dir/regression.log" 2>&1
    core_status=$?
fi
if [[ "${FLOATKIT_SKIP_VISUAL:-0}" == 1 ]]; then
    visual_status=0
    printf '%s\n' 'SKIP: external compositor capture disabled for this functional-only run' >"$artifact_dir/visual.log"
else
    if [[ "${FLOATKIT_SKIP_GENERIC_VISUAL:-0}" == 1 ]]; then
        visual_status=0
        printf '%s\n' 'SKIP: generic visual fixture disabled for TextEdit diagnostic' >"$artifact_dir/visual.log"
    else
        FLOATKIT_CODESIGN_IDENTITY=- \
        ./run-visual-regression-tests.sh "$artifact_dir" >"$artifact_dir/visual.log" 2>&1
        visual_status=$?
    fi
    if [[ "$visual_status" -eq 0 ]]; then
        FLOATKIT_CODESIGN_IDENTITY=- \
        ./run-textedit-visual-regression-tests.sh "$artifact_dir" >>"$artifact_dir/visual.log" 2>&1
        visual_status=$?
    fi
fi
if [[ "${FLOATKIT_SKIP_CORE:-0}" == 1 ]]; then
    mutation_status=0
    printf '%s\n' 'SKIP: mutation suite disabled for this visual-oracle diagnostic run' >"$artifact_dir/sharpness-mutation.log"
else
    FLOATKIT_CODESIGN_IDENTITY=- \
    ./run-sharpness-mutation-test.sh >"$artifact_dir/sharpness-mutation.log" 2>&1
    mutation_status=$?
fi
status=$((core_status != 0 ? core_status : (visual_status != 0 ? visual_status : mutation_status)))
set -e

/bin/ps -axo pid,ppid,state,etime,command >"$artifact_dir/processes.txt"
/usr/bin/log show --last 10m --style compact \
    --predicate 'process == "FloatKit" OR process == "FloatKitFixture"' \
    >"$artifact_dir/unified.log" 2>&1 || true

if [[ "$status" -ne 0 ]]; then
    cat "$artifact_dir/regression.log"
    [[ ! -f "$artifact_dir/visual.log" ]] || cat "$artifact_dir/visual.log"
    [[ ! -f "$artifact_dir/sharpness-mutation.log" ]] || cat "$artifact_dir/sharpness-mutation.log"
    exit "$status"
fi

cat "$artifact_dir/regression.log"
cat "$artifact_dir/visual.log"
cat "$artifact_dir/sharpness-mutation.log"
