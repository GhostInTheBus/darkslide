import Foundation
import SQLite3

/// the legacy app's catalog tier-style catalog: an SQLite index of folders you choose, searchable across the
/// whole archive without opening each folder. Rows hold the path, capture date, rating,
/// class, tag and the caption fields. Thumbnails still come from the files.
final class Catalog {
    static let shared = Catalog()
    static let file = AppPaths.support.appendingPathComponent("catalog.sqlite")
    private var db: OpaquePointer?
    private let path: URL
    private let queue = DispatchQueue(label: "catalog")

    struct Row: Identifiable, Hashable {
        let path: String; let folder: String; let name: String
        let captureDate: String; let rating: Int; let colorClass: Int; let tagged: Bool
        let caption: String; let keywords: String; let city: String; let state: String; let country: String; let event: String; let byline: String
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    init(path: URL = Catalog.file) { self.path = path; open() }

    private func open() {
        // FULLMUTEX: the connection is used from the index queue and from the UI thread.
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        exec("""
        CREATE TABLE IF NOT EXISTS photos (
            path TEXT PRIMARY KEY, folder TEXT, name TEXT, capture TEXT, rating INTEGER, class INTEGER, tagged INTEGER,
            caption TEXT, keywords TEXT, city TEXT, state TEXT, country TEXT, event TEXT, byline TEXT, mtime REAL, indexed REAL);
        CREATE INDEX IF NOT EXISTS i_folder ON photos(folder);
        CREATE INDEX IF NOT EXISTS i_capture ON photos(capture);
        CREATE TABLE IF NOT EXISTS folders (path TEXT PRIMARY KEY, indexed REAL, count INTEGER);
        """)
    }

    @discardableResult private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err { print("catalog: \(String(cString: err))"); sqlite3_free(err) }
        return ok
    }

