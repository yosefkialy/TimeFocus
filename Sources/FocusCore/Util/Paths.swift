import Foundation
import os

/// All on-disk locations. Everything lives under ~/Library/Application Support/TimeFocus — nothing leaves the Mac.
public struct AppPaths {
    public let support: URL

    public init(support: URL) {
        self.support = support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    /// ~/Library/Application Support/TimeFocus (overridable with TIMEFOCUS_SUPPORT_DIR for demos/tests).
    public static let `default`: AppPaths = {
        if let custom = ProcessInfo.processInfo.environment["TIMEFOCUS_SUPPORT_DIR"], !custom.isEmpty {
            return AppPaths(support: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return AppPaths(support: base.appendingPathComponent("TimeFocus", isDirectory: true))
    }()

    /// Bundle id of TimeFocus itself — its own windows are tracked as time but never classified.
    public static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.timefocus.app"

    public var database: URL { support.appendingPathComponent("timefocus.sqlite") }
    public var models: URL { support.appendingPathComponent("Models", isDirectory: true) }
    public var studentModel: URL { support.appendingPathComponent("student.bin") }
    public var throttleState: URL { support.appendingPathComponent("throttle-state.json") }
    public var logs: URL { support.appendingPathComponent("Logs", isDirectory: true) }
    public var logFile: URL { logs.appendingPathComponent("timefocus.log") }
    public var runtime: URL { support.appendingPathComponent("Runtime", isDirectory: true) }

    public func modelDirectory(_ id: String) -> URL { models.appendingPathComponent(id, isDirectory: true) }
}

/// Structural logging (never logs window text or titles in release mode — privacy first).
public enum Log {
    private static let logger = Logger(subsystem: "com.timefocus.app", category: "core")
    private static let queue = DispatchQueue(label: "timefocus.log")
    private static var handle: FileHandle?
    public static var verbose = ProcessInfo.processInfo.environment["TIMEFOCUS_VERBOSE"] == "1"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String, _ category: String = "core") { write("INFO", category, message()) }
    public static func error(_ message: @autoclosure () -> String, _ category: String = "core") { write("ERROR", category, message()) }
    public static func debug(_ message: @autoclosure () -> String, _ category: String = "core") {
        guard verbose else { return }
        write("DEBUG", category, message())
    }

    private static func write(_ level: String, _ category: String, _ message: String) {
        logger.log("[\(category, privacy: .public)] \(message, privacy: .private)")
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async {
            let url = AppPaths.default.logFile
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            if let h = handle, let data = line.data(using: .utf8) {
                h.write(data)
                // simple rotation at 4 MB
                if let size = try? h.offset(), size > 4 << 20 {
                    try? h.close()
                    handle = nil
                    let old = url.deletingLastPathComponent().appendingPathComponent("timefocus.old.log")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
            }
        }
    }
}

extension Data {
    /// Packs Float values (little-endian, native layout) for BLOB storage.
    public init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public var floats: [Float] {
        guard count % MemoryLayout<Float>.size == 0 else { return [] }
        return withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

extension Date {
    /// Local day key "yyyy-MM-dd".
    public var dayKey: String { DayKey.formatter.string(from: self) }
    public var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    /// Minutes since local midnight.
    public var minuteOfDay: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    public var hourOfDayFraction: Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: self)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }
}

public enum DayKey {
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    public static func date(_ key: String) -> Date? { formatter.date(from: key) }
}
