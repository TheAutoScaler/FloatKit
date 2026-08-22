import Cocoa

final class CustomChromeFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: NSWindowController!
    private let readyPath = CommandLine.arguments.dropFirst().first
    private let pidPath = CommandLine.arguments.dropFirst(2).first

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 320, y: 300, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        window.setAccessibilityTitleUIElement(nil)
        let label = NSTextField(labelWithString: "Custom application chrome with native window actions")
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.frame = NSRect(x: 100, y: 382, width: 500, height: 24)
        window.contentView?.addSubview(label)
        controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let pidPath {
            try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: URL(fileURLWithPath: pidPath))
        }
        if let readyPath {
            FileManager.default.createFile(atPath: readyPath, contents: Data())
        }
    }
}

let app = NSApplication.shared
let delegate = CustomChromeFixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
