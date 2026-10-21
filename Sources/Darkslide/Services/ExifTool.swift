import Foundation

/// One long-lived `exiftool -stay_open` process. Every command is serialized through
/// `queue`; callers get stdout back as a string. This is how the legacy app-speed batch
/// metadata work stays fast: no process spawn per file.
final class ExifTool {
    static let shared = ExifTool()

    static var executable: String {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/exiftool/exiftool").path,
            "/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "exiftool"
    }

    private let queue = DispatchQueue(label: "exiftool", qos: .userInitiated)
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var errBuffer = Data()
    private let errLock = NSLock()
    private(set) var lastError: String = ""
    var log: ((String) -> Void)?

    struct Result {
        let output: String
        let error: String
        var ok: Bool { !error.lowercased().contains("error") }
    }

    private func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ExifTool.executable)
        p.arguments = ["-stay_open", "True", "-@", "-", "-common_args", "-charset", "filename=utf8", "-charset", "utf8"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        signal(SIGPIPE, SIG_IGN)      // a dead child must not take the app with it
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        stderr = errPipe.fileHandleForReading
        // Drain stderr continuously so a chatty command can never fill the pipe and stall.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.errLock.lock(); self.errBuffer.append(d); self.errLock.unlock()
        }
    }

    /// Runs one exiftool command (args exactly as on the command line) and waits for it.
    @discardableResult
    func run(_ args: [String]) -> Result {
        queue.sync { runLocked(args) }
    }

    func runAsync(_ args: [String], completion: @escaping (Result) -> Void) {
        queue.async { let r = self.runLocked(args); completion(r) }
    }

    private func runLocked(_ args: [String]) -> Result {
        if process == nil || process?.isRunning == false {
            do { try start() } catch { return Result(output: "", error: "cannot start exiftool: \(error)") }
        }
        guard let stdin, let stdout else { return Result(output: "", error: "exiftool not running") }
        var cmd = args.map(ExifTool.argLine).joined(separator: "\n")
        cmd += "\n-execute\n"
        do { try stdin.write(contentsOf: cmd.data(using: .utf8)!) }
        catch { process = nil; return Result(output: "", error: "exiftool is not responding: \(error.localizedDescription)") }

        var out = Data()
        let sentinel = "{ready}\n".data(using: .utf8)!
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty { break }                      // process died
            out.append(chunk)
            if out.count >= sentinel.count, out.suffix(sentinel.count) == sentinel {
                out.removeLast(sentinel.count); break
            }
        }
        var err = ""
        errLock.lock(); let d = errBuffer; errBuffer = Data(); errLock.unlock()
        if !d.isEmpty {
            // In -stay_open mode the "N image files updated" summaries land on stderr too;
            // only real diagnostics count as errors.
            err = String(decoding: d, as: UTF8.self).split(separator: "\n")
                .filter { $0.contains("Error") || $0.contains("Warning") }
                .joined(separator: "\n")
        }
        if !err.isEmpty { lastError = err; log?(err) }
        return Result(output: String(decoding: out, as: UTF8.self), error: err)
    }

    func shutdown() {
        queue.sync {
            try? stdin?.write(contentsOf: "-stay_open\nFalse\n".data(using: .utf8)!)
            process?.waitUntilExit()
            process = nil
        }
    }

    /// One argfile line per argument. Values with newlines, carriage returns, leading
    /// whitespace or a leading '#' use exiftool's #[CSTR] form with C escapes, so a
    /// multi-line caption stays one argument and can never be parsed as a filename or option.
    static func argLine(_ a: String) -> String {
        let needs = a.contains("\n") || a.contains("\r") || a.hasPrefix("#") || a.first?.isWhitespace == true
        guard needs else { return a }
        var out = "#[CSTR]"
        for ch in a.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
