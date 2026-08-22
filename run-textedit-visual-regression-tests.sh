#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
artifact_dir="${1:-$(mktemp -d /tmp/floatkit-textedit-visual-artifacts.XXXXXX)}"
test_root="$(mktemp -d /tmp/floatkit-textedit-visual.XXXXXX)"
compare_bin="$test_root/pixel-compare"
window_count_bin="$test_root/window-count"
textedit_pid=""
floatkit_pid=""

cleanup() {
    [[ -z "$floatkit_pid" ]] || kill "$floatkit_pid" 2>/dev/null || true
    [[ -z "$textedit_pid" ]] || kill "$textedit_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT
mkdir -p "$artifact_dir"
xcrun swiftc Tests/PixelCompare.swift -framework AppKit -o "$compare_bin"
xcrun swiftc Tests/WindowCount.swift -framework CoreGraphics -o "$window_count_bin"

document="$test_root/FloatKit TextEdit Regression.txt"
zoom_request="$test_root/zoom.request"
for row in $(seq 0 20); do
    printf 'Sharp TextEdit row %s: MWmw 0123456789 /model openai/gpt-5.6-luna\n' "$row"
done > "$document"
open -n -a TextEdit "$document"
for _ in $(seq 1 100); do
    textedit_pid="$(pgrep -n -x TextEdit || true)"
    [[ -n "$textedit_pid" ]] && "$window_count_bin" "$textedit_pid" | grep -qv '^0 ' && break
    sleep 0.05
done
[[ -n "$textedit_pid" ]] || { echo 'TextEdit did not launch' >&2; exit 1; }

read_frame() {
    local sample
    sample="$($window_count_bin "$textedit_pid")"
    read -r _ _ _ frame_x frame_y _ _ frame_width frame_height _ _ display_width display_height <<< "$sample"
    [[ -n "${frame_x:-}" && "$frame_width" != 0 ]] || return 1
    read -r frame_x frame_y frame_width frame_height display_width display_height <<< "$(awk \
        -v x="$frame_x" -v y="$frame_y" -v w="$frame_width" -v h="$frame_height" \
        -v dw="$display_width" -v dh="$display_height" \
        'BEGIN { printf "%.0f %.0f %.0f %.0f %.0f %.0f", x, y, w, h, dw, dh }')"
}

capture() {
    local name="textedit-$1"
    for _ in $(seq 1 50); do read_frame && break; sleep 0.05; done
    local request="$artifact_dir/capture-$name.request"
    local response="$artifact_dir/$name-full.png"
    printf '%s %s\n' "$display_width" "$display_height" > "$request"
    for _ in $(seq 1 160); do [[ -s "$response" ]] && break; sleep 0.05; done
    [[ -s "$response" ]] || { echo "Host framebuffer capture timed out" >&2; exit 1; }
    local image_width image_height scale toolbar crop_x crop_y crop_width crop_height
    image_width="$(sips -g pixelWidth "$response" | awk '/pixelWidth:/{print $2}')"
    image_height="$(sips -g pixelHeight "$response" | awk '/pixelHeight:/{print $2}')"
    read -r scale toolbar crop_x crop_y crop_width crop_height <<< "$(awk \
        -v iw="$image_width" -v ih="$image_height" -v dw="$display_width" -v dh="$display_height" \
        -v x="$frame_x" -v y="$frame_y" -v w="$frame_width" -v h="$frame_height" \
        'BEGIN { s=iw/dw; t=ih-(dh*s); printf "%.6f %.0f %.0f %.0f %.0f %.0f", s,t,x*s,t+y*s,w*s,h*s }')"
    [[ "$toolbar" -ge 0 ]] || { echo "Invalid host framebuffer geometry" >&2; exit 1; }
    sips --cropToHeightWidth "$crop_height" "$crop_width" --cropOffset "$crop_y" "$crop_x" \
        "$response" --out "$artifact_dir/$name.png" >/dev/null
}

sleep 1
capture native-normal

open -n -g -o "$test_root/floatkit.log" --stderr "$test_root/floatkit.log" \
    --env NSUnbufferedIO=YES /Applications/FloatKit.app \
    --args pin TextEdit --pid "$textedit_pid" --visual-zoom-after "$zoom_request"
for _ in $(seq 1 100); do
    floatkit_pid="$(pgrep -n -f '/Applications/FloatKit.app/Contents/MacOS/FloatKit pin TextEdit' || true)"
    [[ -n "$floatkit_pid" ]] && break
    sleep 0.05
done
sleep 2
capture pinned-normal
cp "$test_root/floatkit.log" "$artifact_dir/textedit-floatkit.log"

"$compare_bin" textedit-normal "$artifact_dir/textedit-native-normal.png" \
    "$artifact_dir/textedit-pinned-normal.png" | tee "$artifact_dir/textedit-normal.metrics"
echo "PASS: external visual oracle matched the real TextEdit document composition"

normal_width="$frame_width"
normal_height="$frame_height"
touch "$zoom_request"
for _ in $(seq 1 160); do
    read_frame || true
    if [[ "$frame_width" -gt $((normal_width + 20)) \
          || "$frame_height" -gt $((normal_height + 20)) ]]; then
        break
    fi
    sleep 0.05
done
[[ "$frame_width" -gt $((normal_width + 20)) \
   || "$frame_height" -gt $((normal_height + 20)) ]] || {
    echo 'TextEdit did not enter its zoomed state' >&2
    exit 1
}
sleep 3
capture pinned-maximized
cp "$test_root/floatkit.log" "$artifact_dir/textedit-floatkit.log"

kill "$floatkit_pid" 2>/dev/null || true
wait "$floatkit_pid" 2>/dev/null || true
floatkit_pid=""
sleep 0.5
capture native-maximized

"$compare_bin" textedit-maximized "$artifact_dir/textedit-native-maximized.png" \
    "$artifact_dir/textedit-pinned-maximized.png" | tee "$artifact_dir/textedit-maximized.metrics"
echo "PASS: real maximized TextEdit retained native title geometry and text sharpness"
