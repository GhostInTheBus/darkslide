import Foundation

/// the legacy app's FTP / SFTP uploader. FTP and FTPS go through curl with the password from the
/// Keychain; SFTP goes through the system `sftp` with your SSH keys (no password prompt
/// is possible from a GUI, so key-based auth is the supported path).
struct UploadConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "New connection"
    var proto = "ftp"           // ftp, ftps, sftp
    var host = ""
    var port = 0                // 0 = default
    var user = ""
    var path = "/"              // remote directory
    var passive = true
}

enum Uploader {
    static let keychainService = "Darkslide.upload"

    static func setPassword(_ pw: String, for c: UploadConnection) {
        let acct = "\(c.user)@\(c.host)"
        let del = Process(); del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", keychainService, "-a", acct]; del.standardError = FileHandle.nullDevice; del.standardOutput = FileHandle.nullDevice
        try? del.run(); del.waitUntilExit()
        guard !pw.isEmpty else { return }
        let add = Process(); add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = ["add-generic-password", "-s", keychainService, "-a", acct, "-w", pw, "-U"]
        try? add.run(); add.waitUntilExit()
    }

    static func password(for c: UploadConnection) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", "\(c.user)@\(c.host)", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Result { var sent: [String] = []; var failures: [String] = [] }

    static func upload(_ files: [URL], via c: UploadConnection, progress: @escaping (Int, Int) -> Void, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = Result()
            let dir = c.path.hasSuffix("/") ? c.path : c.path + "/"
            if c.proto == "sftp" {
                // One batch: sftp reads commands from stdin.
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
                var args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
                if c.port > 0 { args += ["-P", "\(c.port)"] }
                args.append("\(c.user.isEmpty ? "" : c.user + "@")\(c.host)")
                p.arguments = args
                let inPipe = Pipe(), errPipe = Pipe(); p.standardInput = inPipe; p.standardError = errPipe; p.standardOutput = FileHandle.nullDevice
                do {
                    try p.run()
                    var script = "cd \"\(dir)\"\n"
                    for f in files { script += "put \"\(f.path)\"\n" }
                    script += "bye\n"
                    inPipe.fileHandleForWriting.write(script.data(using: .utf8)!); try? inPipe.fileHandleForWriting.close()
                    p.waitUntilExit()
                    let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if p.terminationStatus == 0 { result.sent = files.map(\.lastPathComponent) } else { result.failures.append("sftp: \(err.trimmingCharacters(in: .whitespacesAndNewlines))") }
                } catch { result.failures.append("sftp: \(error.localizedDescription)") }
                DispatchQueue.main.async { progress(files.count, files.count); completion(result) }
                return
            }
            let pw = password(for: c) ?? ""
            for (i, f) in files.enumerated() {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                let scheme = c.proto == "ftps" ? "ftps" : "ftp"
                let portPart = c.port > 0 ? ":\(c.port)" : ""
                var args = ["-sS", "--fail", "-T", f.path, "\(scheme)://\(c.host)\(portPart)\(dir)", "--ftp-create-dirs"]
                if !c.passive { args.append("--ftp-port"); args.append("-") }
                if !c.user.isEmpty { args += ["--user", "\(c.user):\(pw)"] }
                p.arguments = args
                let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
                do {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 { result.sent.append(f.lastPathComponent) }
                    else { result.failures.append("\(f.lastPathComponent): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))") }
                } catch { result.failures.append("\(f.lastPathComponent): \(error.localizedDescription)") }
                DispatchQueue.main.async { progress(i + 1, files.count) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
