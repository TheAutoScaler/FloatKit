import AppKit

guard CommandLine.arguments.count == 4 else { exit(2) }
let label = CommandLine.arguments[1]
guard let reference = NSImage(contentsOfFile: CommandLine.arguments[2]),
      let candidate = NSImage(contentsOfFile: CommandLine.arguments[3]),
      let referenceData = reference.tiffRepresentation,
      let candidateData = candidate.tiffRepresentation,
      let a = NSBitmapImageRep(data: referenceData),
      let b = NSBitmapImageRep(data: candidateData),
      a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { exit(3) }

func luminance(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
    return (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * 255
}

let scale = max(1, CGFloat(a.pixelsWide) / 720)
func detectContentStartX(_ bitmap: NSBitmapImageRep) -> Int {
    let searchWidth = min(bitmap.pixelsWide, Int((60 * scale).rounded()))
    for x in 0..<searchWidth {
        var neutralBright = 0
        var samples = 0
        for pointY in stride(from: 4, through: 28, by: 2) {
            let y = min(bitmap.pixelsHigh - 1, Int((CGFloat(pointY) * scale).rounded()))
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let neutral = (channels.max() ?? 0) - (channels.min() ?? 0) < 0.10
                neutralBright += neutral && luminance(bitmap, x, y) > 180 ? 1 : 0
            }
            samples += 1
        }
        if neutralBright * 4 >= samples * 3 { return x }
    }
    return 0
}
let titleXStart = detectContentStartX(a)
let titleXEnd = min(a.pixelsWide, titleXStart + Int((82 * scale).rounded()))
let titleHeight = min(a.pixelsHigh, Int((32 * scale).rounded()))
let titleYStart = 0
var titleError: CGFloat = 0
var titleSamples: CGFloat = 0
var titleChanged: CGFloat = 0
var backdropError: CGFloat = 0
var backdropSamples: CGFloat = 0
for y in stride(from: titleYStart, to: titleHeight, by: 2) {
    for x in stride(from: titleXStart, to: titleXEnd, by: 2) {
        let delta = abs(luminance(a, x, y) - luminance(b, x, y))
        titleError += delta
        titleChanged += delta > 28 ? 1 : 0
        titleSamples += 1
        let pointX = CGFloat(x - titleXStart) / scale
        let pointYFromTop = CGFloat(y) / scale
        let overlapsTrafficLight = [16.0, 38.0, 60.0].contains { centerX in
            let dx = pointX - centerX
            let dy = pointYFromTop - 14
            return dx * dx + dy * dy <= 12 * 12
        }
        let isRightSeam = pointX >= 72 && pointX <= 81
        let isBottomStrip = pointX >= 5 && pointX <= 81
            && pointYFromTop >= 25 && pointYFromTop <= 30
        if !overlapsTrafficLight, (isRightSeam || isBottomStrip),
           pointYFromTop >= 2, pointYFromTop <= 30 {
            backdropError += delta
            backdropSamples += 1
        }
    }
}

var bodyError: CGFloat = 0
var bodySamples: CGFloat = 0
var sharpA: CGFloat = 0
var sharpB: CGFloat = 0
for y in stride(from: titleHeight + 2, to: max(titleHeight + 3, a.pixelsHigh - 2), by: 2) {
    for x in stride(from: 2, to: a.pixelsWide - 2, by: 2) {
        let av = luminance(a, x, y)
        let bv = luminance(b, x, y)
        bodyError += abs(av - bv)
        sharpA += abs(av - luminance(a, x + 1, y)) + abs(av - luminance(a, x, y + 1))
        sharpB += abs(bv - luminance(b, x + 1, y)) + abs(bv - luminance(b, x, y + 1))
        bodySamples += 1
    }
}

