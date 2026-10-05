import AppKit
import XCTest
@testable import Glint

final class DebugLoggerTests: XCTestCase {
    private var directory: URL!
    private var logURL: URL { directory.appendingPathComponent("Glint/debug.log") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlintTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func contents() -> String? {
        try? String(contentsOf: logURL, encoding: .utf8)
    }

    func testDisabledLoggerWritesNothing() {
        let logger = DebugLogger(logFileURL: logURL, isEnabled: { false })
        logger.log("hello")
        logger.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testEnabledLoggerCreatesDirectoryAndAppendsTimestampedLines() throws {
        let logger = DebugLogger(logFileURL: logURL, isEnabled: { true })
        logger.log("first")
        logger.log("second")
        logger.flush()

        let lines = try XCTUnwrap(contents()).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("] first"))
        XCTAssertTrue(lines[1].hasSuffix("] second"))
        // "[<ISO-8601>] message"
        let stamp = String(lines[0].dropFirst().prefix { $0 != "]" })
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stamp), "timestamp \(stamp) is ISO-8601")
    }

    func testEnabledFlagIsReadPerMessage() {
        var enabled = false
        let logger = DebugLogger(logFileURL: logURL, isEnabled: { enabled })
        logger.log("dropped")
        enabled = true
        logger.log("kept")
        logger.flush()
        XCTAssertEqual(contents()?.contains("dropped"), false)
        XCTAssertEqual(contents()?.contains("kept"), true)
    }

    func testOversizedLogIsTruncatedWithAMarker() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 1_000_001).write(to: logURL)

        let logger = DebugLogger(logFileURL: logURL, isEnabled: { true })
        logger.log("after truncation")
        logger.flush()

        let text = try XCTUnwrap(contents())
        XCTAssertTrue(text.hasPrefix("--- log truncated ---\n"))
        XCTAssertTrue(text.hasSuffix("] after truncation\n"))
        XCTAssertLessThan(text.utf8.count, 200)
    }

    func testLogAtTheLimitIsNotTruncated() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 1_000_000).write(to: logURL)

        let logger = DebugLogger(logFileURL: logURL, isEnabled: { true })
        logger.log("appended")
        logger.flush()

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 1_000_000)
    }

    func testDefaultLocationIsApplicationSupportGlint() {
        let url = DebugLogger.defaultLogFileURL
        XCTAssertEqual(url.lastPathComponent, "debug.log")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Glint")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Application Support")
    }
}

final class OSDOverlayTests: XCTestCase {
    private let pill = NSSize(width: 200, height: 28)

    func testPillSitsBelowTheMenuBarCentred() {
        // 1440x900 screen with a 25 pt menu bar (no notch) and a bottom Dock.
        let origin = OSDOverlay.pillOrigin(
            screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 70, width: 1440, height: 805),
            pillSize: pill
        )
        XCTAssertEqual(origin.x, 620)              // 720 - 100
        XCTAssertEqual(origin.y, 900 - 25 - 8 - 28)
    }

    func testPillClearsTheTallerNotchMenuBar() {
        // MacBook Pro 14": 1512x982 with a 38 pt notch menu bar.
        let origin = OSDOverlay.pillOrigin(
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944),
            pillSize: pill
        )
        XCTAssertEqual(origin.x, 656)
        XCTAssertEqual(origin.y, 982 - 38 - 8 - 28)
    }

    func testPillUsesTheTargetScreensCoordinates() {
        // Secondary display to the left of and above the main one, auto-hidden menu bar.
        let origin = OSDOverlay.pillOrigin(
            screenFrame: NSRect(x: -2560, y: 900, width: 2560, height: 1440),
            visibleFrame: NSRect(x: -2560, y: 900, width: 2560, height: 1440),
            pillSize: pill
        )
        XCTAssertEqual(origin.x, -1280 - 100)
        XCTAssertEqual(origin.y, 900 + 1440 - 8 - 28)
    }
}
