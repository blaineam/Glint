import AppKit

/// File-based debug logger. Writes to ~/Library/Application Support/Glint/debug.log
/// when enabled via Preferences. Automatically truncates at 1 MB.
final class DebugLogger: @unchecked Sendable {
    static let shared: DebugLogger = {
        #if DEBUG
        if UITestMode.isActive { return UITestMode.makeDebugLogger() }
        #endif
        return DebugLogger()
    }()

    private let maxFileSize: UInt64
    private let queue = DispatchQueue(label: "com.blainemiller.Glint.logger")
    private let isEnabled: () -> Bool

    let logFileURL: URL

    static var defaultLogFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let glintDir = appSupport.appendingPathComponent("Glint")
        return glintDir.appendingPathComponent("debug.log")
    }

    /// Tests inject a temporary file and their own enabled flag; the app uses the
    /// Application Support log gated by the Debug Logging preference.
    init(
        logFileURL: URL = DebugLogger.defaultLogFileURL,
        maxFileSize: UInt64 = 1_000_000, // 1 MB
        isEnabled: @escaping () -> Bool = { Preferences.shared.debugLogging }
    ) {
        self.logFileURL = logFileURL
        self.maxFileSize = maxFileSize
        self.isEnabled = isEnabled
    }

    /// Blocks until every line queued so far has been written.
    func flush() {
        queue.sync {}
    }

    func log(_ message: String) {
        guard isEnabled() else { return }
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
