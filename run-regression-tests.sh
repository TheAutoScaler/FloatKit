#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

test_root="$(mktemp -d /tmp/floatkit-regression.XXXXXX)"
fixture_app="$test_root/FloatKitFixture.app"
fixture_bin="$fixture_app/Contents/MacOS/FloatKitFixture"
titleless_app="$test_root/FloatKitTitlelessFixture.app"
titleless_bin="$titleless_app/Contents/MacOS/FloatKitTitlelessFixture"
custom_chrome_app="$test_root/FloatKitCustomChromeFixture.app"
custom_chrome_bin="$custom_chrome_app/Contents/MacOS/FloatKitCustomChromeFixture"
window_count_bin="$test_root/window-count"
floatkit_pid=""
fixture_pid=""
max_mirror_windows=0
saw_control_pair=0
misaligned_controls=0
misaligned_sample=""
misalignment_streak=0
last_window_sample=""

cleanup() {
    if [[ -n "$floatkit_pid" ]]; then
        kill "$floatkit_pid" 2>/dev/null || true
        wait "$floatkit_pid" 2>/dev/null || true
    fi
    if [[ -n "$fixture_pid" ]]; then
        kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fixture_app/Contents/MacOS"
cp Tests/WindowFixture-Info.plist "$fixture_app/Contents/Info.plist"
xcrun swiftc Tests/WindowFixture.swift -framework Cocoa -o "$fixture_bin"
xcrun swiftc Tests/WindowCount.swift -framework CoreGraphics -o "$window_count_bin"
codesign --force --sign "${FLOATKIT_CODESIGN_IDENTITY:-FloatKit Local Code Signing}" \
    "$fixture_app" >/dev/null

mkdir -p "$titleless_app/Contents/MacOS"
sed -e 's/FloatKitFixture/FloatKitTitlelessFixture/g' \
    -e 's/regression-fixture/titleless-regression-fixture/g' \
    Tests/WindowFixture-Info.plist > "$titleless_app/Contents/Info.plist"
xcrun swiftc Tests/TitlelessFixture.swift -framework Cocoa -o "$titleless_bin"
codesign --force --sign "${FLOATKIT_CODESIGN_IDENTITY:-FloatKit Local Code Signing}" \
    "$titleless_app" >/dev/null

mkdir -p "$custom_chrome_app/Contents/MacOS"
sed -e 's/FloatKitFixture/FloatKitCustomChromeFixture/g' \
    -e 's/regression-fixture/custom-chrome-regression-fixture/g' \
    Tests/WindowFixture-Info.plist > "$custom_chrome_app/Contents/Info.plist"
xcrun swiftc Tests/CustomChromeFixture.swift -framework Cocoa -o "$custom_chrome_bin"
codesign --force --sign "${FLOATKIT_CODESIGN_IDENTITY:-FloatKit Local Code Signing}" \
    "$custom_chrome_app" >/dev/null

open -n "$fixture_app" --args "$test_root/fixture.complete" "$test_root/fixture.pid"
for _ in $(seq 1 50); do
    if [[ -s "$test_root/fixture.pid" ]]; then
        fixture_pid="$(tr -d '[:space:]' < "$test_root/fixture.pid")"
        break
    fi
    sleep 0.1
done

if [[ -z "$fixture_pid" ]]; then
    echo "FAIL: fixture application did not launch"
    exit 1
fi

fixture_visible=0
for _ in $(seq 1 50); do
    read -r fixture_window_count _ _ <<< "$("$window_count_bin" "$fixture_pid")"
    if [[ "$fixture_window_count" -ge 1 ]]; then
        fixture_visible=1
        break
    fi
    sleep 0.1
done

if [[ "$fixture_visible" -ne 1 ]]; then
    echo "FAIL: fixture window never became visible"
    exit 1
fi

# A window can appear in Core Graphics slightly before ScreenCaptureKit makes
# it available through SCShareableContent. Avoid testing that unrelated launch
# propagation race instead of FloatKit's pinned-window behaviour.
sleep 1

open_env=(--env NSUnbufferedIO=YES)
[[ -z "${FLOATKIT_TEST_FORCE_CAPTURE_SCALE:-}" ]] || open_env+=(--env "FLOATKIT_TEST_FORCE_CAPTURE_SCALE=$FLOATKIT_TEST_FORCE_CAPTURE_SCALE")
[[ -z "${FLOATKIT_TEST_REQUIRED_CAPTURE_SCALE:-}" ]] || open_env+=(--env "FLOATKIT_TEST_REQUIRED_CAPTURE_SCALE=$FLOATKIT_TEST_REQUIRED_CAPTURE_SCALE")
open -n -g -o "$test_root/floatkit.log" --stderr "$test_root/floatkit.log" \
    "${open_env[@]}" /Applications/FloatKit.app \
    --args pin FloatKitFixture --pid "$fixture_pid" \
    --exercise-input-after "$test_root/fixture.complete" \
    --unpin-after "$test_root/unpin.request"
for _ in $(seq 1 50); do
    floatkit_pid="$(pgrep -n -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit pin FloatKitFixture' || true)"
    if [[ -n "$floatkit_pid" ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "$floatkit_pid" ]]; then
    echo "FAIL: FloatKit test instance did not launch"
    exit 1
fi

for _ in $(seq 1 180); do
    last_window_sample="$("$window_count_bin" "$floatkit_pid")"
    read -r current_mirror_windows has_controls controls_aligned \
        mirror_x mirror_y control_x control_y mirror_width mirror_height \
        control_width control_height <<< "$last_window_sample"
    if [[ "$current_mirror_windows" -gt "$max_mirror_windows" ]]; then
        max_mirror_windows="$current_mirror_windows"
    fi
    if [[ "$has_controls" -eq 1 ]]; then
        saw_control_pair=1
        control_dx="$(awk -v c="$control_x" -v m="$mirror_x" 'BEGIN { print c - m }')"
        control_dy="$(awk -v c="$control_y" -v m="$mirror_y" 'BEGIN { print c - m }')"
        if ! awk -v x="$control_dx" -v y="$control_dy" '
            function abs(v) { return v < 0 ? -v : v }
            BEGIN {
                exit(abs(x) <= 32 && abs(y) <= 20 ? 0 : 1)
            }'; then
            misalignment_streak=$((misalignment_streak + 1))
            if [[ "$misalignment_streak" -ge 5 ]]; then
                misaligned_controls=1
                misaligned_sample="$last_window_sample"
            fi
        else
            misalignment_streak=0
        fi
    fi
    if [[ -f "$test_root/fixture.complete" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -f "$test_root/fixture.complete" ]]; then
    echo "FAIL: fixture did not finish the stress sequence"
    exit 1
fi

for _ in $(seq 1 250); do
    if rg -q '^\[diag\] window control actions verified$' "$test_root/floatkit.log"; then break; fi
    sleep 0.1
done

if rg -q 'capture failed|recovery attempt .* failed|window control invariant failed|mirror geometry commit timed out|fresh mirror frame timed out|manipulation overlay remained visible|window control actions failed|minimise-all native animation failed|post-zoom titlebar or Retina capture failed|maximized overlay corner invariant failed|status icon state invariant failed|unpin overlay remained visible|unpin all interaction path blocked|regression unpin trigger timed out|regression controls unavailable|regression control trigger timed out|passive overlay invariant failed|pinned window input failed|regression editor unavailable|regression editor geometry unavailable|regression input trigger timed out|input routing event tap unavailable|regression routed drag unavailable|FloatKit control surface obstructed top-left resize borders|restored window controls were not hit-testable|active native presentation invariant failed' "$test_root/floatkit.log"; then
    echo "FAIL: FloatKit lost the pin or capture during the stress sequence"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] deactivation presented retained mirror without a blank frame$' "$test_root/floatkit.log"; then
    echo "FAIL: click-away transition did not synchronously retain a visible frame"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] click-away controls remained continuously visible$' "$test_root/floatkit.log"; then
    echo "FAIL: click-away recovery hid and recreated the window controls"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] window controls remained hit-testable after minimize and restore$' "$test_root/floatkit.log"; then
    echo "FAIL: minimize/restore did not preserve all window-control hit targets"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] top-left resize borders remain outside FloatKit hit surfaces$' "$test_root/floatkit.log"; then
    echo "FAIL: FloatKit did not prove its top-left resize bands are unobstructed"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] activation retained mirror until native window was ready$' "$test_root/floatkit.log"; then
    echo "FAIL: active/native transition did not retain the mirror until WindowServer was ready"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] live accessibility edited title and native alignment applied$' "$test_root/floatkit.log"; then
    echo "FAIL: edited pinned title was not left-aligned with its Edited suffix"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] manipulation overlays hidden synchronously$' "$test_root/floatkit.log"; then
    echo "FAIL: manipulation did not synchronously remove both overlays"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] resized mirror revealed with fresh capture frame$' "$test_root/floatkit.log"; then
    echo "FAIL: resized mirror fresh-frame reveal assertion did not run"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] maximized overlay uses square corners$' "$test_root/floatkit.log"; then
    echo "FAIL: maximized overlay square-corner assertion did not run"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] adaptive capture rate verified: fps=(24|30) ' "$test_root/floatkit.log"; then
    echo "FAIL: large-window capture did not reduce full-resolution frame bandwidth"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] direct native presentation enabled$' "$test_root/floatkit.log" \
    || ! rg -q '^\[diag\] direct native presentation disabled$' "$test_root/floatkit.log"; then
    echo "FAIL: active pinned windows did not switch between native and mirrored presentation"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] active native presentation capture and overlays stopped$' "$test_root/floatkit.log"; then
    echo "FAIL: active pinned window retained capture or a FloatKit overlay"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] live accessibility window title applied$' "$test_root/floatkit.log"; then
    echo "FAIL: pinned standard window did not receive its live Accessibility title"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] ready and pinned status icon states verified$' "$test_root/floatkit.log"; then
    echo "FAIL: two-state status icon assertion did not run"
    cat "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] post-zoom titlebar and Retina capture verified$' "$test_root/floatkit.log"; then
    echo "FAIL: restored window did not retain its repaired title bar at Retina resolution"
    sed -n '1,260p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] active native content bypassed mirror updates$' "$test_root/floatkit.log"; then
    echo "FAIL: active source still used mirror capture"
    sed -n '1,260p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] input routing event tap verified$' "$test_root/floatkit.log"; then
    echo "FAIL: pre-dispatch pinned-window input routing was not installed"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] obscured pinned-window click routed$' "$test_root/floatkit.log"; then
    echo "FAIL: overlapping-window click never entered the routing path"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] passive rounded overlay verified$' "$test_root/floatkit.log"; then
    echo "FAIL: mirror focus, native shadow, or rounded-content invariant failed"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] pinned window click and keyboard input verified$' "$test_root/floatkit.log"; then
    echo "FAIL: pinned fixture did not accept a real click and keyboard input after stress"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] window control actions verified$' "$test_root/floatkit.log"; then
    echo "FAIL: close, minimise, and zoom action regression did not complete"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] minimise-all native animation verified$' "$test_root/floatkit.log"; then
    echo "FAIL: minimise all did not use the native pinned-window path"
    sed -n '1,260p' "$test_root/floatkit.log"
    exit 1
