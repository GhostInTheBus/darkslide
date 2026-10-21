import Foundation

/// the legacy app's Code Replacements: a tab-separated text file of `code<TAB>expansion`; in caption
/// fields `\code\` becomes the expansion. The file is plain text so it can be shared.
enum CodeReplacements {
    static let file = AppPaths.support.appendingPathComponent("code-replacements.txt")

    static func load() -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            try? "# code<TAB>replacement, one per line. Use \\code\\ in any caption field.\n".write(to: file, atomically: true, encoding: .utf8)
            return [:]
        }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { map[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        return map
    }

    static func expand(_ text: String, delimiter: String, map: [String: String]) -> String {
        guard !map.isEmpty, !delimiter.isEmpty, text.contains(delimiter) else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: delimiter) {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: delimiter) else { out += rest[open.lowerBound...]; return out }
            let code = String(afterOpen[..<close.lowerBound])
            out += map[code] ?? (delimiter + code + delimiter)
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }
}