    func folders() -> [(path: String, count: Int, indexed: Date)] {
        var out: [(String, Int, Date)] = []
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, count, indexed FROM folders ORDER BY path", -1, &st, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(st, 0)), Int(sqlite3_column_int(st, 1)), Date(timeIntervalSince1970: sqlite3_column_double(st, 2))))
        }
        sqlite3_finalize(st)
        return out
    }

    /// Index a folder tree. Reads metadata through exiftool in chunks; skips files whose
    /// mtime has not changed since last time.
    func index(folder: URL, recursive: Bool, progress: @escaping (Int, Int) -> Void, completion: @escaping (Int) -> Void) {
        queue.async { [self] in
            var files: [URL] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            if recursive, let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let u as URL in en where PhotoItem.imageExtensions.contains(u.pathExtension.lowercased()) || PhotoItem.videoExtensions.contains(u.pathExtension.lowercased()) { files.append(u) }
            } else {
                files = FolderScanner.scan(folder).map(\.url)
            }
            let known = knownMtimes(folder: folder.path, recursive: recursive)
            let todo = files.filter { u in
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                return abs((known[u.path] ?? -1) - m) > 1
            }
            var done = 0
            DispatchQueue.main.async { progress(0, todo.count) }
            for chunk in stride(from: 0, to: todo.count, by: 64).map({ Array(todo[$0..<min($0 + 64, todo.count)]) }) {
                let r = ExifTool.shared.run(PhotoMeta.readArgs + chunk.map(\.path))
                if let data = r.output.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    exec("BEGIN")
                    for obj in arr {
                        guard let src = obj["SourceFile"] as? String else { continue }
                        let u = URL(fileURLWithPath: src)
                        let m = PhotoMeta(json: obj)
                        let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                        upsert(u, m, mtime: mtime)
                    }
                    exec("COMMIT")
                }
                done += chunk.count
                DispatchQueue.main.async { progress(done, todo.count) }
            }
            // Drop rows for files that no longer exist under this folder.
            let present = Set(files.map(\.path))
            for (p, _) in known where !present.contains(p) { run("DELETE FROM photos WHERE path = ?", [p]) }
            run("INSERT OR REPLACE INTO folders(path, indexed, count) VALUES(?, ?, ?)", [folder.path, Date().timeIntervalSince1970, files.count])
            DispatchQueue.main.async { completion(files.count) }
        }
    }

    /// LIKE pattern for "inside this folder": the path plus a slash, with LIKE wildcards escaped.
    static func likePrefix(_ folder: String) -> String {
        let esc = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return esc + "/%"
    }

    private func knownMtimes(folder: String, recursive: Bool) -> [String: Double] {
        var out: [String: Double] = [:]
        var st: OpaquePointer?
        let sql = recursive ? "SELECT path, mtime FROM photos WHERE path LIKE ? ESCAPE '\\'" : "SELECT path, mtime FROM photos WHERE folder = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_text(st, 1, recursive ? Catalog.likePrefix(folder) : folder, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(st) == SQLITE_ROW { out[String(cString: sqlite3_column_text(st, 0))] = sqlite3_column_double(st, 1) }
        sqlite3_finalize(st)
        return out
    }

    private func upsert(_ u: URL, _ m: PhotoMeta, mtime: Double) {
        run("""
        INSERT OR REPLACE INTO photos(path, folder, name, capture, rating, class, tagged, caption, keywords, city, state, country, event, byline, mtime, indexed)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [u.path, u.deletingLastPathComponent().path, u.lastPathComponent, m.captureDate, m.rating, m.colorClass, m.tagged ? 1 : 0,
              m.caption, m.keywords.joined(separator: ", "), m.city, m.state, m.country, m.event, m.byline, mtime, Date().timeIntervalSince1970])
    }

    private func run(_ sql: String, _ params: [Any]) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let s as String: sqlite3_bind_text(st, idx, s, -1, transient)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(st, idx, d)
            default: sqlite3_bind_null(st, idx)
            }
        }
        sqlite3_step(st); sqlite3_finalize(st)
    }

    /// Search: free text across name and caption fields, optional rating/class/date filters.
    func search(text: String, minRating: Int, colorClass: Int?, taggedOnly: Bool, from: Date?, to: Date?, limit: Int = 2000) -> [Row] {
        var sql = "SELECT path, folder, name, capture, rating, class, tagged, caption, keywords, city, state, country, event, byline FROM photos WHERE 1=1"
        var params: [Any] = []
        for word in text.split(separator: " ").map(String.init) where !word.isEmpty {
            sql += " AND (name LIKE ? OR caption LIKE ? OR keywords LIKE ? OR city LIKE ? OR state LIKE ? OR country LIKE ? OR event LIKE ? OR byline LIKE ? OR folder LIKE ?)"
            params += Array(repeating: "%\(word)%", count: 9)
        }
        if minRating > 0 { sql += " AND rating >= ?"; params.append(minRating) }
        if let c = colorClass { sql += " AND class = ?"; params.append(c) }
        if taggedOnly { sql += " AND tagged = 1" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let from { sql += " AND capture >= ?"; params.append(f.string(from: from)) }
        if let to { sql += " AND capture <= ?"; params.append(f.string(from: to)) }
        sql += " ORDER BY capture DESC, name LIMIT \(limit)"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            if let s = p as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, transient) } else if let n = p as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
        }
        var out: [Row] = []
        func col(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Row(path: col(0), folder: col(1), name: col(2), captureDate: col(3), rating: Int(sqlite3_column_int(st, 4)), colorClass: Int(sqlite3_column_int(st, 5)),
                           tagged: sqlite3_column_int(st, 6) == 1, caption: col(7), keywords: col(8), city: col(9), state: col(10), country: col(11), event: col(12), byline: col(13)))
        }
        sqlite3_finalize(st)
        return out
    }

    func removeFolder(_ path: String) {
        run("DELETE FROM photos WHERE path LIKE ? ESCAPE '\\'", [Catalog.likePrefix(path)])
        run("DELETE FROM photos WHERE folder = ?", [path])
        run("DELETE FROM folders WHERE path = ?", [path])
    }

    func count() -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photos", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }
}