fi

if [[ "$max_mirror_windows" -gt 2 ]]; then
    echo "FAIL: expected one mirror and one control strip, found $max_mirror_windows windows"
    exit 1
fi

if [[ "$misaligned_controls" -ne 0 ]]; then
    echo "FAIL: the control strip remained detached from the mirror for five consecutive samples"
    echo "Misaligned FloatKit window sample: $misaligned_sample"
    exit 1
fi

if ! rg -q '^\[diag\] window controls verified$' "$test_root/floatkit.log"; then
    echo "FAIL: close, minimise, and zoom controls were never verified"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] overlay window control click verified$' "$test_root/floatkit.log"; then
    echo "FAIL: control actions bypassed the overlay hit targets"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

if ! rg -q '^\[diag\] window control hover glyphs verified$' "$test_root/floatkit.log"; then
    echo "FAIL: traffic-light hover glyphs were not displayed"
    sed -n '1,240p' "$test_root/floatkit.log"
    exit 1
fi

touch "$test_root/unpin.request"
for _ in $(seq 1 50); do
    if rg -q '^\[diag\] unpin overlay hidden synchronously$' "$test_root/floatkit.log"; then break; fi
    sleep 0.02
done
if ! rg -q '^\[diag\] unpin overlay hidden synchronously$' "$test_root/floatkit.log"; then
    echo "FAIL: unpin did not remove both overlay surfaces synchronously"
    sed -n '1,280p' "$test_root/floatkit.log"
    exit 1
