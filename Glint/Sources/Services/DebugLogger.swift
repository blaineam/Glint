import AppKit

/// File-based debug logger. Writes to ~/Library/Application Support/Glint/debug.log
/// when enabled via Preferences. Automatically truncates at 1 MB.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    private let maxFileSize: UInt64 = 1_000_000 // 1 MB
    private let queue = DispatchQueue(label: "com.blainemiller.Glint.logger")

    var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let glintDir = appSupport.appendingPathComponent("Glint")
        return glintDir.appendingPathComponent("debug.log")
    }

    private init() {}

    func log(_ message: String) {
        guard Preferences.shared.debugLogging else { return }
        queue.async { [self] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"

            let fm = FileManager.default
            let dir = logFileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: logFileURL.path) {
                fm.createFile(atPath: logFileURL.path, contents: nil)
            }

            // Truncate if too large
            if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? UInt64, size > maxFileSize {
                try? "--- log truncated ---\n".write(to: logFileURL, atomically: true, encoding: .utf8)
            }

            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
        }
    }

    func revealInFinder() {
        let fm = FileManager.default
        let dir = logFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        NSWorkspace.shared.selectFile(logFileURL.path, inFileViewerRootedAtPath: dir.path)
    }
}
