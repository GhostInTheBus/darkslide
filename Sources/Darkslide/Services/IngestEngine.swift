import CryptoKit
import Foundation

/// Card ingest: copy everything to one or two destinations, rename on the way with the legacy app
/// variables, verify each copy by SHA-256, log it, never touch the source.
final class IngestEngine {
    struct Options {
        var sources: [URL]
        var primary: URL
        var secondary: URL?
        var folderTemplate: String
        var renameTemplate: String?           // nil = keep names
        var jobName: String
        var startSequence: Int
        var sequencePadding: Int
        var copyNonImages: Bool
        var skipMirrorCard: Bool
        var skipAlreadyIngested: Bool
        var eject: Bool
        var user: UserInfo
    }

    struct Progress {
        var total = 0
        var done = 0
        var bytesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var current = ""
        var failures: [String] = []
        var skipped = 0
        var finished = false
        var destinationFolder: URL?
        var nextSequence = 0
        var copied: [URL] = []
    }

    struct LogEntry: Codable {
        var source: String
        var primary: String
        var secondary: String?
        var sha256: String
        var verified: Bool
        var bytes: Int64
    }
    struct Log: Codable {
        var started: Date
        var finished: Date?
        var cardIDs: [String]
        var job: String
        var entries: [LogEntry]
        var failures: [String]
    }

    static let logDir = AppPaths.support.appendingPathComponent("ingest-logs", isDirectory: true)
    static let ingestedIndex = AppPaths.support.appendingPathComponent("ingested.json")

    private(set) var progress = Progress()
    var onProgress: ((Progress) -> Void)?
    private var cancelled = false
    func cancel() { cancelled = true }

    /// Files on a card, with the "card id" used to remember what was already pulled.
    struct SourceFile { let url: URL; let size: Int64; let cardID: String; let modified: Date }

