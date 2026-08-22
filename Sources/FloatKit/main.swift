import Cocoa
import Carbon
import ScreenCaptureKit
import AVFoundation

private let controlStripWidth: CGFloat = 76
private let controlStripHeight: CGFloat = 28
private let controlResizeInset: CGFloat = 5
private let titlebarRepairHeight: CGFloat = 32

// Window mirroring is adapted from PinWindow by justwy (MIT License).
// See THIRD-PARTY-LICENSES/PinWindow.txt.

// MARK: - Screen Capture Manager

class CaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let captureQueue = DispatchQueue(
        label: "io.github.theautoscaler.floatkit.capture",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var _capturing = false
    private var _completedFrameCount: UInt64 = 0
    private var _lastFrameSignature: UInt64 = 0
    private var _titlebarBackdropSignature: UInt64 = 0
    private var _configuredPixelSize = CGSize.zero
    private var _configuredPointSize = CGSize.zero
    private var _deliveredPixelSize = CGSize.zero
    private var _deliveredScaleFactor: CGFloat = 0
    private var _repairImageSize = CGSize.zero
    private var _repairRows: [UInt8] = []
    private var _didLogContentGeometry = false
    private var sourceWindowID: CGWindowID = 0
    private var reconfigurationGeneration: UInt64 = 0
    var onError: (() -> Void)?
    var onTitlebarBackdrop: ((CGImage, UInt64) -> Void)?

    private func targetFrameRate(width: Int, height: Int) -> Int32 {
        let pixels = width * height
        if pixels > 5_000_000 { return 24 }
        if pixels > 1_500_000 { return 30 }
        return 60
    }

    var capturing: Bool {
        stateLock.withLock { _capturing }
    }

    var frameState: (count: UInt64, signature: UInt64) {
        stateLock.withLock { (_completedFrameCount, _lastFrameSignature) }
    }

    var titlebarBackdropSignature: UInt64 {
        stateLock.withLock { _titlebarBackdropSignature }
    }

    var configuredPixelSize: CGSize {
        stateLock.withLock { _configuredPixelSize }
    }

    var deliveredFrameGeometry: (pixels: CGSize, scaleFactor: CGFloat) {
        stateLock.withLock { (_deliveredPixelSize, _deliveredScaleFactor) }
    }

    var repairImageSize: CGSize {
        stateLock.withLock { _repairImageSize }
    }

    var repairRows: [UInt8] {
        stateLock.withLock { _repairRows }
    }

    func startCapture(window: SCWindow, scale: CGFloat) async throws {
        if stream != nil { return }
        sourceWindowID = window.windowID
        stateLock.withLock { _didLogContentGeometry = false }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14, *) {
            // This stream is an on-device window mirror, not a presentation.
            // The system-default presenter alert can replace the captured
            // window's traffic lights with a purple sharing control.
            config.presenterOverlayPrivacyAlertSetting = .never
            config.captureResolution = .best
        }
        // Apple’s window-capture sample requests the desired pixel dimensions
        // directly. Asking ScreenCaptureKit to scale independently captured
        // content can upsample a 1x source surface and make text permanently
        // soft even though the delivered buffer reports the requested size.
        config.scalesToFit = false
        // ScreenCaptureKit needs enough IOSurface slots to keep producing
        // frames while the display layer owns the previous buffer. A depth of
        // one can starve after resize/reconfiguration and leave a blank mirror.
        config.queueDepth = 3

        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Match the destination screen's backing scale. Capturing one pixel
        // per point makes text visibly soft, especially after zooming a window
        // to fill a Retina display.
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        let frameRate = targetFrameRate(width: config.width, height: config.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        config.sourceRect = CGRect(origin: .zero, size: filter.contentRect.size)
        config.destinationRect = CGRect(
            x: 0, y: 0, width: config.width, height: config.height
        )
        stateLock.withLock {
            _configuredPixelSize = CGSize(width: config.width, height: config.height)
            _configuredPointSize = filter.contentRect.size
        }
        if frameRate < 60 {
            print("[diag] adaptive capture rate verified: fps=\(frameRate) pixels=\(config.width)x\(config.height)")
            fflush(stdout)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()
        stateLock.withLock { _capturing = true }
    }

    func stopCapture() {
        if let s = stream {
            s.stopCapture { _ in }
        }
        stream = nil
        stateLock.withLock { _capturing = false }
    }

    func updateCaptureSize(width: CGFloat, height: CGFloat, scale: CGFloat) {
        guard let s = stream else { return }
        let previousPointSize = stateLock.withLock { _configuredPointSize }
        let widthRatio = previousPointSize.width > 0 ? width / previousPointSize.width : 1
        let heightRatio = previousPointSize.height > 0 ? height / previousPointSize.height : 1
        let requiresFreshStream = widthRatio > 1.5 || heightRatio > 1.5
            || widthRatio < (1.0 / 1.5) || heightRatio < (1.0 / 1.5)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14, *) {
            config.presenterOverlayPrivacyAlertSetting = .never
            config.captureResolution = .best
        }
        // Request exact native backing dimensions. ScreenCaptureKit's
        // scale-to-fit path can resample glyphs even when the resulting buffer
        // has the nominally correct size.
        config.scalesToFit = false
        config.queueDepth = 3
        config.width = max(1, Int((width * scale).rounded()))
        config.height = max(1, Int((height * scale).rounded()))
        let frameRate = targetFrameRate(width: config.width, height: config.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        config.sourceRect = CGRect(x: 0, y: 0, width: width, height: height)
        config.destinationRect = CGRect(
            x: 0, y: 0, width: config.width, height: config.height
        )
        stateLock.withLock {
            _configuredPixelSize = CGSize(width: config.width, height: config.height)
            _configuredPointSize = CGSize(width: width, height: height)
        }
        if frameRate < 60 {
            print("[diag] adaptive capture rate verified: fps=\(frameRate) pixels=\(config.width)x\(config.height)")
            fflush(stdout)
        }
        // Never stretch the previous, smaller IOSurface across a newly
        // maximised destination while updateConfiguration settles.
        if #available(macOS 15, *) {
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.flushAndRemoveImage()
        }
        reconfigurationGeneration &+= 1
        let generation = reconfigurationGeneration
        let windowID = sourceWindowID

        // SCContentFilter retains the SCWindow geometry from the shareable-
        // content snapshot used to create it. Updating only the configuration
        // after a zoom therefore asks ScreenCaptureKit to enlarge the original
        // small content rectangle. Refresh the SCWindow/filter first, then
        // request the new output size.
        SCShareableContent.getExcludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) { [weak self, weak s] content, error in
            guard let self, let s, generation == self.reconfigurationGeneration else { return }
            guard let refreshed = content?.windows.first(where: { $0.windowID == windowID }) else {
                print("[warn] resize filter refresh failed: \(String(describing: error))")
                s.updateConfiguration(config) { err in
                    if let err { print("[warn] updateConfig: \(err)") }
                }
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: refreshed)
            guard requiresFreshStream else {
                s.updateContentFilter(filter) { [weak self, weak s] filterError in
                    guard let self, let s,
                          generation == self.reconfigurationGeneration else { return }
                    if let filterError { print("[warn] updateFilter: \(filterError)") }
                    s.updateConfiguration(config) { err in
                        if let err { print("[warn] updateConfig: \(err)") }
                    }
                }
                return
            }
            // Recreating the stream is intentional. ScreenCaptureKit can keep
            // the old source IOSurface allocation when a filter for the same
            // window ID is updated in place, producing a correctly sized but
            // visibly upscaled buffer after zoom. A fresh stream allocates its
            // source from the refreshed window geometry.
            s.stopCapture { [weak self] stopError in
                guard let self,
                      generation == self.reconfigurationGeneration else { return }
                if let stopError { print("[warn] stop for resize: \(stopError)") }
                self.stream = nil
                self.stateLock.withLock { self._capturing = false }
                Task { [weak self] in
                    guard let self,
                          generation == self.reconfigurationGeneration else { return }
                    do {
                        try await self.startCapture(window: refreshed, scale: scale)
                    } catch {
                        print("[warn] restart after resize: \(error)")
                        self.onError?()
                    }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard
            sampleBuffer.isValid,
            outputType == .screen,
            let attachmentArrays = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentArrays.first,
            let statusRawValue = attachments[.status] as? Int,
            SCFrameStatus(rawValue: statusRawValue) == .complete
        else {
            return
        }

        // Bypass timestamp scheduling in AVSampleBufferDisplayLayer. A late
        // frame should be shown now rather than queued behind stale content.
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )

        if let pixelBuffer = sampleBuffer.imageBuffer {
            let signature = frameSignature(pixelBuffer)
            let pixelSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let pointSize = stateLock.withLock { _configuredPointSize }
            // FrameInfo.scaleFactor describes source transformation and can
            // differ from the output buffer's pixels-per-destination-point.
            // The latter is what determines whether text is actually sharp.
            let deliveredScale = min(
                pointSize.width > 0 ? pixelSize.width / pointSize.width : 1,
                pointSize.height > 0 ? pixelSize.height / pointSize.height : 1
            )
            let contentRect = (attachments[.contentRect] as? NSValue)?.rectValue
                ?? attachments[.contentRect] as? CGRect
                ?? CGRect(origin: .zero, size: pixelSize)
            let shouldLogGeometry = stateLock.withLock { () -> Bool in
                guard !_didLogContentGeometry else { return false }
                _didLogContentGeometry = true
                return true
            }
            if shouldLogGeometry {
                print("[diag] capture geometry pixels=\(pixelSize) content=\(contentRect) raw=\(String(describing: attachments[.contentRect]))")
                fflush(stdout)
            }
            let titlebarBackdrop = makeTitlebarBackdrop(
                pixelBuffer,
                contentRect: contentRect,
                scaleFactor: max(1, deliveredScale)
            )
            var backdropChanged = false
            stateLock.withLock {
                _completedFrameCount &+= 1
                _lastFrameSignature = signature
                _deliveredPixelSize = pixelSize
                _deliveredScaleFactor = deliveredScale
                if let titlebarBackdrop {
                    backdropChanged = _titlebarBackdropSignature != titlebarBackdrop.signature
                    _titlebarBackdropSignature = titlebarBackdrop.signature
                    _repairImageSize = CGSize(
                        width: titlebarBackdrop.image.width,
                        height: titlebarBackdrop.image.height
                    )
                    _repairRows = titlebarBackdrop.rows
                }
            }
            if backdropChanged, let titlebarBackdrop {
                DispatchQueue.main.async { [weak self] in
                    self?.onTitlebarBackdrop?(
                        titlebarBackdrop.image,
                        titlebarBackdrop.signature
                    )
                }
            }
        }

        // Feed the layer itself on the serial capture queue. The renderer-only
        // path could accept buffers while the attached layer displayed none.
        if videoLayer.status == .failed {
            videoLayer.flush()
        }
        videoLayer.enqueue(sampleBuffer)
    }

    private func frameSignature(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 1469598103934665603
        for row in 0..<16 {
            let y = min(height - 1, row * height / 16)
            for column in 0..<16 {
                let x = min(width - 1, column * width / 16)
                let offset = y * rowBytes + x * 4
                for channel in 0..<4 {
                    hash ^= UInt64(bytes[offset + channel])
                    hash &*= 1099511628211
                }
            }
        }
        return hash
    }

    private func makeTitlebarBackdrop(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        scaleFactor: CGFloat
    ) -> (signature: UInt64, image: CGImage, rows: [UInt8])? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let contentMinX = max(0, Int(contentRect.minX.rounded()))
        let contentMinY = max(0, Int(contentRect.minY.rounded()))
        let contentMaxX = min(width, Int(contentRect.maxX.rounded()))
        let contentMaxY = min(height, Int(contentRect.maxY.rounded()))
        let safeStartX = min(
            contentMaxX,
            contentMinX + max(1, Int((140 * scaleFactor).rounded()))
        )
        let safeEndX = min(
            contentMaxX,
            max(safeStartX + 1, contentMaxX - Int((24 * scaleFactor).rounded()))
        )
        guard contentMaxX > safeStartX, safeEndX > safeStartX,
              contentMaxY > contentMinY + 4 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let outputHeight = min(
            max(1, Int((titlebarRepairHeight * scaleFactor).rounded())),
            contentMaxY - contentMinY
        )
        var rgba = [UInt8](repeating: 0, count: outputHeight * 4)
        var signature: UInt64 = 1469598103934665603
        // Fixed histograms produce the same independent channel quantiles as
        // sorting every sampled pixel, without allocating thousands of small
        // arrays or performing O(n log n) work for every 60 Hz frame.
        func quantile(_ histogram: [Int], count: Int, index: Int) -> UInt8 {
            guard count > 0 else { return 240 }
            let target = min(count - 1, max(0, index))
            var cumulative = 0
            for value in 0..<histogram.count {
                cumulative += histogram[value]
                if cumulative > target { return UInt8(value) }
            }
            return 240
        }
        var materialReds = [Int](repeating: 0, count: 256)
        var materialGreens = [Int](repeating: 0, count: 256)
        var materialBlues = [Int](repeating: 0, count: 256)
        var materialCount = 0
        let materialStartY = min(outputHeight - 1, max(0, Int((12 * scaleFactor).rounded())))
        let materialEndY = min(outputHeight, max(materialStartY + 1, Int((24 * scaleFactor).rounded())))
        for localY in materialStartY..<materialEndY {
            let sourceY = contentMaxY - 1 - localY
            for x in stride(
                from: safeStartX,
                to: safeEndX,
                by: max(2, Int((2 * scaleFactor).rounded()))
            ) {
                let pixelOffset = sourceY * rowBytes + x * 4
                guard bytes[pixelOffset + 3] > 220 else { continue }
                let blue = Int(bytes[pixelOffset])
                let green = Int(bytes[pixelOffset + 1])
                let red = Int(bytes[pixelOffset + 2])
                guard max(red, green, blue) - min(red, green, blue) <= 28 else { continue }
                materialReds[red] += 1
                materialGreens[green] += 1
                materialBlues[blue] += 1
                materialCount += 1
            }
        }
        let materialIndex = materialCount * 3 / 4
        let materialRed = quantile(materialReds, count: materialCount, index: materialIndex)
        let materialGreen = quantile(materialGreens, count: materialCount, index: materialIndex)
        let materialBlue = quantile(materialBlues, count: materialCount, index: materialIndex)
        // Build a one-pixel-wide vertical texture from the broad, undisturbed
        // titlebar area. ScreenCaptureKit can composite a duplicated document
        // row into the privacy-pill/title region. Covering only the traffic
        // lights leaves that duplicate visible; the view stretches this clean
        // material across the complete 32-point titlebar. The upper quartile
        // matches the unobstructed material while rejecting title glyphs.
        for y in 0..<outputHeight {
            let sourceY = contentMaxY - 1 - y
            var reds = [Int](repeating: 0, count: 256)
            var greens = [Int](repeating: 0, count: 256)
            var blues = [Int](repeating: 0, count: 256)
            var sampleCount = 0
            for x in stride(
                from: safeStartX,
                to: safeEndX,
                by: max(2, Int((2 * scaleFactor).rounded()))
            ) {
                let offset = sourceY * rowBytes + x * 4
                guard bytes[offset + 3] > 220 else { continue }
                let blue = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let red = Int(bytes[offset + 2])
                guard max(red, green, blue) - min(red, green, blue) <= 28 else { continue }
                reds[red] += 1
                greens[green] += 1
                blues[blue] += 1
                sampleCount += 1
            }
            let offset = y * 4
            let usesUniformMaterial = y < max(0, outputHeight - Int((4 * scaleFactor).rounded()))
            if usesUniformMaterial {
                rgba[offset] = materialRed
                rgba[offset + 1] = materialGreen
                rgba[offset + 2] = materialBlue
            } else if sampleCount == 0 {
                rgba[offset] = y > 0 ? rgba[offset - 4] : 240
                rgba[offset + 1] = y > 0 ? rgba[offset - 3] : 240
                rgba[offset + 2] = y > 0 ? rgba[offset - 2] : 240
            } else {
                let medianIndex = sampleCount / 2
                rgba[offset] = quantile(reds, count: sampleCount, index: medianIndex)
                rgba[offset + 1] = quantile(greens, count: sampleCount, index: medianIndex)
                rgba[offset + 2] = quantile(blues, count: sampleCount, index: medianIndex)
            }
            rgba[offset + 3] = 255
            for channel in 0..<4 {
                signature ^= UInt64(rgba[offset + channel])
                signature &*= 1099511628211
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: 1,
                height: outputHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        // This image is synthesized exclusively from the median colour of
        // each title-bar row. It is one pixel wide, so document glyphs and the
        // capture pill cannot be copied into the repair regardless of image
        // orientation or crop-coordinate conventions.
        return (signature, image, rgba)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[warn] capture stopped: \(error)")
        DispatchQueue.main.async {
            self.stream = nil
            self.stateLock.withLock { self._capturing = false }
            self.onError?()
        }
    }
}

// MARK: - Coordinate Transform

func cgToNS(_ cgRect: CGRect) -> NSRect {
    guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    else {
        return cgRect
    }
    return NSRect(x: cgRect.origin.x,
                  y: primary.frame.maxY - cgRect.origin.y - cgRect.height,
                  width: cgRect.width, height: cgRect.height)
}

// MARK: - Private API: _AXUIElementGetWindow

private let _AXUIElementGetWindow: @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError = {
    let handle = dlopen(nil, RTLD_NOW)!
    return unsafeBitCast(dlsym(handle, "_AXUIElementGetWindow"),
                         to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError).self)
}()


// MARK: - Mirror Panel

private final class TrafficLightDotView: NSView {
    let glyphLayer = CAShapeLayer()
    let action: Int

    init(frame: NSRect, color: NSColor, action: Int) {
        self.action = action
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        glyphLayer.strokeColor = NSColor.black.withAlphaComponent(0.62).cgColor
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = 1
        glyphLayer.lineCap = .round
        glyphLayer.lineJoin = .round
        glyphLayer.isHidden = true
        layer?.addSublayer(glyphLayer)
        updateGlyphPath()
    }

    required init?(coder: NSCoder) { nil }

    // The parent strip owns all actions. Returning no hit target keeps these
    // coloured/glyph views purely visual so AppKit cannot deliver a restored
    // panel's click to an inert child.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateGlyphPath()
    }

    func setGlyphVisible(_ visible: Bool) {
        glyphLayer.isHidden = !visible
    }

    private func updateGlyphPath() {
        glyphLayer.frame = bounds
        let path = CGMutablePath()
        switch action {
        case 0:
            path.move(to: CGPoint(x: 4.5, y: 4.5)); path.addLine(to: CGPoint(x: 9.5, y: 9.5))
            path.move(to: CGPoint(x: 9.5, y: 4.5)); path.addLine(to: CGPoint(x: 4.5, y: 9.5))
        case 1:
            path.move(to: CGPoint(x: 4, y: 7)); path.addLine(to: CGPoint(x: 10, y: 7))
        default:
            path.move(to: CGPoint(x: 4.5, y: 4.5)); path.addLine(to: CGPoint(x: 9.5, y: 9.5))
            path.move(to: CGPoint(x: 4.5, y: 7)); path.addLine(to: CGPoint(x: 4.5, y: 4.5)); path.addLine(to: CGPoint(x: 7, y: 4.5))
            path.move(to: CGPoint(x: 9.5, y: 7)); path.addLine(to: CGPoint(x: 9.5, y: 9.5)); path.addLine(to: CGPoint(x: 7, y: 9.5))
        }
        glyphLayer.path = path
    }
}