fi
if ! rg -q '^\[diag\] unpin all overlays hidden atomically$' "$test_root/floatkit.log"; then
    echo "FAIL: unpin all did not hide every overlay in one compositor transaction"
    sed -n '1,300p' "$test_root/floatkit.log"
    exit 1
fi
if ! rg -q '^\[diag\] unpin all interaction path stayed nonblocking$' "$test_root/floatkit.log"; then
    echo "FAIL: unpin all did not complete its interaction path synchronously"
    sed -n '1,300p' "$test_root/floatkit.log"
    exit 1
fi

kill "$floatkit_pid" 2>/dev/null || true
wait "$floatkit_pid" 2>/dev/null || true
floatkit_pid=""
kill "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

open -n "$custom_chrome_app" --args "$test_root/custom-chrome.ready" "$test_root/custom-chrome.pid"
for _ in $(seq 1 50); do
    if [[ -s "$test_root/custom-chrome.pid" ]]; then
        fixture_pid="$(tr -d '[:space:]' < "$test_root/custom-chrome.pid")"
        break
    fi
    sleep 0.1
done
if [[ -z "$fixture_pid" || ! -f "$test_root/custom-chrome.ready" ]]; then
    echo "FAIL: custom-chrome fixture did not launch"
    exit 1
fi
sleep 1
open -n -g -o "$test_root/custom-chrome-floatkit.log" --stderr "$test_root/custom-chrome-floatkit.log" \
    --env NSUnbufferedIO=YES /Applications/FloatKit.app \
    --args pin FloatKitCustomChromeFixture --pid "$fixture_pid"
