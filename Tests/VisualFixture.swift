import Cocoa

final class PatternView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let text = (0..<18).map {
            "Sharp text row \($0): MWmw 0123456789 /model openai/gpt-5.6-luna"
        }.joined(separator: "\n")
        text.draw(
            at: NSPoint(x: 8, y: bounds.height - 24),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
        )

        let origin = NSPoint(x: 430, y: 36)
        for y in 0..<80 {
            for x in 0..<220 where (x + y).isMultiple(of: 2) {
                NSColor.black.setFill()
                NSRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y), width: 1, height: 1).fill()
            }
        }
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var originalFrame = NSRect.zero
    private let controlDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    private let documentStyle = CommandLine.arguments.dropFirst(2).first == "document-style"

    func applicationDidFinishLaunching(_ notification: Notification) {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if documentStyle { styleMask.insert(.fullSizeContentView) }
        window = NSWindow(
            contentRect: NSRect(x: 220, y: 220, width: 720, height: 480),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "FloatKit Visual Regression"
        if documentStyle {
            // TextEdit uses a full-size document surface under a transparent
            // unified title bar. This is the composition that previously let
            // body text bleed under FloatKit's repaired traffic-light strip.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
        }
        window.isReleasedWhenClosed = false
        window.contentView = PatternView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        originalFrame = window.frame
        write("pid", "\(ProcessInfo.processInfo.processIdentifier)\n")
        write("ready", "ready\n")

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.processCommands()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func processCommands() {
        if consume("maximize") {
            window.zoom(nil)
            signalAfterSettle("maximized")
        }
        if consume("restore") {
            if window.isZoomed { window.zoom(nil) }
            window.setFrame(originalFrame, display: true)
            signalAfterSettle("restored")
        }
        if consume("quit") { NSApp.terminate(nil) }
    }

    private func signalAfterSettle(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.write(name, "ready\n")
        }
    }

    private func consume(_ name: String) -> Bool {
        let url = controlDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private func write(_ name: String, _ value: String) {
        try? Data(value.utf8).write(to: controlDirectory.appendingPathComponent(name))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
