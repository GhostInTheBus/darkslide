import Foundation

/// Plain-text log in Application Support/Darkslide/logs. Errors the UI shows, exiftool
/// diagnostics, ingest failures and uncaught exceptions all land here with timestamps,
/// so a problem can be diagnosed after the fact. Rotates at 2 MB, keeps three files.
enum AppLog {
    static let dir = AppPaths.support.appendingPathComponent("logs", isDirectory: true)
    static let file = dir.appendingPathComponent("darkslide.log")
    private static let queue = DispatchQueue(label: "log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    static func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        info("Darkslide \(v) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        NSSetUncaughtExceptionHandler { e in
            AppLog.write("FATAL", "uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))")
        }
    }

    static func info(_ msg: String) { write("INFO", msg) }
    static func warn(_ msg: String) { write("WARN", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    static func write(_ level: String, _ msg: String) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(msg)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd(); try? h.write(contentsOf: line.data(using: .utf8)!)
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2 << 20 else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent("darkslide.log.3"))
        for i in stride(from: 2, through: 1, by: -1) {
            try? fm.moveItem(at: dir.appendingPathComponent("darkslide.log.\(i)"), to: dir.appendingPathComponent("darkslide.log.\(i + 1)"))
        }
        try? fm.moveItem(at: file, to: dir.appendingPathComponent("darkslide.log.1"))
    }
}
