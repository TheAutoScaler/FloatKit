import Cocoa

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var windowController: NSWindowController!
    private var blockerWindow: NSWindow?
    private var step = 0
    private var timer: Timer?
    private let completionPath = CommandLine.arguments.dropFirst().first
    private let pidPath = CommandLine.arguments.dropFirst(2).first

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let pidPath {
            FileManager.default.createFile(
                atPath: pidPath,
                contents: Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            )
        }
        window = NSWindow(
            contentRect: NSRect(x: 240, y: 260, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FloatKit Regression Fixture"
        window.isDocumentEdited = true
        window.setAccessibilityEdited(true)
        window.isReleasedWhenClosed = false
        let content = NSView()
        let editor = NSTextField(frame: NSRect(x: 160, y: 200, width: 400, height: 32))
        editor.identifier = NSUserInterfaceItemIdentifier("FloatKitRegressionEditor")
        editor.setAccessibilityIdentifier("FloatKitRegressionEditor")
        editor.placeholderString = "Pinned window input regression target"
        editor.delegate = self
        content.addSubview(editor)
        window.contentView = content
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        windowController = NSWindowController(window: window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startStressRun()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        // Make a stationary input update affect most captured pixels. This
        // turns stale/blank mirrors into a deterministic frame-signature
        // failure instead of relying on OCR of a few text glyphs.
        window.contentView?.layer?.backgroundColor = NSColor(
            calibratedRed: 0.20, green: 0.42, blue: 0.72, alpha: 1
        ).cgColor
    }

    private func startStressRun() {
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        step += 1

        switch step {
        case 1...40:
            var frame = window.frame
            frame.origin.x += step.isMultiple(of: 2) ? 9 : -7
            frame.origin.y += step.isMultiple(of: 3) ? 6 : -4
            window.setFrameOrigin(frame.origin)

        case 41...80:
            var frame = window.frame
            frame.size.width += step.isMultiple(of: 2) ? 11 : -9
            frame.size.height += step.isMultiple(of: 3) ? 8 : -6
            window.setFrame(frame, display: true)

        case 81...90:
            window.zoom(nil)

        case 91...97:
            break

        case 98...137:
            var frame = window.frame
            frame.origin.x += step.isMultiple(of: 2) ? 5 : -5
            frame.size.width += step.isMultiple(of: 2) ? 7 : -7
            window.setFrame(frame, display: true)

        case 138:
            // Put a second real window between the pinned source and its
            // floating mirror. A mirror that merely ignores mouse events will
            // send the click to this blocker instead of the source window.
            // This reproduces the populated-desktop input failure that a
            // single isolated fixture cannot expose.
            let blocker = NSWindow(
                contentRect: window.frame.insetBy(dx: 60, dy: 60),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            blocker.title = "FloatKit Regression Blocker"
            blocker.contentView = NSTextField(labelWithString: "This window must not receive the routed click")
            blocker.isReleasedWhenClosed = false
            blocker.orderFrontRegardless()
            blockerWindow = blocker
            if let completionPath {
                FileManager.default.createFile(atPath: completionPath, contents: Data("complete\n".utf8))
            }
            print("FIXTURE_STRESS_COMPLETE", terminator: "\n")
            fflush(stdout)

        case 600:
            // The runner allows up to 25 seconds after stress completion for
            // independent hover/control/minimise verification. Keep the source
            // alive beyond that entire window even on a loaded VM; terminating
            // at step 260 could close the capture while those checks remained
            // legitimately in progress and manufacture an auto-unpin failure.
            timer?.invalidate()
            timer = nil
            window.close()
            NSApp.terminate(nil)

        default:
            break
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let applicationItem = NSMenuItem()
mainMenu.addItem(applicationItem)
let applicationMenu = NSMenu()
applicationMenu.addItem(
    withTitle: "Quit FloatKitFixture",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
applicationItem.submenu = applicationMenu
app.mainMenu = mainMenu
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
