#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
artifact_dir="${1:-$(mktemp -d /tmp/floatkit-visual-artifacts.XXXXXX)}"
test_root="$(mktemp -d /tmp/floatkit-visual.XXXXXX)"
fixture_app="$test_root/FloatKitVisualFixture.app"
fixture_bin="$fixture_app/Contents/MacOS/FloatKitVisualFixture"
compare_bin="$test_root/pixel-compare"
window_count_bin="$test_root/window-count"
fixture_pid=""
floatkit_pid=""

cleanup() {
    [[ -z "$floatkit_pid" ]] || kill "$floatkit_pid" 2>/dev/null || true
    [[ -z "$fixture_pid" ]] || kill "$fixture_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT
mkdir -p "$artifact_dir" "$fixture_app/Contents/MacOS"
cp Tests/VisualFixture-Info.plist "$fixture_app/Contents/Info.plist"
xcrun swiftc Tests/VisualFixture.swift -framework Cocoa -o "$fixture_bin"
xcrun swiftc Tests/PixelCompare.swift -framework AppKit -o "$compare_bin"
xcrun swiftc Tests/WindowCount.swift -framework CoreGraphics -o "$window_count_bin"
codesign --force --sign "${FLOATKIT_CODESIGN_IDENTITY:--}" "$fixture_app" >/dev/null

open -n "$fixture_app" --args "$test_root" document-style
for _ in $(seq 1 100); do [[ -s "$test_root/pid" ]] && break; sleep 0.05; done
fixture_pid="$(tr -d '[:space:]' < "$test_root/pid")"

read_frame() {
    local sample
    sample="$($window_count_bin "$fixture_pid")"
    read -r _ _ _ frame_x frame_y _ _ frame_width frame_height _ _ display_width display_height <<< "$sample"
    [[ -n "${frame_x:-}" && "$frame_width" != 0 ]] || return 1
    read -r frame_x frame_y frame_width frame_height display_width display_height <<< "$(awk \
        -v x="$frame_x" -v y="$frame_y" -v w="$frame_width" -v h="$frame_height" \
        -v dw="$display_width" -v dh="$display_height" \
        'BEGIN { printf "%.0f %.0f %.0f %.0f %.0f %.0f", x, y, w, h, dw, dh }')"
}

capture() {
    local name="$1"
    for _ in $(seq 1 50); do read_frame && break; sleep 0.05; done
    request="$artifact_dir/capture-$name.request"
    response="$artifact_dir/$name-full.png"
    printf '%s %s\n' "$display_width" "$display_height" > "$request"
    for _ in $(seq 1 160); do [[ -s "$response" ]] && break; sleep 0.05; done
    [[ -s "$response" ]] || { echo "Host framebuffer capture timed out" >&2; exit 1; }
    image_width="$(/usr/bin/sips -g pixelWidth "$response" | awk '/pixelWidth:/{print $2}')"
    image_height="$(/usr/bin/sips -g pixelHeight "$response" | awk '/pixelHeight:/{print $2}')"
    read -r scale toolbar crop_x crop_y crop_width crop_height <<< "$(awk \
        -v iw="$image_width" -v ih="$image_height" -v dw="$display_width" -v dh="$display_height" \
        -v x="$frame_x" -v y="$frame_y" -v w="$frame_width" -v h="$frame_height" \
        'BEGIN { s=iw/dw; t=ih-(dh*s); printf "%.6f %.0f %.0f %.0f %.0f %.0f", s,t,x*s,t+y*s,w*s,h*s }')"
    [[ "$toolbar" -ge 0 ]] || { echo "Invalid host framebuffer geometry" >&2; exit 1; }
    /usr/bin/sips --cropToHeightWidth "$crop_height" "$crop_width" \
        --cropOffset "$crop_y" "$crop_x" "$response" \
        --out "$artifact_dir/$name.png" >/dev/null
}

signal_and_wait() {
    local command="$1" marker="$2"
    rm -f "$test_root/$marker"
    : > "$test_root/$command"
    for _ in $(seq 1 100); do [[ -f "$test_root/$marker" ]] && return; sleep 0.05; done
    echo "Timed out waiting for visual fixture $marker" >&2
    exit 1
}

signal_and_wait maximize maximized
capture native-maximized
signal_and_wait restore restored
capture native-normal

open -n -g -o "$test_root/floatkit.log" --stderr "$test_root/floatkit.log" \
    --env NSUnbufferedIO=YES /Applications/FloatKit.app \
    --args pin FloatKitVisualFixture --pid "$fixture_pid"
for _ in $(seq 1 100); do
    floatkit_pid="$(pgrep -n -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit pin FloatKitVisualFixture' || true)"
    [[ -n "$floatkit_pid" ]] && break
    sleep 0.05
done
sleep 2
capture pinned-normal
signal_and_wait maximize maximized
sleep 3
capture pinned-maximized
signal_and_wait restore restored
sleep 3
capture pinned-restored

"$compare_bin" normal "$artifact_dir/native-normal.png" "$artifact_dir/pinned-normal.png" \
    | tee "$artifact_dir/normal.metrics"
"$compare_bin" maximized "$artifact_dir/native-maximized.png" "$artifact_dir/pinned-maximized.png" \
    | tee "$artifact_dir/maximized.metrics"
"$compare_bin" restored "$artifact_dir/native-normal.png" "$artifact_dir/pinned-restored.png" \
    | tee "$artifact_dir/restored.metrics"
echo "PASS: external visual oracle matched zero-overhead native normal, maximized, and restored windows"