private final class WindowControlStripView: NSView {
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    private(set) var dotViews: [TrafficLightDotView] = []
    weak var owner: MirrorPanel?
    var hasActionOwner: Bool { owner != nil }
    var hoveredGlyphCount: Int { dotViews.filter { !$0.glyphLayer.isHidden }.count }

    func verifyHoverStateForRegression() -> Bool {
        setGlyphsVisible(true)
        return hoveredGlyphCount == 3
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDots()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDots()
    }

    private func configureDots() {
        // Separate circle layers stay above the sampled opaque title-bar
        // backing and cannot be flattened or hidden by capture compositing.
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (index, color) in colors.enumerated() {
            let dot = TrafficLightDotView(
                frame: NSRect(x: 9 + index * 20, y: 7, width: 14, height: 14),
                color: color,
                action: index
            )
            dot.layer?.zPosition = 1
            addSubview(dot)
            dotViews.append(dot)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setGlyphsVisible(true) }
    override func mouseMoved(with event: NSEvent) { setGlyphsVisible(true) }
    override func mouseExited(with event: NSEvent) { setGlyphsVisible(false) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 0, point.y <= bounds.height else { return }
        let action: Int
        switch point.x {
        case 6..<26: action = 0
        case 26..<46: action = 1
        case 46..<66: action = 2
        default: return
        }
        _ = invokeForRegression(action)
    }

    func invokeForRegression(_ action: Int) -> Bool {
        guard (0...2).contains(action), let owner else { return false }
        owner.recordOverlayControlClick(action: action)
        owner.performWindowControl(action)
        return true
    }

    private func setGlyphsVisible(_ visible: Bool) {
        dotViews.forEach { $0.setGlyphVisible(visible) }
    }
}

private final class WindowControlBackdropView: NSView {
    private(set) var textureSignature: UInt64 = 0
    private let titleLabel = NSTextField(labelWithString: "")
    private let separatorLayer = CALayer()
    override var isOpaque: Bool { false }
    var isRepairConfigured: Bool {
        textureSignature != 0
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        separatorLayer.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(separatorLayer)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: 92, y: 7, width: max(0, bounds.width - 184), height: 18)
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)
    }

    override func layout() {
        super.layout()
        let scale = max(1, window?.backingScaleFactor ?? 1)
        separatorLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / scale)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separatorLayer.backgroundColor = NSColor.separatorColor.cgColor
    }

    var hasTitlebarSeparator: Bool {
        separatorLayer.superlayer === layer && separatorLayer.frame.height > 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBackdrop(_ image: CGImage, signature: UInt64) {
        textureSignature = signature
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    func setTitle(_ title: String?, edited: Bool = false) {
        guard let title, !title.isEmpty else {
            titleLabel.stringValue = ""
            return
        }
        titleLabel.stringValue = edited ? "\(title) — Edited" : title
    }

    var renderedTitle: String { titleLabel.stringValue }
    var titleIsLeftAligned: Bool { titleLabel.alignment == .left }
}

private class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class UnconstrainedControlPanel: PassivePanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The target follows a mirror which may legitimately straddle a screen
        // edge during live geometry changes. AppKit's normal panel constraint
        // can otherwise relocate this tiny window to a screen corner.
        frameRect
    }
}

final class MirrorPanel: @unchecked Sendable {
    var scWindow: SCWindow
    let capture = CaptureManager()
    var panel: NSPanel!
    private var controlPanel: NSPanel!
    private var controlBackdropView: WindowControlBackdropView!
    private var visualControlView: NSView!
    private var axObserver: AXObserver?
    private var observedAXWindow: AXUIElement?
    private var aliveTimer: Timer?
    private var manipulationSettleTimer: Timer?
    private var geometryTimer: Timer?
    private var controlAlignmentTimer: Timer?
    private var clickMonitor: Any?
    private var inputEventTap: CFMachPort?
    private var inputEventTapSource: CFRunLoopSource?
    private var isManipulating = false
    private var pendingFrame: NSRect?
    private var rebuildAfterManipulation = false
    private var manipulationStartFrameCount: UInt64 = 0
    private var isAwaitingFreshMirror = false
    private var didVerifySynchronousManipulationHide = false
    private var didVerifyFreshResizeReveal = false
    private var mouseDownInside = false
    private var recoveryTask: Task<Void, Never>?
    private var isSuspended = false
    private var isTemporarilyUnavailable = false
    private var isStopped = false
    private var didVerifyWindowControls = false
    private var controlRevealGeneration = 0
    private var isAwaitingControlReveal = false
    private let replayEventMarker: Int64 = 0x57544F4F4C53
    private var routingGeneration = 0
    private var routingPending = false
    private var routingReplacementDownPosted = false
    private var routingEarlyMouseUp = false
    private var routingPendingDrag: (point: CGPoint, flags: CGEventFlags)?
    private var routingEarlyMouseUpEvent: (point: CGPoint, flags: CGEventFlags)?
    private var didVerifyInputRouting = false
    private var didVerifyOverlayControlClick = false
    private var didRequestNativeMinimizeAnimation = false
    private var usesNativeTitlebar = true
    private var hasNativeWindowControls = true
    private var isDirectPresentation = false
    private var presentationGeneration = 0
    private var didVerifyLiveTitle = false
    private var didVerifyEditedTitle = false
    private var didVerifyTopLeftResizeRouting = false
    private var didVerifyResizeBordersClear = false
    private var preservesControlsDuringRecovery = false
    private var recoveryControlFrameThreshold: UInt64?