for _ in $(seq 1 120); do
    floatkit_pid="$(pgrep -n -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit pin FloatKitCustomChromeFixture' || true)"
    if [[ -n "$floatkit_pid" ]] && rg -q '^\[diag\] custom chrome retained interactive window controls$' "$test_root/custom-chrome-floatkit.log"; then
        break
    fi
    sleep 0.1
done
if [[ -z "$floatkit_pid" ]] || ! rg -q '^\[diag\] custom chrome retained interactive window controls$' "$test_root/custom-chrome-floatkit.log"; then
    echo "FAIL: custom-chrome classification did not retain window controls"
    cat "$test_root/custom-chrome-floatkit.log"
    exit 1
fi
# Active custom-chrome windows now use their exact native controls. Activate a
# different application before asserting FloatKit's background replacement.
open -a Finder
sleep 1
for _ in $(seq 1 100); do
    read -r custom_windows custom_has_controls _ <<< "$("$window_count_bin" "$floatkit_pid")"
    if [[ "$custom_windows" -eq 2 && "$custom_has_controls" -eq 1 ]]; then break; fi
    sleep 0.05
done
if [[ "$custom_windows" -ne 2 || "$custom_has_controls" -ne 1 ]]; then
    echo "FAIL: custom-chrome window lost its replacement traffic-light controls"
    cat "$test_root/custom-chrome-floatkit.log"
    exit 1
