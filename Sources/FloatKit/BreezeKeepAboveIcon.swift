// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Adapted from KDE Breeze Icons' 16px window-keep-above.svg.
// Copyright (C) 2014 Uri Herrera <uri_herrera@nitrux.in> and others.
// Source and licence notice: ../../THIRD-PARTY-LICENSES/Breeze-Icons.txt

import AppKit

func keepAboveVectorImage(active: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let chevrons = [
            [NSPoint(x: 9, y: 14.707), NSPoint(x: 3, y: 8.707),
             NSPoint(x: 3.707, y: 8), NSPoint(x: 9, y: 13.293),
             NSPoint(x: 14.293, y: 8), NSPoint(x: 15, y: 8.707)],
            [NSPoint(x: 9, y: 10.707), NSPoint(x: 3, y: 4.707),
             NSPoint(x: 3.707, y: 4), NSPoint(x: 9, y: 9.293),
             NSPoint(x: 14.293, y: 4), NSPoint(x: 15, y: 4.707)]
        ]

        NSColor.black.setFill()
        let activeCutout = NSBezierPath()
        if active {
            activeCutout.appendOval(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            activeCutout.windingRule = .evenOdd
        }
        for points in chevrons {
            let chevron = NSBezierPath()
            chevron.move(to: points[0])
            points.dropFirst().forEach { chevron.line(to: $0) }
            chevron.close()
            if active {
                activeCutout.append(chevron)
            } else {
                chevron.fill()
            }
        }
        if active {
            activeCutout.fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Keep window above"
    return image
}
