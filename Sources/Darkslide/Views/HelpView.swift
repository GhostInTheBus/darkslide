import SwiftUI

/// Help > Keyboard Shortcuts: everything the keys do, read from the live map.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let fixed: [(String, String)] = [
        ("Double-click a thumbnail", "Open the preview"),
        ("Double-click the preview, Esc, Space", "Back to the contact sheet"),
        ("Click in the preview", "100% zoom at that point; drag to pan"),
        ("⌘O", "Open folder"), ("⌘G", "Ingest"), ("⌘R", "Rename"), ("⌘I", "IPTC Info"), ("⌘K", "Structured keywords"),
        ("⌘E", "Open in editor"), ("⌘⇧S", "Export"), ("⌘⇧C", "Copy / Move"), ("⌘P", "Print contact sheet"),
        ("⌘F", "Find"), ("⌘⇧F", "Catalog"), ("⌘A / ⌘D", "Select all / none"), ("⌘⌫", "Move to Trash"),
        ("⌘+ / ⌘-", "Thumbnail size"), ("⌃⌘F", "Full screen"), ("⌥⌘S", "Slideshow"), ("⌘⇧R", "Rescan folder"), ("⌘,", "Preferences"),
    ]
    private let names: [ShortcutAction: String] = [
        .rate0: "Clear rating", .rate1: "1 star", .rate2: "2 stars", .rate3: "3 stars", .rate4: "4 stars", .rate5: "5 stars",
        .class0: "Clear color class", .class1: "Color class 1", .class2: "Color class 2", .class3: "Color class 3", .class4: "Color class 4",
        .class5: "Color class 5", .class6: "Color class 6", .class7: "Color class 7", .class8: "Color class 8",
        .toggleTag: "Toggle tag", .preview: "Preview / back", .closePreview: "Close preview", .next: "Next", .previous: "Previous",
        .first: "First", .last: "Last", .zoom: "100% zoom", .openInEditor: "Open in editor", .rename: "Rename", .caption: "IPTC Info",
        .rotateCW: "Rotate clockwise", .rotateCCW: "Rotate counterclockwise",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Culling and preview (remappable)").font(.caption.bold())
                    ForEach(ShortcutAction.allCases, id: \.self) { a in
                        HStack { Text(pretty(Shortcuts.current.map[a] ?? "")).font(.system(.caption, design: .monospaced)).frame(width: 70, alignment: .leading); Text(names[a] ?? a.rawValue).font(.caption) }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything else").font(.caption.bold())
                    ForEach(fixed, id: \.0) { k, v in
                        HStack(alignment: .top) { Text(k).font(.system(.caption, design: .monospaced)).frame(width: 190, alignment: .leading); Text(v).font(.caption) }
                    }
                }
            }
            HStack { Button("Edit shortcuts.json") { NSWorkspace.shared.open(Shortcuts.file) }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(16).frame(width: 640)
    }
    private func pretty(_ k: String) -> String {
        k.replacingOccurrences(of: "cmd+", with: "⌘").replacingOccurrences(of: "shift+", with: "⇧").replacingOccurrences(of: "opt+", with: "⌥").replacingOccurrences(of: "ctrl+", with: "⌃")
            .replacingOccurrences(of: "space", with: "Space").replacingOccurrences(of: "esc", with: "Esc").replacingOccurrences(of: "left", with: "←").replacingOccurrences(of: "right", with: "→")
            .replacingOccurrences(of: "home", with: "Home").replacingOccurrences(of: "end", with: "End").uppercased()
    }
}
