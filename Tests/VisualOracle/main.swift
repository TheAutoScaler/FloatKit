import AppKit
import CoreGraphics

enum OracleError: Error, CustomStringConvertible {
    case usage
    case permissionDenied
    case windowNotFound(pid_t)
    case captureFailed(Int32, String)
    case pngWriteFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: FloatKitVisualOracle status | request | capture --pid PID --output FILE"
        case .permissionDenied:
            return "Screen Recording permission is not granted to FloatKit Visual Oracle"
        case .windowNotFound(let pid):
            return "no capturable window found for pid \(pid)"
        case .captureFailed(let status, let message):
            return "screencapture failed with status \(status): \(message)"
        case .pngWriteFailed(let path):
            return "could not write PNG to \(path)"
        }
    }
}

@main
struct FloatKitVisualOracle {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let resultPath = args.firstIndex(of: "--result").flatMap { index in
            args.indices.contains(index + 1) ? args[index + 1] : nil
        }
        do {
            let message = try await run(args: args)
            writeResult("ok: \(message)\n", to: resultPath)
        } catch {
            writeResult("error: \(error)\n", to: resultPath)
            fputs("FloatKitVisualOracle: \(error)\n", stderr)
            exit(1)
        }
    }

    static func writeResult(_ value: String, to path: String?) {
        guard let path else { return }
        try? Data(value.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func run(args: [String]) async throws -> String {
        guard let command = args.first else { throw OracleError.usage }

        switch command {
        case "status":
            let allowed = CGPreflightScreenCaptureAccess()
            guard allowed else { throw OracleError.permissionDenied }
            return "granted"

        case "request":
            let allowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            guard allowed else { throw OracleError.permissionDenied }
            return "granted"

        case "capture":
            guard CGPreflightScreenCaptureAccess() else {
                throw OracleError.permissionDenied
            }
            guard let pidIndex = args.firstIndex(of: "--pid"),
                  args.indices.contains(pidIndex + 1),
                  let pid = pid_t(args[pidIndex + 1]),
                  let outputIndex = args.firstIndex(of: "--output"),
                  args.indices.contains(outputIndex + 1)
            else { throw OracleError.usage }
            try capture(pid: pid, output: args[outputIndex + 1])
            return "captured \(args[outputIndex + 1])"

        default:
            throw OracleError.usage
        }
    }

    static func capture(pid: pid_t, output: String) throws {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates: [(id: CGWindowID, area: CGFloat)] = windows.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 50, bounds.height > 50
            else { return nil }
            return (CGWindowID(number.uint32Value), bounds.width * bounds.height)
        }
        guard let window = candidates.max(by: { $0.area < $1.area }) else {
            throw OracleError.windowNotFound(pid)
        }
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.id), output]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OracleError.captureFailed(process.terminationStatus, message)
        }
        guard FileManager.default.fileExists(atPath: output) else {
            throw OracleError.pngWriteFailed(output)
        }
    }
}