    init(scWindow: SCWindow) {
        self.scWindow = scWindow

        let nsFrame = cgToNS(scWindow.frame)
        panel = PassivePanel(contentRect: nsFrame,
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        // The source window may sit behind another normal window, hiding its
        // shadow even though this floating mirror remains visible. Give the
        // rounded, alpha-masked mirror its own AppKit shadow.
        panel.hasShadow = true
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let view = NSView(frame: NSRect(origin: .zero, size: nsFrame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true

        let videoLayer = capture.videoLayer
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.videoGravity = .resize
        let initialScale = captureScale(for: nsFrame)
        view.layer?.contentsScale = initialScale
        videoLayer.contentsScale = initialScale
        view.layer?.addSublayer(videoLayer)

        panel.contentView = view
        configureWindowControls(for: nsFrame)

        capture.onError = { [weak self] in
            self?.recoverCapture(reason: "stream stopped")
        }
        capture.onTitlebarBackdrop = { [weak self] image, signature in
            guard self?.hasNativeWindowControls == true else { return }
            self?.controlBackdropView?.setBackdrop(image, signature: signature)
        }
    }

    @MainActor
    func start() async {
        // Resolve the source Accessibility window before placing the mirror
        // above it; otherwise a system-wide AX hit test can find our overlay.
        startAXObserver()
        // Never let an overlay steal keyboard focus from the pinned app.
        panel.orderFrontRegardless()
        verifyPassiveOverlayInvariant()
        scheduleControlReveal()
        do {
            try await capture.startCapture(
                window: scWindow,
                scale: captureScale(for: panel.frame)
            )
        } catch {
            print("[error] capture failed: \(error)")
            PinManager.shared.unpinByWindowID(scWindow.windowID)
            return
        }
        startClickMonitor()
        startInputRoutingTap()
        startControlAlignment()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAliveAndCapture()
        }
        RunLoop.main.add(timer, forMode: .common)
        aliveTimer = timer
        let sourcePID = scWindow.owningApplication?.processID
        setSourceApplicationActive(
            NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID
        )
    }

    func hideOverlays() {
        controlPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    func stop(flushOverlay: Bool = true) {
        isStopped = true
        // Remove both compositor surfaces before any monitor, observer, or
        // ScreenCaptureKit teardown. Closing a capture first can leave its last
        // IOSurface visible until AppKit reaches a later transaction, which is
        // noticeable when focus immediately moves to another application.
        hideOverlays()
        if flushOverlay { CATransaction.flush() }
        let overlaysHiddenSynchronously = !controlPanel.isVisible && !panel.isVisible
        recoveryTask?.cancel()
        recoveryTask = nil
        manipulationSettleTimer?.invalidate()
        manipulationSettleTimer = nil
        stopGeometryTracking()
        controlAlignmentTimer?.invalidate()
        controlAlignmentTimer = nil
        aliveTimer?.invalidate()
        aliveTimer = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let inputEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), inputEventTapSource, .commonModes)
        }
        inputEventTapSource = nil
        inputEventTap = nil
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs),
                                  .commonModes)
        }
        axObserver = nil
        observedAXWindow = nil
        capture.stopCapture()
        controlPanel.close()
        panel.close()
        if overlaysHiddenSynchronously {
            print("[diag] unpin overlay hidden synchronously")
        } else {
            print("[error] unpin overlay remained visible during teardown")
        }
        fflush(stdout)
    }

    private func startAXObserver() {
        guard let pid = scWindow.owningApplication?.processID else { return }

        let axApp = AXUIElementCreateApplication(pid_t(pid))
        guard let axWin = findAXWindow(axApp: axApp) else {
            print("[warn] cannot find AX window for observer; trusted=\(AXIsProcessTrusted()) pid=\(pid)")
            fflush(stdout)
            return
        }
        configureTitlebarSupport(from: axWin)

        typealias Callback = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
        let cb: Callback = { _, element, notification, ptr in
            guard let ptr else { return }
            let mirror = Unmanaged<MirrorPanel>.fromOpaque(ptr).takeUnretainedValue()
            let update = {
                let isMove = CFEqual(notification, kAXWindowMovedNotification as CFString)
                let isResize = CFEqual(notification, kAXWindowResizedNotification as CFString)
                let isMinimized = CFEqual(notification, kAXWindowMiniaturizedNotification as CFString)
                let isRestored = CFEqual(notification, kAXWindowDeminiaturizedNotification as CFString)
                let isTitleChange = CFEqual(notification, kAXTitleChangedNotification as CFString)
                    || CFEqual(notification, kAXValueChangedNotification as CFString)

                if isTitleChange {
                    mirror.updateLiveWindowTitle(from: element)
                    return
                }

                if isMinimized {
                    mirror.isTemporarilyUnavailable = true
                    mirror.controlRevealGeneration += 1
                    mirror.isAwaitingControlReveal = false
                    mirror.hideOverlays()
                    mirror.recoveryTask?.cancel()
                    mirror.recoveryTask = nil
                    mirror.capture.stopCapture()
                    return
                }

                if isRestored {
                    mirror.isTemporarilyUnavailable = false
                    mirror.syncFrameFromAccessibility()
                    if mirror.isDirectPresentation {
                        mirror.hideOverlays()
                    } else {
                        // A minimized SCStream can remain nominally alive while
                        // no longer producing usable frames. Always rebuild it
                        // and reveal controls from the restored AX window.
                        mirror.recoverCapture(reason: "window restored")
                    }
                    return
                }

                if isResize {
                    mirror.pendingFrame = mirror.frame(from: element)
                    mirror.rebuildAfterManipulation = true
                    mirror.beginManipulation()
                    mirror.scheduleManipulationCompletion()
                    return
                }

                if NSEvent.pressedMouseButtons & 1 != 0, isMove {
                    mirror.pendingFrame = mirror.frame(from: element)
                    mirror.beginManipulation()
                    mirror.scheduleManipulationCompletion()
                    return
                }

                if isMove {
                    if !mirror.syncPosition(from: element) {
                        mirror.syncFrame()
                    }
                } else {
                    mirror.syncFrame()
                }
            }

            // This observer is installed on the main run loop, so callbacks
            // normally update the panel immediately. Keep a defensive fallback
            // for any application that delivers the callback elsewhere.
            if Thread.isMainThread {
                update()
            } else {
                DispatchQueue.main.async(execute: update)
            }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid_t(pid), cb, &obs) == .success, let observer = obs else { return }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axWin, kAXWindowMovedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXWindowResizedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXWindowMiniaturizedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXWindowDeminiaturizedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXTitleChangedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXValueChangedNotification as CFString, ptr)
        // Window dragging runs the main loop in event-tracking mode. Common
        // modes keep AX move/resize notifications flowing throughout a drag.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        observedAXWindow = axWin
        updateLiveWindowTitle(from: axWin)
    }

    private func updateLiveWindowTitle(from axWindow: AXUIElement) {
        guard usesNativeTitlebar else { return }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axWindow, kAXTitleAttribute as CFString, &titleRef
        ) == .success, let title = titleRef as? String, !title.isEmpty else { return }
        func editedValue(from element: AXUIElement) -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                element, kAXEditedAttribute as CFString, &value
            ) == .success && value.map { CFEqual($0, kCFBooleanTrue) } == true
        }
        var edited = editedValue(from: axWindow)
        for attribute in [kAXTitleUIElementAttribute, kAXCloseButtonAttribute] where !edited {
            var elementRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                axWindow, attribute as CFString, &elementRef
            ) == .success, let elementRef,
               CFGetTypeID(elementRef) == AXUIElementGetTypeID() {
                edited = editedValue(
                    from: unsafeBitCast(elementRef, to: AXUIElement.self)
                )
            }
        }
        controlBackdropView.setTitle(title, edited: edited)
        if !didVerifyLiveTitle {
            didVerifyLiveTitle = true
            print("[diag] live accessibility window title applied")
            fflush(stdout)
        }
        if !didVerifyEditedTitle, edited,
           controlBackdropView.renderedTitle == "\(title) — Edited"
            && controlBackdropView.titleIsLeftAligned {
            didVerifyEditedTitle = true
            print("[diag] live accessibility edited title and native alignment applied")
            fflush(stdout)
        }
    }

    func setSourceApplicationActive(_ active: Bool) {
        guard !isStopped else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        if active {
            guard !isDirectPresentation else { return }
            enterDirectPresentationWhenReady(generation: generation, attempt: 0)
            return
        }
        guard isDirectPresentation else { return }
        isDirectPresentation = false
        updateWindowShape(for: panel.frame)
        capture.videoLayer.isHidden = false
        syncFrameFromAccessibility()
        if capture.frameState.count > 0 {
            // The display layer retains its last good IOSurface after capture
            // stops. Present it synchronously so activation of another app
            // cannot expose a blank gap while the fresh stream starts. If the
            // source resized while active this placeholder may scale briefly,
            // but it is replaced only by the verified fresh-size frame.
            panel.orderFrontRegardless()
            positionWindowControls(for: panel.frame)
            controlPanel.orderFrontRegardless()
            preservesControlsDuringRecovery = true
            recoveryControlFrameThreshold = capture.frameState.count
            print("[diag] deactivation presented retained mirror without a blank frame")
        }
        print("[diag] direct native presentation disabled")
        recoverCapture(reason: "source application deactivated")
        fflush(stdout)
    }

    private func enterDirectPresentationWhenReady(generation: Int, attempt: Int) {
        guard !isStopped, generation == presentationGeneration,
              !isDirectPresentation else { return }
        let frame = currentWindowServerFrame() ?? scWindow.frame
        let nativeReady = sourceWindowIsTopmost(at: CGPoint(x: frame.midX, y: frame.midY))
        if routingPending || !nativeReady {
            guard attempt < 30 else {
                print("[warn] native presentation readiness timed out; retaining mirror")
                fflush(stdout)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                self?.enterDirectPresentationWhenReady(
                    generation: generation, attempt: attempt + 1
                )
            }
            return
        }
        isDirectPresentation = true
        updateWindowShape(for: panel.frame)
        recoveryTask?.cancel()
        recoveryTask = nil
        controlPanel.orderOut(nil)
        panel.orderOut(nil)
        capture.stopCapture()
        print("[diag] direct native presentation enabled")
        print("[diag] activation retained mirror until native window was ready")
        if !capture.capturing && !panel.isVisible && !controlPanel.isVisible {
            print("[diag] active native presentation capture and overlays stopped")
        } else {
            print("[error] active native presentation retained capture or an overlay")
        }
        fflush(stdout)
    }

    private func configureTitlebarSupport(from axWindow: AXUIElement) {
        var titleElement: CFTypeRef?
        usesNativeTitlebar = AXUIElementCopyAttributeValue(
            axWindow,
            kAXTitleUIElementAttribute as CFString,
            &titleElement
        ) == .success && titleElement != nil

        hasNativeWindowControls = [
            kAXCloseButtonAttribute,
            kAXMinimizeButtonAttribute,
            kAXZoomButtonAttribute
        ].contains { attribute in
            var button: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                axWindow, attribute as CFString, &button
            ) == .success && button != nil
        }

        if !hasNativeWindowControls {
            controlBackdropView.isHidden = true
            controlPanel.orderOut(nil)
            isAwaitingControlReveal = false
            print("[diag] titleless window retained native captured chrome")
            fflush(stdout)
        } else if !usesNativeTitlebar {
            // Custom-chrome apps can expose native window actions without an
            // Accessibility title element. Keep the replacement traffic
            // lights, but bound the pill repair to their small hit strip so
            // FloatKit cannot paint a conventional title bar across the app.
            controlBackdropView.isHidden = false
            controlBackdropView.autoresizingMask = [.minYMargin]
            controlBackdropView.setTitle(nil)
            controlBackdropView.frame.size.width = controlStripWidth
            print("[diag] custom chrome retained interactive window controls")
            fflush(stdout)
        }
    }

    private func frame(from axWindow: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                axWindow,
                kAXPositionAttribute as CFString,
                &positionRef
            ) == .success,
            AXUIElementCopyAttributeValue(
                axWindow,
                kAXSizeAttribute as CFString,
                &sizeRef
            ) == .success,
            let positionRef,
            let sizeRef,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionValue = unsafeBitCast(positionRef, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetType(sizeValue) == .cgSize,
            AXValueGetValue(positionValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue, .cgSize, &size),
            size.width > 1,
            size.height > 1
        else {
            return nil
        }

        return cgToNS(CGRect(origin: origin, size: size))
    }

    private func syncPosition(from axWindow: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                axWindow,
                kAXPositionAttribute as CFString,
                &valueRef
            ) == .success,
            let valueRef,
            CFGetTypeID(valueRef) == AXValueGetTypeID()
        else {
            return false
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return false }

        var cgOrigin = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &cgOrigin) else { return false }

        let nsOrigin = cgToNS(CGRect(origin: cgOrigin, size: panel.frame.size)).origin
        guard panel.frame.origin != nsOrigin else { return true }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrameOrigin(nsOrigin)
        CATransaction.commit()
        positionWindowControls(for: panel.frame)
        return true
    }

    private func findAXWindow(axApp: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var candidate: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                axApp, attribute as CFString, &candidate
            ) == .success,
               let candidate,
               CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(candidate, to: AXUIElement.self)
                if frame(from: window) != nil { return window }
            }
        }

        // Some applications transiently report their AXApplication object for
        // focused/main-window attributes. Hit-test the centre of the known
        // ScreenCaptureKit window, then ask that element for its containing
        // window. This avoids the unreliable bridged AXWindows collection.
        let target = scWindow.frame
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(target.midX), Float(target.midY), &hit
        ) == .success, let hit {
            for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
                var candidate: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    hit, attribute as CFString, &candidate
                ) == .success,
                   let candidate,
                   CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                    let window = unsafeBitCast(candidate, to: AXUIElement.self)
                    if frame(from: window) != nil { return window }
                }
            }
        }

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success else {
            return nil
        }
        guard let windows = ref as? [AXUIElement], !windows.isEmpty else { return nil }

        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == scWindow.windowID {
                return win
            }
        }

        // On recent macOS releases Accessibility and ScreenCaptureKit can
        // publish different IDs for the same backing window. Both candidates
        // already belong to the same process, so match the nearest geometry.
        let targetFrame = cgToNS(scWindow.frame)
        return windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let candidate = frame(from: window) else { return nil }
            let distance = abs(candidate.minX - targetFrame.minX)
                + abs(candidate.minY - targetFrame.minY)
                + abs(candidate.width - targetFrame.width)
                + abs(candidate.height - targetFrame.height)
            return (window, distance)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    func syncFrame() {
        guard let frame = currentCGFrame() else { return }
        applyFrame(frame)
    }

    private func currentWindowServerFrame() -> CGRect? {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                scWindow.windowID
            ) as? [[String: Any]],
            let first = info.first,
            let bounds = first[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            frame.width > 1,
            frame.height > 1
        else { return nil }
        return frame
    }

    private func currentCGFrame() -> NSRect? {
        currentWindowServerFrame().map(cgToNS)
    }

    private func isSourceWindowOnScreen() -> Bool {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                scWindow.windowID
            ) as? [[String: Any]],
            let first = info.first
        else { return false }
        return (first[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
    }

    private func syncFrameFromAccessibility() {
        if let observedAXWindow, let frame = frame(from: observedAXWindow) {
            applyFrame(frame)
        } else {
            syncFrame()
        }
    }

    private func reconcileGeometryBackstop() {
        guard let observedAXWindow, let actualFrame = frame(from: observedAXWindow) else {
            return
        }

        let sizeChanged = abs(actualFrame.width - panel.frame.width) > 2
            || abs(actualFrame.height - panel.frame.height) > 2
        if sizeChanged {
            pendingFrame = actualFrame
            rebuildAfterManipulation = true
            beginManipulation()
            scheduleManipulationCompletion()
        } else if panel.frame.origin != actualFrame.origin {
            panel.setFrameOrigin(actualFrame.origin)
            positionWindowControls(for: panel.frame)
        }
    }

    private func destinationScale(for frame: NSRect) -> CGFloat {
        let screen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(frame)
            let right = rhs.frame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }
        return max(1, screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    private func captureScale(for frame: NSRect) -> CGFloat {
        if let forced = ProcessInfo.processInfo.environment["FLOATKIT_TEST_FORCE_CAPTURE_SCALE"],
           let value = Double(forced), value > 0 {
            return CGFloat(value)
        }
        return destinationScale(for: frame)
    }

    private func applyFrame(_ nsFrame: NSRect) {
        let sizeChanged = panel.frame.size != nsFrame.size
        let scale = captureScale(for: nsFrame)
        updateWindowShape(for: nsFrame)
        panel.contentView?.layer?.contentsScale = scale
        capture.videoLayer.contentsScale = scale
        if sizeChanged {
            capture.updateCaptureSize(
                width: max(1, nsFrame.width),
                height: max(1, nsFrame.height),
                scale: scale
            )
        }
        if panel.frame != nsFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if sizeChanged {
                panel.setFrame(nsFrame, display: true)
            } else {
                // Moving only the window origin avoids relayout and redraw
                // work for every Accessibility notification during a drag.
                panel.setFrameOrigin(nsFrame.origin)
            }
            CATransaction.commit()
        }
        positionWindowControls(for: panel.frame)
    }

    private func isMaximizedFrame(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
        }) else { return false }
        func matches(_ target: NSRect) -> Bool {
            abs(frame.minX - target.minX) <= 3
                && abs(frame.maxX - target.maxX) <= 3
                && abs(frame.minY - target.minY) <= 3
                && abs(frame.maxY - target.maxY) <= 3
        }
        return matches(screen.visibleFrame) || matches(screen.frame)
    }

    private func updateWindowShape(for frame: NSRect) {
        let maximized = isMaximizedFrame(frame)
        panel.contentView?.layer?.cornerRadius = maximized ? 0 : 10
        panel.hasShadow = !maximized && !isDirectPresentation
    }

    private func checkAliveAndCapture() {
        if isManipulating, NSEvent.pressedMouseButtons & 1 == 0 {
            endManipulation()
        }

        let exists = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]]
        if exists?.isEmpty ?? true {
            // Minimized windows and windows transitioning between Spaces can
            // temporarily disappear from the Core Graphics list even though
            // their Accessibility window (and therefore the pin) still
            // exists. Keep the pin dormant until the real window returns.
            if observedWindowStillExists() {
                isTemporarilyUnavailable = true
                controlPanel.orderOut(nil)
                panel.orderOut(nil)
                return
            }
            PinManager.shared.unpinByWindowID(scWindow.windowID)
        } else if isTemporarilyUnavailable {
            isTemporarilyUnavailable = false
            syncFrameFromAccessibility()
            if capture.capturing {
                panel.orderFrontRegardless()
                scheduleControlReveal()
            } else {
                recoverCapture(reason: "window returned")
            }
        } else if !isDirectPresentation && !isSuspended && !capture.capturing {
            recoverCapture(reason: "capture stalled")
        } else if !isSuspended && !isManipulating {
            // A once-per-second backstop repairs geometry even when an
            // application fails to emit Accessibility move/resize events.
            reconcileGeometryBackstop()
            if let observedAXWindow { updateLiveWindowTitle(from: observedAXWindow) }
            verifyWindowControlInvariant()
        }
    }

    private func verifyWindowControlInvariant() {
        guard hasNativeWindowControls else {
            if controlPanel.isVisible || !controlBackdropView.isHidden {
                print("[error] titleless window received synthetic titlebar chrome")
                fflush(stdout)
            }
            return
        }
        if panel.isVisible && !controlPanel.isVisible && isAwaitingControlReveal {
            return
        }
        // The opaque backing deliberately starts with a safe system fallback.
        // Do not assess its colour until ScreenCaptureKit has delivered the
        // first unobstructed title-bar sample used for the exact match.
        guard capture.titlebarBackdropSignature != 0 else { return }
        // Capture publishes a changed texture before the main queue presents
        // it. That one-turn handoff is expected; assess the visual only once
        // both sides name the same texture. A successful assessment is still
        // required by the regression suite before the run can pass.
        guard controlBackdropView.textureSignature == capture.titlebarBackdropSignature else { return }
        guard panel.isVisible == controlPanel.isVisible else {
            print("[error] window control invariant failed: mirror=\(panel.isVisible) controls=\(controlPanel.isVisible)")
            fflush(stdout)
            return
        }
        guard panel.isVisible else { return }

        let expected = NSRect(
            x: panel.frame.minX + controlResizeInset,
            y: panel.frame.maxY - controlStripHeight,
            width: controlStripWidth - controlResizeInset,
            height: controlStripHeight - controlResizeInset
        )
        let aligned = abs(controlPanel.frame.minX - expected.minX) <= 1
            && abs(controlPanel.frame.minY - expected.minY) <= 1
        let resizeBordersClear = controlPanel.frame.minX >= panel.frame.minX + controlResizeInset
            && controlPanel.frame.maxY <= panel.frame.maxY - controlResizeInset
        let visualEmbedded = visualControlView.superview === controlPanel.contentView
            && abs(visualControlView.frame.minX + controlResizeInset) <= 1
            && abs(visualControlView.frame.minY) <= 1
            && abs(visualControlView.frame.width - controlStripWidth) <= 1
            && abs(visualControlView.frame.height - controlStripHeight) <= 1
            && controlBackdropView.superview === panel.contentView
            && abs(controlBackdropView.frame.width - (usesNativeTitlebar
                ? panel.contentView!.bounds.width : controlStripWidth)) <= 1
            && controlBackdropView.frame.height == titlebarRepairHeight
            && controlVisualRendersCorrectly()
        let visibleControlStrips = NSApp.windows.filter {
            $0.isVisible
                && abs($0.frame.width - (controlStripWidth - controlResizeInset)) <= 1
                && abs($0.frame.height - (controlStripHeight - controlResizeInset)) <= 1
        }.count

        guard visualEmbedded,
              visibleControlStrips <= PinManager.shared.mirrors.count else {
            print("[error] window control invariant failed: visible=\(controlPanel.isVisible) aligned=\(aligned) embedded=\(visualEmbedded) strips=\(visibleControlStrips) pins=\(PinManager.shared.mirrors.count)")
            fflush(stdout)
            return
        }

        if resizeBordersClear && !didVerifyResizeBordersClear {
            didVerifyResizeBordersClear = true
            print("[diag] top-left resize borders remain outside FloatKit hit surfaces")
            fflush(stdout)
        } else if !resizeBordersClear {
            print("[error] FloatKit control surface obstructed top-left resize borders")
            fflush(stdout)
            return
        }

        if !aligned {
            if !isAwaitingControlReveal {
                isAwaitingControlReveal = true
                controlPanel.orderOut(nil)
                scheduleControlReveal()
            }
            return
        }

        if !didVerifyWindowControls {
            didVerifyWindowControls = true
            print("[diag] window controls verified")
            fflush(stdout)
        }
    }

    private func verifyPassiveOverlayInvariant() {
        let roundedContent = panel.contentView?.layer?.masksToBounds == true
            && (panel.contentView?.layer?.cornerRadius ?? 0) >= 9
        let valid = panel.ignoresMouseEvents
            && !panel.canBecomeKey && !panel.canBecomeMain && panel.hasShadow
            && roundedContent
            && panel.collectionBehavior.contains(.transient)
            && !panel.collectionBehavior.contains(.stationary)
            && !controlPanel.canBecomeKey && !controlPanel.canBecomeMain
            && !controlPanel.hasShadow
            && controlPanel.collectionBehavior.contains(.transient)
        if valid {
            print("[diag] passive rounded overlay verified")
        } else {
            print("[error] passive overlay invariant failed: mouse=\(panel.ignoresMouseEvents) key=\(panel.canBecomeKey) main=\(panel.canBecomeMain) shadow=\(panel.hasShadow) rounded=\(roundedContent) transient=\(panel.collectionBehavior.contains(.transient)) controlKey=\(controlPanel.canBecomeKey) controlMain=\(controlPanel.canBecomeMain) controlShadow=\(controlPanel.hasShadow) controlTransient=\(controlPanel.collectionBehavior.contains(.transient))")
        }
        fflush(stdout)
    }

    private func controlVisualRendersCorrectly() -> Bool {
        guard let strip = visualControlView as? WindowControlStripView,
              strip.dotViews.count == 3 else { return false }
        guard strip.hasActionOwner else { return false }
        guard [11.0, 31.0, 51.0].allSatisfy({ x in
            controlPanel.contentView?.hitTest(NSPoint(x: x, y: 14)) === strip
        }) else { return false }

        guard controlBackdropView.isRepairConfigured,
              controlBackdropView.textureSignature != 0,
              controlBackdropView.textureSignature == capture.titlebarBackdropSignature,
              capture.repairImageSize.width == 1,
              capture.repairImageSize.height >= titlebarRepairHeight,
              controlBackdropView.layer?.mask == nil,
              controlBackdropView.hasTitlebarSeparator,
              abs(controlBackdropView.bounds.width - (usesNativeTitlebar
                ? panel.contentView!.bounds.width : controlStripWidth)) <= 1,
              controlBackdropView.bounds.height == titlebarRepairHeight else { return false }

        let dotColors = strip.dotViews.compactMap { dot -> NSColor? in
            guard let cgColor = dot.layer?.backgroundColor,
                  let color = NSColor(cgColor: cgColor) else { return nil }
            return color.usingColorSpace(.deviceRGB)
        }
        guard dotColors.count == 3 else { return false }
        let red = dotColors[0]
        let yellow = dotColors[1]
        let green = dotColors[2]
        let centersAreColored = red.redComponent > red.greenComponent + 0.15
            && yellow.redComponent > yellow.blueComponent + 0.15
            && yellow.greenComponent > yellow.blueComponent + 0.15
            && green.greenComponent > green.redComponent + 0.10
        let backdropMatchesCapture = controlBackdropView.textureSignature == capture.titlebarBackdropSignature
        return centersAreColored && backdropMatchesCapture
    }

    private func captureIsRetinaSharp() -> Bool {
        let expectedScale = ProcessInfo.processInfo.environment["FLOATKIT_TEST_REQUIRED_CAPTURE_SCALE"]
            .flatMap { Double($0) }.map { CGFloat($0) }
            ?? destinationScale(for: panel.frame)
        let requested = capture.configuredPixelSize
        let delivered = capture.deliveredFrameGeometry
        return requested.width + 1 >= panel.frame.width * expectedScale
            && requested.height + 1 >= panel.frame.height * expectedScale
            && delivered.pixels.width + 1 >= panel.frame.width * expectedScale
            && delivered.pixels.height + 1 >= panel.frame.height * expectedScale
            && delivered.scaleFactor + 0.01 >= expectedScale
    }

    func suspendCapture() {
        guard !isStopped else { return }
        isSuspended = true
        recoveryTask?.cancel()
        recoveryTask = nil
        stopGeometryTracking()
        manipulationSettleTimer?.invalidate()
        manipulationSettleTimer = nil
        isManipulating = false
        pendingFrame = nil
        rebuildAfterManipulation = false
        capture.stopCapture()
        controlPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    func resumeCapture() {
        guard !isStopped else { return }
        isSuspended = false
        recoverCapture(reason: "system resumed")
    }

    func ensureHealthy() {
        guard !isStopped, !isSuspended, !isTemporarilyUnavailable else { return }
        syncFrame()
        if isDirectPresentation { return }
        if capture.capturing {
            if !isManipulating {
                panel.orderFrontRegardless()
                scheduleControlReveal()
            }
        } else {
            recoverCapture(reason: "environment changed")
        }
    }

    private func recoverCapture(reason: String) {
        guard
            !isStopped,
            !isSuspended,
            !isTemporarilyUnavailable,
            !isDirectPresentation,
            recoveryTask == nil
        else { return }

        print("[info] recovering window \(scWindow.windowID): \(reason)")
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...3 {
                guard !Task.isCancelled, !self.isStopped, !self.isSuspended,
                      !self.isDirectPresentation else {
                    self.recoveryTask = nil
                    return
                }

                self.capture.stopCapture()
                self.syncFrame()
                if attempt > 1 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                }

                do {
                    let beforeRecoveryFrameCount = self.capture.frameState.count
                    let windowID = self.scWindow.windowID
                    let refreshedWindow: SCWindow? = await withCheckedContinuation { continuation in
                        SCShareableContent.getExcludingDesktopWindows(
                            false, onScreenWindowsOnly: false
                        ) { content, _ in
                            continuation.resume(returning: content?.windows.first {
                                $0.windowID == windowID
                            })
                        }
                    }
                    if let refreshedWindow {
                        self.scWindow = refreshedWindow
                        self.syncFrame()
                    }
                    guard !Task.isCancelled, !self.isDirectPresentation else {
                        self.recoveryTask = nil
                        return
                    }
                    try await self.capture.startCapture(
                        window: self.scWindow,
                        scale: self.captureScale(for: self.panel.frame)
                    )
                    self.syncFrame()
                    if !self.isManipulating {
                        self.controlRevealGeneration += 1
                        self.scheduleFreshMirrorReveal(
                            generation: self.controlRevealGeneration,
                            afterFrameCount: beforeRecoveryFrameCount,
                            attempt: 0
                        )
                    }
                    self.recoveryTask = nil
                    print("[info] capture recovered for window \(self.scWindow.windowID)")
                    return
                } catch {
                    print("[warn] recovery attempt \(attempt) failed: \(error)")
                }
            }

            self.recoveryTask = nil
            if self.observedWindowStillExists() {
                self.isTemporarilyUnavailable = true
                self.controlPanel.orderOut(nil)
                self.panel.orderOut(nil)
            } else {
                PinManager.shared.unpinByWindowID(self.scWindow.windowID)
            }
        }
    }

    private func observedWindowStillExists() -> Bool {
        guard let observedAXWindow else { return false }
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(observedAXWindow, &windowID) == .success,
           windowID == scWindow.windowID {
            return true
        }
        // A readable role proves the AX element remains live even when its
        // framework-specific ID differs or a miniaturised window has no frame.
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            observedAXWindow, kAXRoleAttribute as CFString, &role
        ) == .success && role != nil
    }

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            let handleEvent = {
                if self.controlPanel.isVisible,
                   self.controlPanel.frame.contains(NSEvent.mouseLocation) {
                    // Keep the hit-target window present for the complete
                    // button down/up sequence.
                    return
                }
                switch event.type {
                case .leftMouseDown:
                    // Include the normal macOS resize affordance just outside
                    // the visible frame, rather than demanding pixel-perfect
                    // clicks on the border.
                    self.mouseDownInside = self.panel.frame
                        .insetBy(dx: -12, dy: -12)
                        .contains(NSEvent.mouseLocation)
                    if self.mouseDownInside {
                        // The mirror ignores mouse events, so AppKit already
                        // delivers this click directly to the real window.
                        // Explicitly activating and AX-raising it here races
                        // native title-bar controls and double-click zoom.
                        self.startGeometryTracking()
                        let point = NSEvent.mouseLocation
                        let frame = self.panel.frame
                        let nearEdge = point.x <= frame.minX + 16
                            || point.x >= frame.maxX - 16
                            || point.y <= frame.minY + 16
                            || point.y >= frame.maxY - 16
                        let inTitleBar = point.y >= frame.maxY - 32
                        if nearEdge || inTitleBar {
                            // Hide before the first WindowServer update so no
                            // stale rectangular mirror survives for a frame.
                            self.beginManipulation()
                        }
                    }

                case .leftMouseUp:
                    self.mouseDownInside = false
                    self.stopGeometryTracking()
                    self.endManipulation()

                default:
                    break
                }
            }

            if Thread.isMainThread {
                handleEvent()
            } else {
                DispatchQueue.main.async(execute: handleEvent)
            }
        }
    }

    private func startInputRoutingTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let mirror = Unmanaged<MirrorPanel>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = mirror.inputEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard (type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp),
                  !mirror.isStopped else {
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == mirror.replayEventMarker {
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseUp, mirror.routingPending {
                if mirror.routingReplacementDownPosted {
                    mirror.routingPending = false
                    return Unmanaged.passUnretained(event)
                }
                mirror.routingEarlyMouseUp = true
                mirror.routingEarlyMouseUpEvent = (event.location, event.flags)
                return nil
            }
            if type == .leftMouseDragged, mirror.routingPending {
                if mirror.routingReplacementDownPosted {
                    return Unmanaged.passUnretained(event)
                }
                mirror.routingPendingDrag = (event.location, event.flags)
                return nil
            }
            guard type == .leftMouseDown else {
                return Unmanaged.passUnretained(event)
            }

            let cgPoint = event.location
            let sourceFrame = mirror.currentWindowServerFrame() ?? mirror.scWindow.frame
            guard sourceFrame.insetBy(dx: -12, dy: -12).contains(cgPoint) else {
                return Unmanaged.passUnretained(event)
            }

            // The independent control panel sits above the mirror. Let its
            // buttons receive their native down/up sequence; routing these
            // events to the source instead clicks macOS's sharing pill.
            let controlStrip = CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.minY,
                width: 76,
                height: 28
            )
            if controlStrip.contains(cgPoint) {
                // The control panel overlaps the native top-left resize
                // affordance. Consume and replay border gestures only after
                // raising the source, so the panel cannot swallow resizing.
                let onResizeBorder = cgPoint.x <= sourceFrame.minX + 5
                    || cgPoint.y <= sourceFrame.minY + 5
                if onResizeBorder {
                    mirror.beginRoutedMouseSequence(at: cgPoint, flags: event.flags)
                    if !mirror.didVerifyTopLeftResizeRouting {
                        mirror.didVerifyTopLeftResizeRouting = true
                        print("[diag] top-left resize border routed to native window")
                        fflush(stdout)
                    }
                    return nil
                }
                let onButtonBand = cgPoint.x >= sourceFrame.minX + 6
                    && cgPoint.x <= sourceFrame.minX + 66
                if onButtonBand && mirror.controlPanel.isVisible {
                    return Unmanaged.passUnretained(event)
                }
                // Never allow a transiently absent/misaligned overlay to turn
                // a traffic-light click into a sharing-pill click.
                return nil
            }

            // This callback runs at the head of session event delivery. Focus
            // the exact source before WindowServer chooses a mouse recipient.
            guard mirror.prepareSourceWindowForInput(at: cgPoint) else {
                return Unmanaged.passUnretained(event)
            }

            if !mirror.didVerifyInputRouting {
                mirror.didVerifyInputRouting = true
                print("[diag] obscured pinned-window click routed")
                fflush(stdout)
            }

            mirror.beginRoutedMouseSequence(at: cgPoint, flags: event.flags)
            return nil
        }

        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: pointer
        ) else {
            print("[error] input routing event tap unavailable")
            fflush(stdout)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        inputEventTap = tap
        inputEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[diag] input routing event tap verified")
        fflush(stdout)
    }

    private func beginRoutedMouseSequence(at point: CGPoint, flags: CGEventFlags) {
        routingGeneration += 1
        let generation = routingGeneration
        routingPending = true
        routingReplacementDownPosted = false
        routingEarlyMouseUp = false
        routingPendingDrag = nil
        routingEarlyMouseUpEvent = nil

        postRoutedMouseSequence(
            at: point, flags: flags, generation: generation, attempt: 0
        )
    }

    private func postRoutedMouseSequence(
        at point: CGPoint, flags: CGEventFlags, generation: Int, attempt: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.005 : 0.01)) { [weak self] in
            guard let self, self.routingPending, self.routingGeneration == generation else { return }
            _ = self.prepareSourceWindowForInput(at: point)
            if let pid = self.scWindow.owningApplication?.processID,
               let sourceWindow = self.resolvedAXWindow(),
               !(self.sourceWindowIsFocused(sourceWindow, pid: pid)
                    && self.sourceWindowIsTopmost(at: point)),
               attempt < 20 {
                self.postRoutedMouseSequence(
                    at: point, flags: flags, generation: generation, attempt: attempt + 1
                )
                return
            }

            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left)
            down?.flags = flags
            down?.setIntegerValueField(.eventSourceUserData, value: self.replayEventMarker)
            down?.post(tap: .cghidEventTap)
            self.routingReplacementDownPosted = true

            if let pendingDrag = self.routingPendingDrag {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    guard let self else { return }
                    let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                       mouseCursorPosition: pendingDrag.point, mouseButton: .left)
                    drag?.flags = pendingDrag.flags
                    drag?.setIntegerValueField(.eventSourceUserData, value: self.replayEventMarker)
                    drag?.post(tap: .cghidEventTap)
                }
            }

            if self.routingEarlyMouseUp {
                let earlyUp = self.routingEarlyMouseUpEvent
                let upDelay = self.routingPendingDrag == nil ? 0.01 : 0.025
                DispatchQueue.main.asyncAfter(deadline: .now() + upDelay) { [weak self] in
                    guard let self else { return }
                    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                     mouseCursorPosition: earlyUp?.point ?? point, mouseButton: .left)
                    up?.flags = earlyUp?.flags ?? flags
                    up?.setIntegerValueField(.eventSourceUserData, value: self.replayEventMarker)
                    up?.post(tap: .cghidEventTap)
                    self.routingPending = false
                }
            }
        }
    }

    private func sourceWindowIsFocused(_ sourceWindow: AXUIElement, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focusedRef
        ) == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var focusedID: CGWindowID = 0
        var sourceID: CGWindowID = 0
        guard _AXUIElementGetWindow(focused, &focusedID) == .success,
              _AXUIElementGetWindow(sourceWindow, &sourceID) == .success,
              focusedID != 0, sourceID != 0 else { return false }
        return focusedID == sourceID
    }

    private func sourceWindowIsTopmost(at point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                == scWindow.windowID
        }
        return false
    }

    private func prepareSourceWindowForInput(at point: CGPoint) -> Bool {
        guard let pid = scWindow.owningApplication?.processID,
              let sourceWindow = resolvedAXWindow() else { return false }
        let focused = sourceWindowIsFocused(sourceWindow, pid: pid)
        let topmost = sourceWindowIsTopmost(at: point)
        guard !focused || !topmost else { return false }

        let app = AXUIElementCreateApplication(pid)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, sourceWindow
        )
        return true
    }

    private func startGeometryTracking() {
        guard geometryTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, !self.isStopped else { return }

            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.stopGeometryTracking()
                self.endManipulation()
                return
            }

            // Core Graphics snapshots do not synchronously query the target
            // application's Accessibility server, keeping its UI responsive.
            guard let actualFrame = self.currentCGFrame() else { return }
            let referenceFrame = self.pendingFrame ?? self.panel.frame
            let originChanged = abs(actualFrame.origin.x - referenceFrame.origin.x) > 0.5
                || abs(actualFrame.origin.y - referenceFrame.origin.y) > 0.5
            let sizeChanged = abs(actualFrame.width - referenceFrame.width) > 0.5
                || abs(actualFrame.height - referenceFrame.height) > 0.5

            if originChanged || sizeChanged {
                self.pendingFrame = actualFrame
                if sizeChanged {
                    self.rebuildAfterManipulation = true
                }
                self.beginManipulation()
            }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        geometryTimer = timer
    }

    private func stopGeometryTracking() {
        geometryTimer?.invalidate()
        geometryTimer = nil
    }

    private func startControlAlignment() {
        guard hasNativeWindowControls else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self,
                  !self.isStopped,
                  !self.isManipulating,
                  self.panel.isVisible
            else { return }
            if self.mirrorGeometryIsCommitted() {
                self.positionWindowControls(for: self.panel.frame)
                if !self.controlPanel.isVisible {
                    self.controlPanel.orderFrontRegardless()
                }
                self.isAwaitingControlReveal = false
                self.verifyWindowControlInvariant()
            } else {
                if !self.isAwaitingControlReveal {
                    self.isAwaitingControlReveal = true
                    self.controlPanel.orderOut(nil)
                    self.scheduleControlReveal()
                }
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        controlAlignmentTimer = timer
    }

    private func beginManipulation() {
        if !isManipulating {
            isManipulating = true
            manipulationStartFrameCount = capture.frameState.count
            controlRevealGeneration += 1
            controlPanel.orderOut(nil)
            panel.orderOut(nil)
            CATransaction.flush()
            isAwaitingFreshMirror = false
            if !didVerifySynchronousManipulationHide {
                didVerifySynchronousManipulationHide = true
                if !controlPanel.isVisible && !panel.isVisible {
                    print("[diag] manipulation overlays hidden synchronously")
                } else {
                    print("[error] manipulation overlay remained visible after hide flush")
                }
                fflush(stdout)
            }
        }
    }

    private func scheduleManipulationCompletion() {
        manipulationSettleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleManipulationCompletion()
            } else {
                self.endManipulation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manipulationSettleTimer = timer
    }

    private func endManipulation() {
        guard isManipulating else { return }
        manipulationSettleTimer?.invalidate()
        manipulationSettleTimer = nil
        isManipulating = false

        let requiresFreshFrame = rebuildAfterManipulation
        rebuildAfterManipulation = false

        // Pending and Accessibility frames can both describe an intermediate
        // zoom/constraint state. Read the final geometry actually published by
        // WindowServer before showing the mirror and controls again.
        syncFrame()
        self.pendingFrame = nil
        if isDirectPresentation {
            hideOverlays()
            return
        }
        if requiresFreshFrame {
            scheduleFreshMirrorReveal(
                generation: controlRevealGeneration,
                afterFrameCount: manipulationStartFrameCount
            )
        } else {
            panel.orderFrontRegardless()
            scheduleControlReveal()
        }

        // Some applications settle snapped or constrained sizes shortly after
        // mouse-up. Reconcile more than once so an intermediate AX size cannot
        // leave the mirror permanently shrunken.
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped, !self.isManipulating,
                      !self.isDirectPresentation else { return }
                self.syncFrame()
                if requiresFreshFrame {
                    self.scheduleFreshMirrorReveal(
                        generation: self.controlRevealGeneration,
                        afterFrameCount: self.manipulationStartFrameCount
                    )
                } else {
                    self.panel.orderFrontRegardless()
                    self.scheduleControlReveal()
                }
            }
        }
    }

    private func scheduleFreshMirrorReveal(
        generation: Int,
        afterFrameCount: UInt64,
        attempt: Int = 0
    ) {
        if attempt == 0 {
            guard !isAwaitingFreshMirror else { return }
            isAwaitingFreshMirror = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.scheduleFreshMirrorReveal(
                    generation: generation,
                    afterFrameCount: afterFrameCount,
                    attempt: 1
                )
            }
            return
        }
        guard !isStopped, !isManipulating, !isDirectPresentation,
              generation == controlRevealGeneration else {
            isAwaitingFreshMirror = false
            return
        }
        let requested = capture.configuredPixelSize
        let delivered = capture.deliveredFrameGeometry.pixels
        let frameState = capture.frameState
        let fresh = frameState.count > afterFrameCount
            && abs(delivered.width - requested.width) <= 1
            && abs(delivered.height - requested.height) <= 1
        if fresh {
            isAwaitingFreshMirror = false
            panel.orderFrontRegardless()
            scheduleControlReveal()
            if !didVerifyFreshResizeReveal {
                didVerifyFreshResizeReveal = true
                print("[diag] resized mirror revealed with fresh capture frame")
                fflush(stdout)
            }
        } else if attempt < 200 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.scheduleFreshMirrorReveal(
                    generation: generation,
                    afterFrameCount: afterFrameCount,
                    attempt: attempt + 1
                )
            }
        } else {
            isAwaitingFreshMirror = false
            print("[error] fresh mirror frame timed out: requested=\(requested) delivered=\(delivered) before=\(afterFrameCount) now=\(frameState.count)")
            fflush(stdout)
        }
    }

    private func scheduleControlReveal(attempt: Int = 0) {
        guard !isDirectPresentation else {
            isAwaitingControlReveal = false
            controlPanel.orderOut(nil)
            return
        }
        guard hasNativeWindowControls else {
            isAwaitingControlReveal = false
            controlPanel.orderOut(nil)
            return
        }
        let generation = controlRevealGeneration
        isAwaitingControlReveal = true
        let preserveVisibleSurface = preservesControlsDuringRecovery
            && controlPanel.isVisible
        if !preserveVisibleSurface {
            controlPanel.orderOut(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self,
                  !self.isStopped,
                  !self.isSuspended,
                  !self.isTemporarilyUnavailable,
                  !self.isManipulating,
                  !self.isDirectPresentation,
                  generation == self.controlRevealGeneration
            else { return }

            if self.mirrorGeometryIsCommitted() {
                self.positionWindowControls(for: self.panel.frame)
                if !self.controlPanel.isVisible {
                    self.controlPanel.orderFrontRegardless()
                }
                self.isAwaitingControlReveal = false
                self.verifyWindowControlInvariant()
                if self.preservesControlsDuringRecovery,
                   let threshold = self.recoveryControlFrameThreshold,
                   self.capture.frameState.count > threshold {
                    self.preservesControlsDuringRecovery = false
                    self.recoveryControlFrameThreshold = nil
                    print("[diag] click-away controls remained continuously visible")
                    fflush(stdout)
                }
            } else if attempt < 50 {
                self.scheduleControlReveal(attempt: attempt + 1)
            } else {
                self.isAwaitingControlReveal = false
                let presented = self.presentedMirrorFrame().map(String.init(describing:)) ?? "missing"
                print("[warn] mirror geometry commit timed out: model=\(self.panel.frame) presented=\(presented)")
                fflush(stdout)
            }
        }
    }

    private func presentedMirrorFrame() -> NSRect? {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], CGWindowID(panel.windowNumber)
            ) as? [[String: Any]],
            let bounds = info.first?[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return cgToNS(frame)
    }

    private func mirrorGeometryIsCommitted() -> Bool {
        guard panel.isVisible, let actual = presentedMirrorFrame() else { return false }
        // WindowServer may report a compatibility-scaled frame which is not
        // numerically comparable with AppKit's model frame. Existence and a
        // nontrivial presented size are the reliable commit boundary; the
        // regression suite separately compares mirror/control CG geometry.
        return actual.width > 1 && actual.height > 1
    }

    private func configureWindowControls(for frame: NSRect) {
        controlPanel = UnconstrainedControlPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        controlPanel.isOpaque = false
        controlPanel.backgroundColor = .clear
        controlPanel.hasShadow = false
        controlPanel.isReleasedWhenClosed = false
        controlPanel.hidesOnDeactivate = false
        controlPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        controlPanel.ignoresMouseEvents = false
        controlPanel.acceptsMouseMovedEvents = true

        let content = NSView(frame: NSRect(
            x: 0, y: 0,
            width: controlStripWidth - controlResizeInset,
            height: controlStripHeight - controlResizeInset
        ))
        content.wantsLayer = true

        let controlFrame = NSRect(
            x: 0,
            y: max(0, (panel.contentView?.bounds.height ?? titlebarRepairHeight) - titlebarRepairHeight),
            width: panel.contentView?.bounds.width ?? frame.width,
            height: titlebarRepairHeight
        )
        let backdrop = WindowControlBackdropView(frame: controlFrame)
        backdrop.autoresizingMask = [.width, .minYMargin]
        backdrop.layer?.zPosition = 9_999
        controlBackdropView = backdrop
        backdrop.setTitle(scWindow.title)
        panel.contentView?.addSubview(backdrop)

        let visual = WindowControlStripView(
            frame: NSRect(
                x: -controlResizeInset, y: 0,
                width: controlStripWidth, height: controlStripHeight
            )
        )
        visual.owner = self
        visual.wantsLayer = true
        // Render the circles in the same WindowServer window that owns their
        // hit targets. A nearly transparent hit-only window can be omitted
        // from hit testing, allowing the sharing pill below to receive clicks.
        visualControlView = visual
        content.addSubview(visual)

        controlPanel.contentView = content
        positionWindowControls(for: frame)
        // Do not attach this hit target as an NSWindow child. Reordering the
        // mirror implicitly reorders child windows and can resurrect a hidden
        // target at its previous frame during a resize. Its explicit higher
        // level and the alignment controller provide deterministic ownership.
    }

    private func positionWindowControls(for frame: NSRect) {
        controlPanel?.setFrame(
            NSRect(
                x: frame.minX + controlResizeInset,
                y: frame.maxY - controlStripHeight,
                width: controlStripWidth - controlResizeInset,
                height: controlStripHeight - controlResizeInset
            ),
            display: false
        )
    }

    fileprivate func performWindowControl(_ action: Int) {
        guard let axWindow = resolvedAXWindow() else { return }
        if action == 1 {
            var buttonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                axWindow, kAXMinimizeButtonAttribute as CFString, &buttonRef
            ) == .success, let buttonRef {
                let button = unsafeBitCast(buttonRef, to: AXUIElement.self)
                prepareForNativeMinimize()
                CATransaction.flush()
                didRequestNativeMinimizeAnimation = true
                // One native button press starts the Dock's normal genie/scale
                // animation after the overlay transaction is flushed. Do not
                // reuse the button element: it can become stale. Some apps
                // nevertheless return success without transitioning, so verify
                // the window state and fall back to the native AX attribute.
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    var minimizedRef: CFTypeRef?
                    let minimized = AXUIElementCopyAttributeValue(
                        axWindow, kAXMinimizedAttribute as CFString, &minimizedRef
                    ) == .success
                        && minimizedRef.map { CFEqual($0, kCFBooleanTrue) } == true
                    if !minimized {
                        AXUIElementSetAttributeValue(
                            axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                        )
                    }
                }
            } else {
                prepareForNativeMinimize()
                CATransaction.flush()
                AXUIElementSetAttributeValue(
                    axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                )
            }
            return
        }

        let attribute = action == 0 ? kAXCloseButtonAttribute : kAXZoomButtonAttribute
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axWindow, attribute as CFString, &value) == .success,
            let value
        else { return }
        if action == 2 {
            // Some applications resize for a zoom-button press without
            // delivering a usable AXResized notification to our observer.
            // Hide the old mirror before the animation and independently
            // reconcile the destination throughout the transition.
            beginManipulation()
        }
        let result = AXUIElementPerformAction(
            unsafeBitCast(value, to: AXUIElement.self),
            kAXPressAction as CFString
        )
        if action == 2, result == .success {
            for delay in [0.05, 0.15, 0.35, 0.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.syncFrameFromAccessibility()
                    if delay == 0.7 {
                        self.endManipulation()
                    }
                }
            }
        }
        if result != .success {
            print("[error] window control AX press failed: action=\(action) result=\(result.rawValue)")
            fflush(stdout)
        }
    }

    fileprivate func prepareForNativeMinimize() {
        controlRevealGeneration += 1
        isAwaitingControlReveal = false
        hideOverlays()
        isTemporarilyUnavailable = true
        recoveryTask?.cancel()
        recoveryTask = nil
        capture.stopCapture()
    }

    fileprivate func recordOverlayControlClick(action: Int) {
        if !didVerifyOverlayControlClick {
            didVerifyOverlayControlClick = true
            print("[diag] overlay window control click verified")
        }
        print("[diag] overlay window control invoked: action=\(action)")
        fflush(stdout)
    }

    @MainActor
    private func postOverlayControlClick(_ index: Int) async -> Bool {
        for _ in 0..<120 {
            let aligned = abs(controlPanel.frame.minX - (panel.frame.minX + controlResizeInset)) <= 1
                && abs(controlPanel.frame.minY - (panel.frame.maxY - controlStripHeight)) <= 1
            if controlPanel.isVisible && !isAwaitingControlReveal && aligned { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard controlPanel.isVisible, !isAwaitingControlReveal,
              abs(controlPanel.frame.minX - (panel.frame.minX + controlResizeInset)) <= 1,
              abs(controlPanel.frame.minY - (panel.frame.maxY - controlStripHeight)) <= 1
        else { return false }
        return (visualControlView as? WindowControlStripView)?
            .invokeForRegression(index) == true
    }

    @MainActor
    private func verifyOverlayHoverForRegression() async -> Bool {
        for _ in 0..<40 {
            let aligned = abs(controlPanel.frame.minX - (panel.frame.minX + controlResizeInset)) <= 1
                && abs(controlPanel.frame.minY - (panel.frame.maxY - controlStripHeight)) <= 1
            if controlPanel.isVisible && !isAwaitingControlReveal && aligned { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let strip = visualControlView as? WindowControlStripView else { return false }
        return strip.verifyHoverStateForRegression()
    }

    private func resolvedAXWindow() -> AXUIElement? {
        guard let pid = scWindow.owningApplication?.processID else { return nil }
        if let observedAXWindow {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                observedAXWindow, kAXRoleAttribute as CFString, &role
            ) == .success, role != nil {
                return observedAXWindow
            }
        }
        let app = AXUIElementCreateApplication(pid_t(pid))
        if let current = findAXWindow(axApp: app) {
            observedAXWindow = current
            return current
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &ref) == .success,
               let ref {
                let current = unsafeBitCast(ref, to: AXUIElement.self)
                observedAXWindow = current
                return current
            }
        }
        return nil
    }

    fileprivate func exerciseWindowControlsForRegression() {
        guard let initialFrame = currentCGFrame() else {
            print("[error] regression controls unavailable; trusted=\(AXIsProcessTrusted()) pid=\(scWindow.owningApplication?.processID ?? -1)")
            fflush(stdout)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.verifyOverlayHoverForRegression() {
                print("[diag] window control hover glyphs verified")
            } else {
                print("[error] window control hover glyphs failed")
            }
            fflush(stdout)
            let zoomClickPosted = await self.postOverlayControlClick(2)
            var zoomed = false
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if self.currentCGFrame().map({
                    abs($0.width - initialFrame.width) > 10
                        || abs($0.height - initialFrame.height) > 10
                }) == true {
                    zoomed = true
                    break
                }
            }

            // AX zoom activates the fixture. The remainder of this regression
            // intentionally assesses the inactive floating presentation, so
            // return to that state explicitly instead of racing workspace
            // activation notifications.
            if zoomed {
                self.setSourceApplicationActive(false)
            }

            var maximizedShapeReady = false
            for _ in 0..<80 {
                if self.isMaximizedFrame(self.panel.frame),
                   self.panel.contentView?.layer?.cornerRadius == 0,
                   !self.panel.hasShadow {
                    maximizedShapeReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if maximizedShapeReady {
                print("[diag] maximized overlay uses square corners")
            } else {
                print("[error] maximized overlay corner invariant failed: frame=\(self.panel.frame) radius=\(self.panel.contentView?.layer?.cornerRadius ?? -1) shadow=\(self.panel.hasShadow)")
            }
            fflush(stdout)

            let restoreClickPosted = zoomClickPosted
                ? await self.postOverlayControlClick(2)
                : false
            var restoredVisualReady = false
            for _ in 0..<80 {
                if self.controlPanel.isVisible,
                   !self.isAwaitingControlReveal,
                   self.controlVisualRendersCorrectly(),
                   self.captureIsRetinaSharp() {
                    restoredVisualReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if restoreClickPosted && restoredVisualReady {
                print("[diag] post-zoom titlebar and Retina capture verified")
            } else {
                print("[error] post-zoom titlebar or Retina capture failed: requested=\(self.capture.configuredPixelSize) delivered=\(self.capture.deliveredFrameGeometry) repair=\(self.capture.repairImageSize) frame=\(self.panel.frame) scale=\(self.captureScale(for: self.panel.frame))")
            }
            fflush(stdout)
            let minimiseClickPosted = restoreClickPosted
                ? await self.postOverlayControlClick(1)
                : false
            var minimized = false
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                // A successfully miniaturised window may immediately vanish
                // from kAXWindows, so accept WindowServer's off-screen state
                // before attempting to resolve that AX element again.
                if !self.isSourceWindowOnScreen() {
                    minimized = true
                    break
                }
                var minimizedRef: CFTypeRef?
                guard let currentWindow = self.resolvedAXWindow() else { continue }
                let minimizedAttribute = AXUIElementCopyAttributeValue(
                    currentWindow,
                    kAXMinimizedAttribute as CFString,
                    &minimizedRef
                ) == .success && minimizedRef.map { CFEqual($0, kCFBooleanTrue) } == true
                if minimizedAttribute {
                    minimized = true
                    break
                }
            }

            if let restoredWindow = self.resolvedAXWindow() {
                AXUIElementSetAttributeValue(
                    restoredWindow,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            minimizeAllWindows()
            var minimizedByGlobalAction = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                var minimizedRef: CFTypeRef?
                if let currentWindow = self.resolvedAXWindow(),
                   AXUIElementCopyAttributeValue(
                    currentWindow, kAXMinimizedAttribute as CFString, &minimizedRef
                   ) == .success,
                   minimizedRef.map({ CFEqual($0, kCFBooleanTrue) }) == true {
                    minimizedByGlobalAction = true
                    break
                }
                if !self.isSourceWindowOnScreen() {
                    minimizedByGlobalAction = true
                    break
                }
            }
            if let restoredWindow = self.resolvedAXWindow() {
                AXUIElementSetAttributeValue(
                    restoredWindow,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }

            var restoredControlsReady = false
            for _ in 0..<120 {
                if self.controlPanel.isVisible,
                   !self.isAwaitingControlReveal,
                   self.controlVisualRendersCorrectly() {
                    restoredControlsReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if restoredControlsReady {
                print("[diag] window controls remained hit-testable after minimize and restore")
            } else {
                print("[error] restored window controls were not hit-testable")
            }

            if minimizedByGlobalAction {
                print("[diag] minimise-all native animation verified")
            } else {
                print("[error] minimise-all native animation failed")
            }

            if zoomed && minimiseClickPosted && minimized && self.didRequestNativeMinimizeAnimation {
                print("[diag] window control actions verified")
            } else {
                print("[error] window control actions failed: zoom=\(zoomed) minimise=\(minimized) native=\(self.didRequestNativeMinimizeAnimation)")
            }
            fflush(stdout)

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = await self.postOverlayControlClick(0)
        }
    }

    private func findAXDescendant(_ root: AXUIElement, identifier: String) -> AXUIElement? {
        var identifierRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXIdentifierAttribute as CFString, &identifierRef) == .success,
           (identifierRef as? String) == identifier {
            return root
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let match = findAXDescendant(child, identifier: identifier) { return match }
        }
        return nil
    }

    fileprivate func exerciseInputForRegression(completion: @escaping () -> Void) {
        guard let pid = scWindow.owningApplication?.processID,
              let axWindow = resolvedAXWindow(),
              let editor = findAXDescendant(axWindow, identifier: "FloatKitRegressionEditor")
        else {
            print("[error] regression editor unavailable")
            fflush(stdout)
            completion()
            return
        }

        let expected = "floatkit-input-ok"
        AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, "" as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(editor, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            print("[error] regression editor geometry unavailable")
            fflush(stdout)
            completion()
            return
        }
        let positionValue = unsafeBitCast(positionRef, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        let initialCaptureState = capture.frameState
        let click = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: click, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: click, mouseButton: .left)?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let keyCodes: [Character: CGKeyCode] = [
                "f": 3, "l": 37, "o": 31, "a": 0, "t": 17, "k": 40,
                "i": 34, "n": 45, "p": 35, "u": 32, "x": 7, "-": 27,
            ]
            let source = CGEventSource(stateID: .combinedSessionState)
            for character in expected {
                guard let keyCode = keyCodes[character] else { continue }
                CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
                    .postToPid(pid)
                CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
                    .postToPid(pid)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            var valueRef: CFTypeRef?
            let value = AXUIElementCopyAttributeValue(editor, kAXValueAttribute as CFString, &valueRef) == .success
                ? valueRef as? String : nil
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let app = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            var focusedIdentifierRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
                let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
                _ = AXUIElementCopyAttributeValue(
                    focused, kAXIdentifierAttribute as CFString, &focusedIdentifierRef
                )
            }
            if value == expected && frontmost {
                print("[diag] pinned window click and keyboard input verified")
            } else {
                print("[error] pinned window input failed: value=\(value ?? "missing") frontmost=\(frontmost) point=\(click) editor=\(position)/\(size) focused=\(focusedIdentifierRef as? String ?? "unknown")")
            }
            let updatedCaptureState = self.capture.frameState
            if self.isDirectPresentation && !self.capture.capturing
                && !self.panel.isVisible && !self.controlPanel.isVisible
                && updatedCaptureState.count == initialCaptureState.count {
                print("[diag] active native content bypassed mirror updates")
            } else {
                print("[error] active native presentation invariant failed: before=\(initialCaptureState) after=\(updatedCaptureState) capturing=\(self.capture.capturing) mirror=\(self.panel.isVisible) controls=\(self.controlPanel.isVisible)")
            }
            fflush(stdout)
            self.exerciseRoutedDragForRegression(completion: completion)
        }
    }

    private func exerciseRoutedDragForRegression(completion: @escaping () -> Void) {
        guard let pid = scWindow.owningApplication?.processID,
              let initial = currentWindowServerFrame() else {
            print("[error] regression routed drag unavailable")
            fflush(stdout)
            completion()
            return
        }

        // Re-obscure the pinned source so this gesture must take the routing
        // path instead of falling directly through to an already-topmost source.
        setSourceApplicationActive(false)
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   (titleRef as? String) == "FloatKit Regression Blocker" {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    break
                }
            }
        }

        // Restarting a deliberately stopped ScreenCaptureKit stream requires a
        // fresh SCWindow snapshot. Wait for that transition before exercising
        // the mirrored input route; a fixed 100 ms assumed unrealistically
        // fast VM scheduling and tested startup jitter rather than routing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let start = CGPoint(x: initial.midX, y: initial.minY + 14)
            let finish = CGPoint(x: start.x + 64, y: start.y + 42)
            let source = CGEventSource(stateID: .combinedSessionState)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                    mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                    mouseCursorPosition: finish, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                    mouseCursorPosition: finish, mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let moved = self.currentWindowServerFrame().map {
                abs($0.minX - initial.minX) > 20 || abs($0.minY - initial.minY) > 20
            } ?? false
            if moved {
                print("[diag] obscured pinned-window drag routed")
            } else {
                print("[warn] synthetic same-application blocker drag was inconclusive")
            }
            self.stopGeometryTracking()
            self.endManipulation()
            fflush(stdout)
            completion()
        }
    }

}

// MARK: - Pin Manager

class PinManager {
    static let shared = PinManager()
    var mirrors: [MirrorPanel] = []
    var onPinChanged: (() -> Void)?

    func resyncAll() {
        for mirror in mirrors {
            mirror.ensureHealthy()
        }
    }

    func suspendAll() {
        mirrors.forEach { $0.suspendCapture() }
    }

    func resumeAll() {
        mirrors.forEach { $0.resumeCapture() }
    }

    func activeApplicationChanged(to pid: pid_t) {
        mirrors.forEach {
            $0.setSourceApplicationActive(
                $0.scWindow.owningApplication?.processID == pid
            )
        }
    }

    func prepareAllForNativeMinimize() {
        mirrors.forEach { $0.prepareForNativeMinimize() }
    }

    // Pin the frontmost window of the frontmost app
    func pinFrontmost() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            print("[warn] no frontmost app to pin")
            return
        }
        pinApp(pid: frontApp.processIdentifier, name: frontApp.localizedName ?? "?")
    }

    // Pin by app name (for CLI usage)
    func pinByName(_ appName: String, retry: Int = 0) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
        }
        guard let app = apps.first else {
            if retry < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.pinByName(appName, retry: retry + 1)
                }
                return
            }
            print("No running app matching '\(appName)'.")
            return
        }
        if !pinApp(
            pid: app.processIdentifier,
            name: app.localizedName ?? appName,
            reportMissingWindow: retry >= 20
        ), retry < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pinByName(appName, retry: retry + 1)
            }
        }
    }

    func unpinByName(_ appName: String) {
        let matching = mirrors.filter {
            $0.scWindow.owningApplication?.applicationName.localizedCaseInsensitiveContains(appName) == true
        }
        if matching.isEmpty {
            print("No pinned window matching '\(appName)'.")
            return
        }
        for m in matching {
            let name = m.scWindow.owningApplication?.applicationName ?? "?"
            mirrors.removeAll { $0.scWindow.windowID == m.scWindow.windowID }
            m.stop()
            print("Unpinned '\(name)' (window \(m.scWindow.windowID))")
            showHUD("📍 \(name)")
        }
        onPinChanged?()
    }

    func unpinByWindowID(_ windowID: CGWindowID) {
        guard let idx = mirrors.firstIndex(where: { $0.scWindow.windowID == windowID }) else { return }
        let m = mirrors.remove(at: idx)
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        m.stop()
        print("Auto-unpinned '\(name)'")
        onPinChanged?()
    }

    func unpinLast() {
        guard let m = mirrors.last else {
            print("Nothing pinned.")
            return
        }
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        mirrors.removeLast()
        m.stop()
        print("Unpinned '\(name)'")
        showHUD("📍 \(name)")
        onPinChanged?()
    }

    func unpinAll() {
        let interactionStart = CACurrentMediaTime()
        if mirrors.isEmpty {
            print("Nothing pinned.")
            return
        }
        let pinned = mirrors
        let count = pinned.count
        mirrors.removeAll()
        // Remove every surface and release the pin state immediately. Capture
        // teardown is deferred to the next run-loop turn because SCStream stop
        // can synchronously wait on ScreenCaptureKit and block interaction.
        pinned.forEach { $0.hideOverlays() }
        let allHidden = pinned.allSatisfy { !$0.panel.isVisible }
        onPinChanged?()
        DispatchQueue.main.async {
            pinned.forEach { $0.stop(flushOverlay: false) }
        }
        let interactionMilliseconds = (CACurrentMediaTime() - interactionStart) * 1_000
        if interactionMilliseconds <= 50 {
            print("[diag] unpin all interaction path stayed nonblocking")
        } else {
            print("[error] unpin all interaction path blocked for \(interactionMilliseconds) ms")
        }
        if allHidden {
            print("[diag] unpin all overlays hidden atomically")
        } else {
            print("[error] unpin all overlay remained visible")
        }
        print("Unpinned all (\(count) windows)")
        showHUD("📍 All unpinned")
        fflush(stdout)
    }

    func listPinned() {
        if mirrors.isEmpty {
            print("No pinned windows.")
            return
        }
        print("Pinned windows:")
        for m in mirrors {
            let name = m.scWindow.owningApplication?.applicationName ?? "?"
            print("  📌 \(name) (window \(m.scWindow.windowID))")
        }
    }

    // List all visible windows (for discovery)
    func listWindows(filter: String?) {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            print("Cannot get window list.")
            return
        }

        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
        }

        var rows: [(id: Int, owner: String, name: String)] = []
        for w in windowList {
            guard let wid = w[kCGWindowNumber as String] as? Int,
                  let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                if width < 50 || height < 50 { continue }
            }
            let name = w[kCGWindowName as String] as? String ?? "(untitled)"
            if let filter, !owner.localizedCaseInsensitiveContains(filter) { continue }
            rows.append((id: wid, owner: owner, name: name))
        }

        if rows.isEmpty {
            print("No windows found\(filter.map { " for '\($0)'" } ?? "").")
            return
        }

        print("\(pad("ID", 8))  \(pad("App", 22))  Window Title")
        print(String(repeating: "─", count: 65))
        for r in rows {
            print("\(pad("\(r.id)", 8))  \(pad(r.owner, 22))  \(String(r.name.prefix(32)))")
        }
    }

    /// Returns running apps that have visible windows, excluding ourselves and system agents.
    func runningAppsWithWindows() -> [NSRunningApplication] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // Collect PIDs that have at least one visible window of reasonable size
        var pidsWithWindows = Set<pid_t>()
        for w in windowList {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                if width < 50 || height < 50 { continue }
            }
            pidsWithWindows.insert(pid)
        }

        return NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != myPID &&
            app.activationPolicy == .regular &&
            pidsWithWindows.contains(app.processIdentifier)
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func isPinned(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return mirrors.contains { $0.scWindow.owningApplication?.bundleIdentifier == bundleID }
    }

    @discardableResult
    func pinApp(pid: pid_t, name: String, reportMissingWindow: Bool = true) -> Bool {
        guard let scWindow = findFrontWindow(pid: pid) else {
            if reportMissingWindow {
                print("[error] cannot find window for '\(name)' (pid \(pid))")
            }
            return false
        }

        if mirrors.contains(where: { $0.scWindow.windowID == scWindow.windowID }) {
            print("'\(name)' is already pinned.")
            return true
        }

        let m = MirrorPanel(scWindow: scWindow)
        mirrors.append(m)
        Task { await m.start() }

        print("Pinned '\(name)' (window \(scWindow.windowID))")
        showHUD("📌 \(name)")
        onPinChanged?()
        return true
    }

    private func findFrontWindow(pid: pid_t) -> SCWindow? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        var axWindow: AXUIElement?

        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = unsafeBitCast(w, to: AXUIElement.self)
        } else if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = unsafeBitCast(w, to: AXUIElement.self)
        } else if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let list = ref as? [AXUIElement], let first = list.first {
            axWindow = first
        }

        var windowID: CGWindowID = 0
        if let axWindow {
            _ = _AXUIElementGetWindow(axWindow, &windowID)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            result = content
            semaphore.signal()
        }
        semaphore.wait()

        if windowID != 0,
           let exact = result?.windows.first(where: { $0.windowID == windowID }) {
            return exact
        }

        // Some applications expose a transient Accessibility window ID while
        // ScreenCaptureKit reports the stable backing window. Fall back to the
        // foremost substantial window owned by the same process.
        return result?.windows.first(where: {
            $0.owningApplication?.processID == pid
                && $0.frame.width >= 50
                && $0.frame.height >= 50
        })
    }

    private func showHUD(_ text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.isOpaque = false
        w.hasShadow = true
        w.center()
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = w.contentView!.bounds
        label.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(label)
        w.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { w.close() }
    }
}

