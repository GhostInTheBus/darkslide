import SwiftUI

/// Catalog window: add folders to the index, search across all of them, open results
/// as a virtual contact sheet.
struct CatalogView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var folders = Catalog.shared.folders()
    @State private var text = ""
    @State private var minRating = 0
    @State private var colorClass: Int? = nil
    @State private var taggedOnly = false
    @State private var rows: [Catalog.Row] = []
    @State private var indexing = ""
    @State private var selection = Set<String>()
    @State private var total = Catalog.shared.count()
    @State private var showSave = false
    @State private var showDelete = false
    @State private var saveName = ""

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Indexed folders (\(total) photos)").font(.caption.bold())
                List(folders, id: \.path) { f in
                    VStack(alignment: .leading) {
                        Text(URL(fileURLWithPath: f.path).lastPathComponent).lineLimit(1)
                        Text("\(f.count) files · \(f.indexed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Re-index") { index(URL(fileURLWithPath: f.path)) }
                        Button("Update Folder Location…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = "Where did \(URL(fileURLWithPath: f.path).lastPathComponent) move to?"
                            if p.runModal() == .OK, let u = p.url { Catalog.shared.removeFolder(f.path); index(u) }
                        }
                        Button("Remove from catalog") { Catalog.shared.removeFolder(f.path); refresh() }
                    }
                }
                HStack {
                    Button("Add Folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                        if p.runModal() == .OK { for u in p.urls { index(u) } }
                    }
                    Button("Re-index All") { for f in folders { index(URL(fileURLWithPath: f.path)) } }.disabled(folders.isEmpty)
                }
                if !indexing.isEmpty { Text(indexing).font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 260)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Search names, captions, keywords, places…", text: $text).textFieldStyle(.roundedBorder).onSubmit(search)
                    Picker("", selection: $minRating) { Text("any ★").tag(0); ForEach(1...5, id: \.self) { Text("≥ \($0)★").tag($0) } }.labelsHidden().frame(width: 80)
                    Picker("", selection: $colorClass) { Text("any class").tag(Optional<Int>.none); ForEach(1...8, id: \.self) { Text(library.colorClasses.name($0)).tag(Optional($0)) } }.labelsHidden().frame(width: 110)
                    Toggle("Tagged", isOn: $taggedOnly)
                    Button("Search") { search() }.keyboardShortcut(.defaultAction)
                    Menu("Saved") {
                        ForEach(library.settings.savedSearches.keys.sorted(), id: \.self) { n in Button(n) { text = library.settings.savedSearches[n] ?? ""; search() } }
                        if !library.settings.savedSearches.isEmpty { Divider() }
                        Button("Save Current Search…") { saveName = text; showSave = true }.disabled(text.isEmpty)
                        if !library.settings.savedSearches.isEmpty { Button("Delete…") { showDelete = true } }
                    }.frame(width: 80)
                }
                Table(rows, selection: $selection) {
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Captured") { Text($0.captureDate) }.width(130)
                    TableColumn("★") { Text($0.rating > 0 ? String(repeating: "★", count: $0.rating) : "") }.width(50)
                    TableColumn("Place") { Text([$0.city, $0.state].filter { !$0.isEmpty }.joined(separator: ", ")) }.width(130)
                    TableColumn("Caption") { Text($0.caption).lineLimit(1) }
                    TableColumn("Folder") { Text(URL(fileURLWithPath: $0.folder).lastPathComponent) }.width(120)
                }
                HStack {
                    Text("\(rows.count) result\(rows.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(rows.filter { selection.contains($0.id) }.map(\.url)) }.disabled(selection.isEmpty)
                    Button("Open Folder") { if let r = rows.first(where: { selection.contains($0.id) }) { library.open(URL(fileURLWithPath: r.folder)); library.selection = [r.url]; dismiss() } }.disabled(selection.isEmpty)
                    Button("Open Results as Contact Sheet") { library.openVirtual(rows.map(\.url), title: "Search: \(text)"); dismiss() }.disabled(rows.isEmpty)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(16).frame(width: 980, height: 560)
        .sheet(isPresented: $showSave) {
            VStack(spacing: 12) { Text("Save search as").font(.headline); TextField("Name", text: $saveName).frame(width: 240)
                HStack { Button("Cancel") { showSave = false }; Button("Save") { if !saveName.isEmpty { library.settings.savedSearches[saveName] = text; library.saveSettings() }; showSave = false }.keyboardShortcut(.defaultAction) } }.padding(20)
        }
        .sheet(isPresented: $showDelete) {
            VStack(spacing: 12) { Text("Delete saved search").font(.headline)
                ForEach(library.settings.savedSearches.keys.sorted(), id: \.self) { n in Button("Delete \"\(n)\"") { library.settings.savedSearches[n] = nil; library.saveSettings() } }
                Button("Done") { showDelete = false }.keyboardShortcut(.cancelAction) }.padding(20)
        }
    }

    private func refresh() { folders = Catalog.shared.folders(); total = Catalog.shared.count() }
    private func search() {
        rows = Catalog.shared.search(text: text, minRating: minRating, colorClass: colorClass, taggedOnly: taggedOnly, from: nil, to: nil)
    }
    private func index(_ u: URL) {
        indexing = "Indexing \(u.lastPathComponent)…"
        Catalog.shared.index(folder: u, recursive: true, progress: { d, t in indexing = "Indexing \(u.lastPathComponent): \(d)/\(t)" }) { n in
            indexing = "Indexed \(u.lastPathComponent): \(n) files"; refresh()
        }
    }
}
