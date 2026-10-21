import SwiftUI

/// the legacy app's Rename Photos dialog: free-text template with variables, live preview, named
/// templates, sequence control, collision warnings, undo.
struct RenameView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var template = ""
    @State private var sequence = 1
    @State private var padding = 4
    @State private var saveName = ""
    @State private var showVariables = false
    @State private var warming = true

    private var items: [PhotoItem] { library.targets }

    private var plan: RenamePlan {
        var ctx = library.variableContext()
        ctx.sequence = sequence; ctx.sequencePadding = padding
        return RenameEngine.plan(items: items, template: template, context: ctx,
                                 metaFor: { library.meta[$0.url] }, infoFor: { library.info(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(items.count) photo\(items.count == 1 ? "" : "s")").font(.title3.bold())
            HStack {
                TextField("Template, e.g. {datesort}-{seqn}", text: $template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Menu("Saved") {
                    ForEach(library.settings.savedRenameTemplates.keys.sorted(), id: \.self) { name in
                        Button(name) { template = library.settings.savedRenameTemplates[name] ?? template }
                    }
                    if !library.settings.savedRenameTemplates.isEmpty { Divider() }
                    Button("Save Current As…") { saveName = "" ; showSave = true }
                }.frame(width: 90)
                Button("Variables") { showVariables.toggle() }
                    .popover(isPresented: $showVariables) { VariablesPalette(insert: { template += $0 }) }
            }
            HStack(spacing: 12) {
                Text("Sequence")
                TextField("", value: $sequence, format: .number).frame(width: 70)
                Stepper("", value: $sequence, in: 0...999999).labelsHidden()
                Text("Padding")
                Picker("", selection: $padding) { ForEach(1...8, id: \.self) { Text("\($0)").tag($0) } }.frame(width: 60).labelsHidden()
                Spacer()
                if let last = library.lastRename, !last.moved.isEmpty {
                    Button("Undo last rename (\(last.moved.count) files)") { library.undoRename() }
                }
            }.font(.callout)

            let p = warming ? RenamePlan(entries: []) : plan
            Table(p.entries) {
                TableColumn("From") { Text($0.from.lastPathComponent) }
                TableColumn("To") { e in
                    Text(e.to.lastPathComponent).foregroundStyle(e.collision ? .red : .primary)
                }
                TableColumn("") { e in e.collision ? Text(e.from == e.to ? "empty name" : "collision").foregroundStyle(.red) : Text("") }.width(80)
            }
            .frame(minHeight: 220)
            .overlay { if warming { ProgressView("Reading capture info for \(items.count) files…").controlSize(.small) } }

            HStack {
                if p.collisions > 0 { Text("\(p.collisions) name collision\(p.collisions == 1 ? "" : "s") will be skipped").foregroundStyle(.red) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    library.settings.renameTemplate = template
                    library.settings.sequence = sequence
                    library.settings.sequencePadding = padding
                    library.applyRename(p, advanceSequenceBy: items.count)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.isEmpty || items.isEmpty || warming)
            }
        }
        .padding(16)
        .frame(width: 720, height: 460)
        .onAppear {
            template = library.settings.renameTemplate
            sequence = library.settings.sequence
            padding = library.settings.sequencePadding
        }
        .task { await library.warmInfo(for: items); warming = false }
        .sheet(isPresented: $showSave) {
            VStack(spacing: 12) {
                Text("Save template as").font(.headline)
                TextField("Name", text: $saveName).frame(width: 240)
                HStack { Button("Cancel") { showSave = false }; Button("Save") {
                    if !saveName.isEmpty { library.settings.savedRenameTemplates[saveName] = template; library.saveSettings() }
                    showSave = false
                }.keyboardShortcut(.defaultAction) }
            }.padding(20)
        }
    }
    @State private var showSave = false
}

/// The Variables palette: click to insert. Grouped the way the legacy app groups them.
struct VariablesPalette: View {
    var insert: (String) -> Void
    private let groups: [(String, [String])] = [
        ("Date / time", ["datesort", "datesortdash", "date", "year4", "year2", "month0", "monthname", "day0", "hour24", "minute", "second", "time", "timesort", "todaysort"]),
        ("File", ["filename", "filenamebase", "extension", "folder", "frame", "frame4", "filesize"]),
        ("Sequence", ["seqn", "seqn:3", "ingestseq"]),
        ("Camera", ["make", "model", "serial", "lens", "iso", "f", "shutter", "focallength", "width", "height"]),
        ("IPTC", ["caption", "headline", "byline", "credit", "copyright", "city", "state", "country", "location", "event", "keywords"]),
        ("Job / rating", ["jobname", "rating", "colorclass", "tag", "username", "usercompany", "useremail"]),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groups, id: \.0) { g in
                    Text(g.0).font(.caption.bold()).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(g.1, id: \.self) { v in
                            Button("{\(v)}") { insert("{\(v)}") }.buttonStyle(.bordered).controlSize(.small).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }.padding(12)
        }.frame(width: 420, height: 380)
    }
}

/// Minimal wrapping layout for the variable chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