// MARK: - Global Hotkeys

private var hotKeyRefs: [EventHotKeyRef?] = []

private func installHotkeys() {
    var sig: OSType = 0
    for c in "PINW".utf8 { sig = (sig << 8) | OSType(c) }

    let keys: [(keyCode: UInt32, modifiers: UInt32, id: UInt32)] = [
        (0x23, UInt32(optionKey), 1),   // Option+P = pin frontmost
        (0x20, UInt32(optionKey), 2),   // Option+U = unpin last
        (0x2E, UInt32(controlKey | optionKey | cmdKey), 3), // Control+Option+Command+M
    ]

    for key in keys {
        let hkID = EventHotKeyID(signature: sig, id: key.id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(key.keyCode, key.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        DispatchQueue.main.async {
            switch hkID.id {
            case 1: PinManager.shared.pinFrontmost()
            case 2: PinManager.shared.unpinLast()
            case 3: minimizeAllWindows()
            default: break
            }
        }
        return noErr
    }, 1, &spec, nil, nil)
}

@MainActor
private func minimizeAllWindows() {
    guard AXIsProcessTrusted() else { return }
    var actions: [() -> Void] = []

    for application in NSWorkspace.shared.runningApplications where
        application.activationPolicy == .regular && !application.isHidden
    {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &value
            ) == .success,
            let windows = value as? [AXUIElement]
        else {
            continue
        }

        for window in windows {
            var minimizedRef: CFTypeRef?
            let isMinimized = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimizedRef
            ) == .success && minimizedRef.map { CFEqual($0, kCFBooleanTrue) } == true
            guard !isMinimized else { continue }

            var buttonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window, kAXMinimizeButtonAttribute as CFString, &buttonRef
            ) == .success, let buttonRef {
                let button = unsafeBitCast(buttonRef, to: AXUIElement.self)
                actions.append {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            } else {
                actions.append {
                    AXUIElementSetAttributeValue(
                        window, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                    )
                }
            }
        }
    }

    // Resolve every target while mirrors remain visible. Then hide all pinned
    // overlays together and begin native animations on the next main-loop turn.
    PinManager.shared.prepareAllForNativeMinimize()
    CATransaction.flush()
    actions.forEach { $0() }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var minimizeStatusItem: NSStatusItem?
    let statusMenu = NSMenu()
    let cliArgs: [String]
    var lastFocusedApplication: NSRunningApplication?
    var permissionTimer: Timer?
    private var lastStatusSymbolName: String?
    private var lastStatusToolTip: String?

    init(cliArgs: [String]) {
        self.cliArgs = cliArgs
    }

    private func statusSymbol(_ name: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular,
            scale: .medium
        )
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: description
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func minimizeAllVectorImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let window = NSBezierPath(
                roundedRect: NSRect(x: 2.5, y: 3.5, width: 13, height: 11),
                xRadius: 1.5,
                yRadius: 1.5
            )
            window.lineWidth = 1
            window.stroke()

            let arrow = NSBezierPath()
            arrow.lineWidth = 1
            arrow.lineCapStyle = .square
            arrow.lineJoinStyle = .miter
            arrow.move(to: NSPoint(x: 9, y: 12))
            arrow.line(to: NSPoint(x: 9, y: 7))
            arrow.move(to: NSPoint(x: 6.5, y: 9.5))
            arrow.line(to: NSPoint(x: 9, y: 7))
            arrow.line(to: NSPoint(x: 11.5, y: 9.5))
            arrow.move(to: NSPoint(x: 6, y: 5.5))
            arrow.line(to: NSPoint(x: 12, y: 5.5))
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Minimize all windows"
        return image
    }

    private func statusIconStatesAreDistinct() -> Bool {
        func alpha(_ image: NSImage, x: CGFloat, y: CGFloat) -> CGFloat {
            guard let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else { return -1 }
            let pixelX = min(bitmap.pixelsWide - 1, max(0, Int((x / 18) * CGFloat(bitmap.pixelsWide))))
            let pixelY = min(bitmap.pixelsHigh - 1, max(0, Int(((18 - y) / 18) * CGFloat(bitmap.pixelsHigh))))
            guard let color = bitmap.colorAt(x: pixelX, y: pixelY) else { return -1 }
            return color.alphaComponent
        }
        let ready = keepAboveVectorImage(active: false)
        let pinned = keepAboveVectorImage(active: true)
        let readyArrow = alpha(ready, x: 9, y: 13.5)
        let readyOutside = alpha(ready, x: 9, y: 3)
        let pinnedArrow = alpha(pinned, x: 9, y: 13.5)
        let pinnedCircle = alpha(pinned, x: 9, y: 3)
        let valid = readyArrow > 0.4 && readyOutside < 0.1
            && pinnedArrow < 0.2 && pinnedCircle > 0.7
        if !valid {
            print("[diag] status icon samples readyArrow=\(readyArrow) readyOutside=\(readyOutside) pinnedArrow=\(pinnedArrow) pinnedCircle=\(pinnedCircle)")
        }
        return valid
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if statusIconStatesAreDistinct() {
            print("[diag] ready and pinned status icon states verified")
        } else {
            print("[error] status icon state invariant failed")
        }
        fflush(stdout)
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastFocusedApplication = application
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Request Accessibility
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Merely asking ScreenCaptureKit for shareable content does not
        // reliably register a newly renamed bundle in the Screen Recording
        // privacy list. Use Core Graphics' explicit request API once so macOS
        // creates the TCC entry and presents its normal consent dialog.
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = CGRequestScreenCaptureAccess()
                DispatchQueue.main.async {
                    self?.updatePermissionStatus()
                }
            }
        }

        // Watch for app termination to auto-unpin
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let toRemove = PinManager.shared.mirrors.filter {
                    $0.scWindow.owningApplication?.bundleIdentifier == app.bundleIdentifier
                }
                toRemove.forEach { PinManager.shared.unpinByWindowID($0.scWindow.windowID) }
            }
        }

        // Handle CLI args or run as menu bar app
        if !cliArgs.isEmpty {
            handleCLI(cliArgs)
        } else {
            setupMenuBar()
            installHotkeys()
            print("FloatKit running. Option+P = pin, Option+U = unpin.")
        }
    }

    @objc func displayConfigurationChanged(_ notification: Notification) {
        // Displays, Spaces, and application windows settle at different times
        // after wake. Retry so a transient early geometry value cannot strand
        // an overlay at the screen origin.
        for delay in [0.0, 0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PinManager.shared.resyncAll()
            }
        }
    }

    @objc func systemWillSleep(_ notification: Notification) {
        PinManager.shared.suspendAll()
    }

    @objc func systemDidWake(_ notification: Notification) {
        PinManager.shared.resumeAll()
        displayConfigurationChanged(notification)
    }

    @objc func activeSpaceChanged(_ notification: Notification) {
        for delay in [0.0, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PinManager.shared.resyncAll()
            }
        }
    }

    func handleCLI(_ args: [String]) {
        // For "list" command, no need to keep running
        switch args[0] {
        case "list":
            PinManager.shared.listWindows(filter: args.count > 1 ? args[1] : nil)
            NSApp.terminate(nil)

        case "pin":
            guard args.count > 1 else {
                printUsage()
                NSApp.terminate(nil)
                return
            }
            // Delay slightly to let permissions settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let option = args.firstIndex(of: "--pid"),
                   args.indices.contains(option + 1),
                   let pid = pid_t(args[option + 1]) {
                    self.pinPIDWhenAvailable(pid, name: args[1])
                } else {
                    PinManager.shared.pinByName(args[1])
                }
                if let option = args.firstIndex(of: "--exercise-controls-after"),
                   args.indices.contains(option + 1) {
                    self.exerciseControlsWhenFileExists(args[option + 1])
                } else if let option = args.firstIndex(of: "--exercise-input-after"),
                          args.indices.contains(option + 1) {
                    self.exerciseInputWhenFileExists(args[option + 1])
                } else if args.contains("--exercise-controls") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        PinManager.shared.mirrors.last?.exerciseWindowControlsForRegression()
                    }
                }
                if let option = args.firstIndex(of: "--visual-zoom-after"),
                   args.indices.contains(option + 1) {
                    self.visualZoomWhenFileExists(args[option + 1])
                }
                if let option = args.firstIndex(of: "--unpin-after"),
                   args.indices.contains(option + 1) {
                    self.unpinWhenFileExists(args[option + 1])
                }
            }

        case "unpin":
            if args.count > 1 {
                PinManager.shared.unpinByName(args[1])
            } else {
                PinManager.shared.unpinAll()
            }
            // Give time for cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }

        case "status":
            PinManager.shared.listPinned()
            NSApp.terminate(nil)

        default:
            printUsage()
            NSApp.terminate(nil)
        }
    }

    private func exerciseControlsWhenFileExists(_ path: String, attempt: Int = 0) {
        guard attempt < 600 else {
            print("[error] regression control trigger timed out")
            fflush(stdout)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.exerciseControlsWhenFileExists(path, attempt: attempt + 1)
            }
            return
        }
        // Let the final AX resize notification and any WindowServer animation
        // settle before beginning the independent control-action phase.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PinManager.shared.mirrors.last?.exerciseWindowControlsForRegression()
        }
    }

    private func unpinWhenFileExists(_ path: String, attempt: Int = 0) {
        guard attempt < 1200 else {
            print("[error] regression unpin trigger timed out")
            fflush(stdout)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.unpinWhenFileExists(path, attempt: attempt + 1)
            }
            return
        }
        PinManager.shared.unpinAll()
    }

    private func visualZoomWhenFileExists(_ path: String, attempt: Int = 0) {
        guard attempt < 600 else {
            print("[error] visual zoom trigger timed out")
            fflush(stdout)
            return
        }
        guard FileManager.default.fileExists(atPath: path),
              let mirror = PinManager.shared.mirrors.last else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.visualZoomWhenFileExists(path, attempt: attempt + 1)
            }
            return
        }
        mirror.performWindowControl(2)
        print("[diag] visual zoom requested")
        fflush(stdout)
    }

    private func exerciseInputWhenFileExists(_ path: String, attempt: Int = 0) {
        guard attempt < 600 else {
            print("[error] regression input trigger timed out")
            fflush(stdout)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.exerciseInputWhenFileExists(path, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            PinManager.shared.mirrors.last?.exerciseInputForRegression {
                // Routed input intentionally activates the source, which now
                // withdraws every FloatKit overlay. Background it again before
                // testing the controls belonging to the mirrored state.
                PinManager.shared.mirrors.last?.setSourceApplicationActive(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    PinManager.shared.mirrors.last?.exerciseWindowControlsForRegression()
                }
            }
        }
    }

    private func pinPIDWhenAvailable(_ pid: pid_t, name: String, attempt: Int = 0) {
        if PinManager.shared.pinApp(
            pid: pid,
            name: name,
            reportMissingWindow: attempt >= 20
        ) {
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pinPIDWhenAvailable(pid, name: name, attempt: attempt + 1)
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.autosaveName = "io.github.theautoscaler.floatkit.status-item"
        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(pinStatusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        minimizeStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        minimizeStatusItem?.autosaveName = "io.github.theautoscaler.floatkit.minimize-status-item"
        if let button = minimizeStatusItem?.button {
            button.image = minimizeAllVectorImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Minimize all windows (Control-Option-Command-M)"
            button.target = self
            button.action = #selector(doMinimizeAll)
        }

        updateMenuBarTitle()
        statusMenu.delegate = self

        PinManager.shared.onPinChanged = { [weak self] in
            self?.updateMenuBarTitle()
        }

        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updatePermissionStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private var permissionsGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    private func updatePermissionStatus() {
        updateMenuBarTitle()
        minimizeStatusItem?.button?.toolTip = accessibilityGranted
            ? "Minimize all windows (Control-Option-Command-M)"
            : "Accessibility permission required"
    }

    func updateMenuBarTitle() {
        let count = PinManager.shared.mirrors.count
        let permissionWarning = !permissionsGranted
        let symbolName = permissionWarning ? "exclamationmark.triangle.fill" : "keep-above"
        let toolTip = permissionWarning
            ? "FloatKit permissions required — right-click for details"
            : (count > 0
                ? "\(count) pinned window\(count == 1 ? "" : "s")"
                : "Pin the focused window")

        guard
            symbolName != lastStatusSymbolName || toolTip != lastStatusToolTip
        else { return }

        lastStatusSymbolName = symbolName
        lastStatusToolTip = toolTip
        let image = permissionWarning
            ? statusSymbol(symbolName, description: "FloatKit permissions required")
            : keepAboveVectorImage(active: count > 0)
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = toolTip
    }

    @objc func pinStatusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || !permissionsGranted {
            statusMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        } else {
            guard let application = lastFocusedApplication else { return }
            PinManager.shared.pinApp(
                pid: application.processIdentifier,
                name: application.localizedName ?? "Unknown"
            )
        }
    }

    @objc func applicationActivated(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            application.activationPolicy == .regular
        else {
            return
        }
        lastFocusedApplication = application
        PinManager.shared.activeApplicationChanged(to: application.processIdentifier)
    }

    @MainActor @objc func doMinimizeAll() {
        if accessibilityGranted {
            minimizeAllWindows()
        } else {
            openAccessibilitySettings()
        }
    }

    @objc func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func pinAppAction(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication,
              let name = app.localizedName else { return }
        PinManager.shared.pinApp(pid: app.processIdentifier, name: name)
    }

    @objc func unpinAppAction(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? CGWindowID else { return }
        PinManager.shared.unpinByWindowID(windowID)
    }

    @objc func doUnpinAll() {
        PinManager.shared.unpinAll()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pm = PinManager.shared

        if !permissionsGranted {
            let warning = NSMenuItem(
                title: "FLOATKIT NEEDS PERMISSION",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            warning.attributedTitle = NSAttributedString(
                string: "FLOATKIT NEEDS PERMISSION",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.systemOrange
                ]
            )
            menu.addItem(warning)

            if !accessibilityGranted {
                let item = NSMenuItem(
                    title: "Open Accessibility Settings…",
                    action: #selector(openAccessibilitySettings),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            }

            if !screenRecordingGranted {
                let item = NSMenuItem(
                    title: "Open Screen Recording Settings…",
                    action: #selector(openScreenRecordingSettings),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        // --- Pinned section ---
        if !pm.mirrors.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: "PINNED",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(header)

            for m in pm.mirrors {
                let appName = m.scWindow.owningApplication?.applicationName ?? "Unknown"

                // Get window title to differentiate multiple windows from the same app
                var title = appName
                if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], m.scWindow.windowID) as? [[String: Any]],
                   let first = info.first,
                   let windowTitle = first[kCGWindowName as String] as? String,
                   !windowTitle.isEmpty {
                    title = "\(appName) — \(windowTitle)"
                }

                let item = NSMenuItem(title: title, action: #selector(unpinAppAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.scWindow.windowID

                if let bid = m.scWindow.owningApplication?.bundleIdentifier,
                   let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
                   let icon = runningApp.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }

                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // --- Available apps section ---
        let appsHeader = NSMenuItem(title: "Pin App", action: nil, keyEquivalent: "")
        appsHeader.isEnabled = false
        appsHeader.attributedTitle = NSAttributedString(
            string: "PIN AN APP",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(appsHeader)

        let apps = pm.runningAppsWithWindows()
        for app in apps {
            guard let name = app.localizedName else { continue }

            let item = NSMenuItem(title: name, action: #selector(pinAppAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app

            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }

            menu.addItem(item)
        }

        if apps.isEmpty {
            let noApps = NSMenuItem(title: "No apps with windows", action: nil, keyEquivalent: "")
            noApps.isEnabled = false
            menu.addItem(noApps)
        }

        // --- Footer ---
        menu.addItem(.separator())

        let hotkeys = NSMenuItem(title: "⌥P Pin frontmost  ·  ⌥U Unpin last", action: nil, keyEquivalent: "")
        hotkeys.isEnabled = false
        hotkeys.attributedTitle = NSAttributedString(
            string: "⌥P Pin frontmost  ·  ⌥U Unpin last",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        menu.addItem(hotkeys)

        let minimize = NSMenuItem(
            title: "Minimize All Windows",
            action: #selector(doMinimizeAll),
            keyEquivalent: "m"
        )
        minimize.target = self
        minimize.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(minimize)

        if !pm.mirrors.isEmpty {
            let unpinAll = NSMenuItem(title: "Unpin All", action: #selector(doUnpinAll), keyEquivalent: "")
            unpinAll.target = self
            menu.addItem(unpinAll)
        }

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit FloatKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

// MARK: - Usage

func printUsage() {
    print("""
    FloatKit - Pin or minimize macOS windows

    Usage:
      FloatKit                     Run as menu bar app (Option+P/U hotkeys)
      FloatKit pin <app>           Pin an app's frontmost window
      FloatKit unpin [app]         Unpin app (or all if no app given)
      FloatKit list [app]          List visible windows
      FloatKit status              Show currently pinned windows

    Hotkeys (when running as menu bar app):
      Option+P    Pin the frontmost window
      Option+U    Unpin the last pinned window

    How it works:
      Uses ScreenCaptureKit to mirror the target window into a floating
      overlay panel. The overlay passes all mouse events through to the
      real window underneath.

    Permissions required:
      - Screen Recording  (System Settings > Privacy & Security > Screen Recording)
      - Accessibility      (System Settings > Privacy & Security > Accessibility)
    """)
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cliArgs = Array(CommandLine.arguments.dropFirst())
let delegate = AppDelegate(cliArgs: cliArgs)
app.delegate = delegate
app.run()
