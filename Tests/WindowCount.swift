import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let windows = CGWindowListCopyWindowInfo(
        .optionOnScreenOnly,
        kCGNullWindowID
      ) as? [[String: Any]]
else {
    exit(2)
}

let allOwned = windows.compactMap { window -> CGRect? in
    guard
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 5,
        frame.height > 5
    else { return nil }
    return frame
}

// Ignore the short-lived 220x50 pin confirmation HUD. It is not part of the
// pinned mirror/control topology being asserted here.
let owned = allOwned.filter {
    // WindowServer may compatibility-scale the 220x50 confirmation HUD.
    !(($0.width >= 170 && $0.width <= 230) && ($0.height >= 35 && $0.height <= 60))
}

guard let mirror = owned.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
    print("0 0 1")
    exit(0)
}

let controls = owned.filter {
    $0.width >= 60 && $0.width <= 82 && $0.height >= 20 && $0.height <= 32
}
let aligned = controls.contains {
    abs($0.minX - mirror.minX) <= 2 && abs($0.minY - mirror.minY) <= 2
}
let control = controls.first ?? .zero
let display = CGDisplayBounds(CGMainDisplayID())
print("\(owned.count) \(controls.isEmpty ? 0 : 1) \(aligned ? 1 : 0) \(mirror.minX) \(mirror.minY) \(control.minX) \(control.minY) \(mirror.width) \(mirror.height) \(control.width) \(control.height) \(display.width) \(display.height)")