fi
if ! rg -q '^\[diag\] window controls verified$' "$test_root/custom-chrome-floatkit.log"; then
    echo "FAIL: custom-chrome controls or bounded pill repair did not render correctly"
    cat "$test_root/custom-chrome-floatkit.log"
    exit 1
fi
kill "$floatkit_pid" 2>/dev/null || true
wait "$floatkit_pid" 2>/dev/null || true
floatkit_pid=""
kill "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

open -n "$titleless_app" --args "$test_root/titleless.ready" "$test_root/titleless.pid"
for _ in $(seq 1 50); do
    if [[ -s "$test_root/titleless.pid" ]]; then
        fixture_pid="$(tr -d '[:space:]' < "$test_root/titleless.pid")"
        break
    fi
    sleep 0.1
done
if [[ -z "$fixture_pid" || ! -f "$test_root/titleless.ready" ]]; then
    echo "FAIL: titleless fixture did not launch"
    exit 1
fi
sleep 1
open -n -g -o "$test_root/titleless-floatkit.log" --stderr "$test_root/titleless-floatkit.log" \
    --env NSUnbufferedIO=YES /Applications/FloatKit.app \
    --args pin FloatKitTitlelessFixture --pid "$fixture_pid"
for _ in $(seq 1 100); do
    floatkit_pid="$(pgrep -n -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit pin FloatKitTitlelessFixture' || true)"
    if [[ -n "$floatkit_pid" ]] && rg -q '^\[diag\] titleless window retained native captured chrome$' "$test_root/titleless-floatkit.log"; then
        break
    fi
    sleep 0.1
done
if [[ -z "$floatkit_pid" ]] || ! rg -q '^\[diag\] titleless window retained native captured chrome$' "$test_root/titleless-floatkit.log"; then
    echo "FAIL: titleless-window classification did not complete"
    cat "$test_root/titleless-floatkit.log"
    exit 1
fi
sleep 0.2
read -r titleless_windows titleless_has_controls _ <<< "$("$window_count_bin" "$floatkit_pid")"
if [[ "$titleless_windows" -gt 1 || "$titleless_has_controls" -ne 0 ]]; then
    echo "FAIL: titleless window received a synthetic title bar or traffic-light strip"
    cat "$test_root/titleless-floatkit.log"
    exit 1
fi
if rg -q 'titleless window received synthetic titlebar chrome' "$test_root/titleless-floatkit.log"; then
    echo "FAIL: titleless-window invariant reported synthetic chrome"
    cat "$test_root/titleless-floatkit.log"
    exit 1
fi
kill "$floatkit_pid" 2>/dev/null || true
wait "$floatkit_pid" 2>/dev/null || true
floatkit_pid=""
kill "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

echo "PASS: 40 moves, 40 resizes, 10 zoom toggles, and 40 mixed operations"
echo "PASS: pin survived the complete sequence"
echo "PASS: exactly one aligned close/minimise/zoom control strip was present"
echo "PASS: no extra FloatKit overlay windows detected"
echo "PASS: real click and keyboard input remained responsive after stress"
echo "PASS: passive rounded mirror retained its own native shadow without taking focus"
echo "PASS: fast title-bar drag survived obscured-window input routing"
echo "PASS: stationary text changes reached the mirror capture renderer"
echo "PASS: maskless full-strip repair removed the maximised-window pill silhouette"
echo "PASS: zoom/restore retained the repaired title bar at Retina resolution"
echo "PASS: traffic-light hover glyphs appeared through real pointer movement"
echo "PASS: individual and minimise-all actions used native animated window controls"
echo "PASS: unpin removed both overlay surfaces synchronously before capture teardown"
echo "PASS: unpin all hid every overlay in one compositor transaction"
echo "PASS: truly borderless windows received no synthetic title bar or controls"
echo "PASS: custom-chrome windows retained interactive controls with a bounded pill repair"
echo "PASS: movement hid overlays synchronously and resize reveal waited for a fresh capture frame"
echo "PASS: active windows stopped capture and background mirrors used adaptive 24/30 fps"
echo "PASS: pinned standard windows retained their live Accessibility titles"
