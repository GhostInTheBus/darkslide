import Foundation

/// the legacy app's Structured Keywords: a controlled vocabulary in a plain text file. Indent with
/// tabs for hierarchy; `term = synonym, synonym` declares synonyms. Also keeps the
/// per-field autocomplete lists the legacy app calls "Edit IPTC list".
final class KeywordNode: Identifiable {
    let id = UUID()
    let term: String
    let synonyms: [String]
    var children: [KeywordNode] = []
    weak var parent: KeywordNode?
    init(term: String, synonyms: [String]) { self.term = term; self.synonyms = synonyms }
    var path: [String] { (parent?.path ?? []) + [term] }
    func matches(_ q: String) -> Bool {
        let s = q.lowercased()
        return term.lowercased().contains(s) || synonyms.contains { $0.lowercased().contains(s) }
    }
    func flattened() -> [KeywordNode] { [self] + children.flatMap { $0.flattened() } }
}

enum Keywords {
    static let file = AppPaths.support.appendingPathComponent("keywords.txt")

    static func load(from file: URL = Keywords.file) -> [KeywordNode] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            try? """
            # Structured keywords. Indent with tabs for hierarchy. "term = synonym, synonym" adds synonyms.
            Places
            \tCalifornia = CA
            \t\tSan Francisco
            \t\tLos Angeles = LA
            \tPennsylvania = PA
            \t\tPhiladelphia = Philly
            People
            \tFamily
            \tFriends
            Events
            \tParade
            \tFire
            \tProtest
            """.write(to: file, atomically: true, encoding: .utf8)
            return load(from: file)
        }
        var roots: [KeywordNode] = []
        var stack: [(Int, KeywordNode)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let depth = line.prefix { $0 == "\t" }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let node = KeywordNode(term: parts[0], synonyms: parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : [])
            while let last = stack.last, last.0 >= depth { stack.removeLast() }
            if let p = stack.last?.1 { node.parent = p; p.children.append(node) } else { roots.append(node) }
            stack.append((depth, node))
        }
        return roots
    }

    // MARK: Autocomplete history

    static let historyFile = AppPaths.support.appendingPathComponent("autocomplete.json")
    static var history: [String: [String]] = {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: historyFile))) ?? [:]
    }()

    /// Remember values written to a field; most recent first, 40 per field.
    static func remember(_ fields: [String: String]) {
        for (k, v) in fields {
            let vals = k == "keywords" ? v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : [v.trimmingCharacters(in: .whitespaces)]
            for val in vals where !val.isEmpty {
                var list = history[k] ?? []
                list.removeAll { $0.caseInsensitiveCompare(val) == .orderedSame }
                list.insert(val, at: 0)
                history[k] = Array(list.prefix(40))
            }
        }
        if let d = try? JSONEncoder().encode(history) { try? d.write(to: historyFile) }
    }
}