let titleMAE = titleError / max(1, titleSamples)
let changedFraction = titleChanged / max(1, titleSamples)
var seamError: CGFloat = 0
var seamSamples: CGFloat = 0
var referenceSeamError: CGFloat = 0
var titleMaterialSamples: CGFloat = 0
let materialXStart = min(a.pixelsWide, titleXStart + Int((110 * scale).rounded()))
let materialXEnd = max(materialXStart, a.pixelsWide - Int((24 * scale).rounded()))
func titleMaterialIntrusionFraction(_ bitmap: NSBitmapImageRep) -> CGFloat {
    var intrusions: CGFloat = 0
    var samples: CGFloat = 0
    for y in stride(from: titleYStart, to: titleHeight, by: 2) {
        let pointYFromTop = CGFloat(y) / scale
        guard pointYFromTop >= 2, pointYFromTop <= 24 else { continue }
        var material: [CGFloat] = []
        if materialXEnd > materialXStart {
            for x in stride(from: materialXStart, to: materialXEnd, by: 2) {
                material.append(luminance(bitmap, x, y))
            }
        }
        material.sort()
        guard !material.isEmpty else { continue }
        let dominantBrightMaterial = material[min(material.count - 1, material.count * 9 / 10)]
        let titleCenter = (titleXStart + materialXEnd) / 2
        let legitimateTitleHalfWidth = Int(CGFloat(materialXEnd - titleXStart) * 0.22)
        for x in stride(from: titleXStart + Int((82 * scale).rounded()), to: materialXEnd, by: 2) {
            if abs(x - titleCenter) <= legitimateTitleHalfWidth { continue }
            if luminance(bitmap, x, y) < dominantBrightMaterial - 25 {
                intrusions += 1
            }
            samples += 1
        }
    }
    return intrusions / max(1, samples)
}
let referenceTitleMaterialIntrusionFraction = titleMaterialIntrusionFraction(a)
let candidateTitleMaterialIntrusionFraction = titleMaterialIntrusionFraction(b)
for y in stride(from: titleYStart, to: titleHeight, by: 2) {
    let pointYFromTop = CGFloat(y) / scale
    guard pointYFromTop >= 2, pointYFromTop <= 24 else { continue }
    var material: [CGFloat] = []
    var referenceMaterial: [CGFloat] = []
    if materialXEnd > materialXStart {
        for x in stride(from: materialXStart, to: materialXEnd, by: 2) {
            material.append(luminance(b, x, y))
            referenceMaterial.append(luminance(a, x, y))
        }
    }
    material.sort()
    referenceMaterial.sort()
    guard !material.isEmpty else { continue }
    let dominantBrightMaterial = material[min(material.count - 1, material.count * 9 / 10)]
    let referenceDominantBrightMaterial = referenceMaterial[
        min(referenceMaterial.count - 1, referenceMaterial.count * 9 / 10)
    ]
    let seamStart = titleXStart + Int((72 * scale).rounded())
    let seamEnd = min(titleXEnd, titleXStart + Int((82 * scale).rounded()))
    for x in stride(from: seamStart, to: seamEnd, by: 2) {
        seamError += abs(luminance(b, x, y) - dominantBrightMaterial)
        referenceSeamError += abs(luminance(a, x, y) - referenceDominantBrightMaterial)
        seamSamples += 1
    }
}
let backdropMAE = seamError / max(1, seamSamples)
let referenceBackdropMAE = referenceSeamError / max(1, seamSamples)
var upperTitleMaterial: [CGFloat] = []
let upperTitleY = min(a.pixelsHigh - 1, Int((24 * scale).rounded()))
if materialXEnd > materialXStart {
    for x in stride(from: materialXStart, to: materialXEnd, by: 2) {
        upperTitleMaterial.append(luminance(b, x, upperTitleY))
    }
}
upperTitleMaterial.sort()
let upperTitleMedian = upperTitleMaterial.isEmpty ? 0 : upperTitleMaterial[upperTitleMaterial.count / 2]
var separatorRowMedians: [CGFloat] = []
for pointY in 27...33 {
    let y = min(a.pixelsHigh - 1, Int((CGFloat(pointY) * scale).rounded()))
    var row: [CGFloat] = []
    if materialXEnd > materialXStart {
        for x in stride(from: materialXStart, to: materialXEnd, by: 2) {
            row.append(luminance(b, x, y))
        }
    }
    row.sort()
    if !row.isEmpty { separatorRowMedians.append(row[row.count / 2]) }
}
let separatorContrast = upperTitleMedian - (separatorRowMedians.min() ?? upperTitleMedian)
let bodyMAE = bodyError / max(1, bodySamples)
let sharpnessRatio = sharpB / max(0.001, sharpA)
var cornerError: CGFloat = 0
var cornerSamples: CGFloat = 0
let cornerExtent = min(a.pixelsWide, a.pixelsHigh, Int((9 * scale).rounded()))
for y in 0..<cornerExtent {
    for x in 0..<cornerExtent {
        cornerError += abs(luminance(a, x, y) - luminance(b, x, y))
        cornerSamples += 1
    }
}
let topLeftCornerMAE = cornerError / max(1, cornerSamples)
print("VISUAL \(label) content_x=\(titleXStart) title_mae=\(titleMAE) title_changed=\(changedFraction) backdrop_mae=\(backdropMAE) native_backdrop_mae=\(referenceBackdropMAE) title_intrusions=\(candidateTitleMaterialIntrusionFraction) native_title_intrusions=\(referenceTitleMaterialIntrusionFraction) separator_contrast=\(separatorContrast) corner_mae=\(topLeftCornerMAE) body_mae=\(bodyMAE) sharpness_ratio=\(sharpnessRatio)")

// The synthetic fixture deliberately begins drawing title text immediately
// after the traffic lights, inside the repaired strip's right-edge probe.
// Use the seam oracle for real TextEdit captures, where that area is native
// title-bar material, and retain the broader title comparison for fixtures.
let realTextEdit = label.hasPrefix("textedit-")
let backdropPass = !realTextEdit || backdropMAE <= referenceBackdropMAE + 1.0
// Compare with the native capture rather than an absolute darkness threshold:
// legitimate title glyphs and content behind translucent material vary by app.
let titleMaterialPass = !realTextEdit
    || candidateTitleMaterialIntrusionFraction <= referenceTitleMaterialIntrusionFraction + 0.01
// A maximized TextEdit window can intentionally merge its title material into
// the screen edge. The separator regression targets the ordinary pinned-window
// titlebar, where the user reported the missing bottom border.
let separatorPass = !realTextEdit || label == "textedit-maximized" || separatorContrast > 5
let maximizedCornerPass = !label.contains("maximized") || topLeftCornerMAE < 8
guard titleMAE < (realTextEdit ? 16 : 22), changedFraction < 0.22,
      backdropPass, titleMaterialPass, separatorPass, maximizedCornerPass, bodyMAE < 10,
      sharpnessRatio > 0.88, sharpnessRatio < 1.12 else { exit(1) }
