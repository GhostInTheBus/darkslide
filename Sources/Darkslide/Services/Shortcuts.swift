import AppKit

/// Remappable keyboard shortcuts, stored as plain JSON in Application Support. Keys are
/// written like "1", "cmd+1", "shift+t", "space", "left", "esc". Several keys for one
/// action are separated by commas: "space,cmd+r". Defaults follow the legacy app's menus.
enum ShortcutAction: String, CaseIterable, Codable {
    case rate0, rate1, rate2, rate3, rate4, rate5
    case class0, class1, class2, class3, class4, class5, class6, class7, class8
    case toggleTag, preview, closePreview, next, previous, first, last, zoom
    case openInEditor, rename, caption, rotateCW, rotateCCW
}

struct Shortcuts {
    static var current = Shortcuts.load()

    var map: [ShortcutAction: String] = [
        .rate0: "0", .rate1: "1", .rate2: "2", .rate3: "3", .rate4: "4", .rate5: "5",
        .class0: "cmd+0", .class1: "cmd+1", .class2: "cmd+2", .class3: "cmd+3", .class4: "cmd+4",
        .class5: "cmd+5", .class6: "cmd+6", .class7: "cmd+7", .class8: "cmd+8",
        .toggleTag: "t", .preview: "space,cmd+r", .closePreview: "esc", .next: "right", .previous: "left",
        .first: "home", .last: "end", .zoom: "z", .openInEditor: "cmd+e", .rename: "cmd+m", .caption: "cmd+i",
        .rotateCW: "cmd+]", .rotateCCW: "cmd+[",
    ]

    static let file: URL = AppPaths.support.appendingPathComponent("shortcuts.json")

    static func load() -> Shortcuts {
        var s = Shortcuts()
        if let d = try? Data(contentsOf: file),
           let dict = try? JSONDecoder().decode([String: String].self, from: d) {
            for (k, v) in dict { if let a = ShortcutAction(rawValue: k) { s.map[a] = v } }
            // Files written by 1.0–1.4 pinned the old defaults; move them to the legacy app's keys.
            if dict["rename"] == "cmd+r", dict["preview"] == "space" {
                s.map[.rename] = "cmd+m"; s.map[.preview] = "space,cmd+r"; s.save()
            }
        } else {
            s.save()
        }
        return s
    }

    func save() {
        let dict = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        if let d = try? JSONEncoder().encode(dict) { try? d.write(to: Shortcuts.file) }
    }

    /// Which action, if any, this key event triggers.
    func action(for event: NSEvent) -> ShortcutAction? {
        let key = Shortcuts.describe(event)
        return map.first { $0.value.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == key } }?.key
    }

    static func describe(_ e: NSEvent) -> String {
        var parts: [String] = []
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { parts.append("cmd") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.shift) { parts.append("shift") }
        let special: [UInt16: String] = [49: "space", 36: "return", 76: "enter", 53: "esc", 51: "delete", 117: "fwddelete",
                                         123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end",
                                         116: "pageup", 121: "pagedown", 48: "tab"]
        if let s = special[e.keyCode] { parts.append(s) }
        else if let c = e.charactersIgnoringModifiers?.lowercased(), !c.isEmpty { parts.append(c) }
        return parts.joined(separator: "+")
    }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Darkslide", isDirectory: true)
        // One-time move from the pre-release name, so settings, templates, catalog and logs carry over.
        let old = base.appendingPathComponent("PictureMechanicLite", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: u)
        }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}