    static func cardID(for volume: URL) -> String {
        // Volume UUID when we can get it, else the volume name. Cards get reformatted, so
        // this is only a hint for "skip already ingested".
        if let v = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey]) {
            return v.volumeUUIDString ?? v.volumeName ?? volume.lastPathComponent
        }
        return volume.lastPathComponent
    }

    static func enumerate(_ source: URL, imagesOnly: Bool) -> [SourceFile] {
        let id = cardID(for: source)
        var out: [SourceFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in en {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            if imagesOnly && !PhotoItem.imageExtensions.contains(u.pathExtension.lowercased()) { continue }
            if u.lastPathComponent.hasPrefix(".") { continue }
            out.append(SourceFile(url: u, size: Int64(rv.fileSize ?? 0), cardID: id, modified: rv.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    private static func loadIngested() -> Set<String> {
        guard let d = try? Data(contentsOf: ingestedIndex), let s = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(s)
    }
    private static func saveIngested(_ s: Set<String>) {
        if let d = try? JSONEncoder().encode(Array(s).sorted()) { try? d.write(to: ingestedIndex) }
    }
    static func ingestKey(_ f: SourceFile) -> String { "\(f.cardID)|\(f.url.lastPathComponent)|\(f.size)" }

    func run(_ o: Options, metaReader: @escaping (URL) -> (CaptureInfo, PhotoMeta)) {
        DispatchQueue.global(qos: .userInitiated).async { self.runSync(o, metaReader: metaReader) }
    }

    private func report() { let p = progress; DispatchQueue.main.async { self.onProgress?(p) } }

    private func runSync(_ o: Options, metaReader: (URL) -> (CaptureInfo, PhotoMeta)) {
        let fm = FileManager.default
        var ingested = IngestEngine.loadIngested()
        var files: [SourceFile] = []
        for s in o.sources { files += IngestEngine.enumerate(s, imagesOnly: !o.copyNonImages) }

        // Dual-slot mirror: same name + size on two cards → keep the first.
        if o.skipMirrorCard && o.sources.count > 1 {
            var seen = Set<String>()
            files = files.filter { f in
                let k = "\(f.url.lastPathComponent)|\(f.size)"
                if seen.contains(k) { progress.skipped += 1; return false }
                seen.insert(k); return true
            }
        }
        if o.skipAlreadyIngested {
            files = files.filter { f in
                if ingested.contains(IngestEngine.ingestKey(f)) { progress.skipped += 1; return false }
                return true
            }
        }
        progress.total = files.count
        progress.bytesTotal = files.reduce(0) { $0 + $1.size }
        report()

        var log = Log(started: Date(), finished: nil, cardIDs: o.sources.map(IngestEngine.cardID), job: o.jobName, entries: [], failures: [])
        var seq = o.startSequence
        var destFolder: URL?
        var secondaryFolder: URL?
        // Items that share a base name (RAW+JPEG, .wav) get the same new name.
        var baseNameMap: [String: String] = [:]

        for f in files {
            if cancelled { break }
            progress.current = f.url.lastPathComponent
            report()
            let (info, meta) = metaReader(f.url)
            var ctx = VariableContext(info: info, meta: meta, sequence: seq, sequencePadding: o.sequencePadding,
                                      ingestSequence: seq, jobName: o.jobName, user: o.user)
            ctx.item = PhotoItem(id: f.url, url: f.url, sidecarJPEG: nil, displayName: f.url.lastPathComponent)

            if destFolder == nil {
                let sub = RenameEngine.sanitize(Variables.expand(o.folderTemplate, ctx))
                destFolder = sub.isEmpty ? o.primary : o.primary.appendingPathComponent(sub)
                secondaryFolder = o.secondary.map { sub.isEmpty ? $0 : $0.appendingPathComponent(sub) }
                for d in [destFolder, secondaryFolder].compactMap({ $0 }) {
                    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                }
                progress.destinationFolder = destFolder
            }

            let srcBase = f.url.deletingPathExtension().lastPathComponent
            var newBase = srcBase
            // the legacy app renames every file on the card with the template, video included; files
            // sharing a base name (RAW+JPEG, .wav) get one name and one sequence number.
            if let t = o.renameTemplate, !t.isEmpty {
                if let existing = baseNameMap[srcBase] { newBase = existing }
                else {
                    newBase = RenameEngine.sanitize(Variables.expand(t, ctx))
                    baseNameMap[srcBase] = newBase
                    seq += 1
                }
            }
            let ext = f.url.pathExtension
            let primaryDest = IngestEngine.uniqueDestination(destFolder!.appendingPathComponent(newBase).appendingPathExtension(ext))
            let secondaryDest = secondaryFolder.map { IngestEngine.uniqueDestination($0.appendingPathComponent(primaryDest.lastPathComponent)) }

            do {
                let hash = try IngestEngine.copyHashed(from: f.url, to: primaryDest)
                let verified = (try? IngestEngine.sha256(of: primaryDest)) == hash
                var secondaryOK = true
                if let s = secondaryDest {
                    let h2 = try IngestEngine.copyHashed(from: f.url, to: s)
                    secondaryOK = h2 == hash && (try? IngestEngine.sha256(of: s)) == hash
                }
                if !verified || !secondaryOK {
                    let msg = "Checksum mismatch: \(f.url.lastPathComponent)"
                    progress.failures.append(msg); log.failures.append(msg)
                    try? fm.removeItem(at: primaryDest); if let s = secondaryDest { try? fm.removeItem(at: s) }   // never leave a bad copy that looks real
                } else {
                    ingested.insert(IngestEngine.ingestKey(f))
                    progress.copied.append(primaryDest)
                }
                log.entries.append(LogEntry(source: f.url.path, primary: primaryDest.path, secondary: secondaryDest?.path,
                                            sha256: hash, verified: verified && secondaryOK, bytes: f.size))
            } catch {
                let msg = "\(f.url.lastPathComponent): \(error.localizedDescription)"
                progress.failures.append(msg); log.failures.append(msg)
                try? fm.removeItem(at: primaryDest); if let s = secondaryDest { try? fm.removeItem(at: s) }
            }
            progress.done += 1
            progress.bytesDone += f.size
            report()
        }

        log.finished = Date()
        try? fm.createDirectory(at: IngestEngine.logDir, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: log.started).replacingOccurrences(of: ":", with: "-") + ".json"
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted; enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(log) { try? d.write(to: IngestEngine.logDir.appendingPathComponent(name)) }
        IngestEngine.saveIngested(ingested)

        if o.eject && progress.failures.isEmpty && !cancelled {
            for s in o.sources { try? NSWorkspace.shared.unmountAndEjectDevice(at: s) }
        }
        progress.nextSequence = seq
        progress.finished = true
        report()
    }

    static func uniqueDestination(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext); n += 1
        }
        return candidate
    }

    /// Stream-copy while hashing the bytes read, so the source is read exactly once.
    static func copyHashed(from: URL, to: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: to.path, contents: nil)
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: from.path), let d = attrs[.modificationDate] {
            try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: to.path)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

import AppKit

/// Watches for cards: any newly mounted volume with a DCIM folder.
final class CardWatcher {
    var onCard: ((URL) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            if CardWatcher.looksLikeCard(url) { self?.onCard?(url) }
        })
    }
    deinit { tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    static func looksLikeCard(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
    }
    static func mountedCards() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []).filter(looksLikeCard)
    }
}
