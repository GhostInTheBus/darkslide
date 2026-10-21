import SwiftUI

struct ExportView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var presetID: UUID?
    @State private var folder = ""
    @State private var done = 0
    @State private var total = 0
    @State private var running = false
    @State private var editing = false

    private var preset: ExportPreset? { library.settings.exportPresets.first { $0.id == presetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            HStack {
                Picker("Preset", selection: $presetID) {
                    ForEach(library.settings.exportPresets) { p in Text(p.name).tag(Optional(p.id)) }
                }
                Button(editing ? "Done" : "Edit Presets") { editing.toggle() }
            }
            if editing {
                PresetEditor().environmentObject(library)
            } else if let p = preset {
                Text("\(p.longEdge == 0 ? "Original size" : "\(p.longEdge) px long edge"), JPEG \(p.quality)%\(p.stripGPS ? ", GPS stripped" : "")\(p.stripAllMetadata ? ", no metadata" : "")\(p.copyrightStamp ? ", copyright stamped" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("To")
                TextField("Folder", text: $folder).truncationMode(.middle)
                Button("…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { folder = u.path }
                }
            }
            if running || total > 0 {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done)/\(total)").font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { run() }.keyboardShortcut(.defaultAction).disabled(running || folder.isEmpty || preset == nil)
            }
        }
        .padding(16).frame(width: 560)
        .onAppear {
            presetID = library.settings.exportPresets.first?.id
            folder = library.settings.lastExportFolder
        }
    }

    private func run() {
        guard let p = preset else { return }
        running = true; total = library.targets.count; done = 0
        library.settings.lastExportFolder = folder; library.saveSettings()
        let user = UserInfo.load()
        let wm: ((PhotoItem) -> String)? = p.watermarkText.isEmpty ? nil : { item in var ctx = library.variableContext(); ctx.item = item; ctx.meta = library.meta[item.url]; ctx.info = library.info(for: item); return Variables.expand(p.watermarkText, ctx) }
        ExportEngine.export(items: library.targets, preset: p, to: URL(fileURLWithPath: folder), meta: library.meta,
                            copyright: user.name.isEmpty ? "" : "© \(Calendar.current.component(.year, from: Date())) \(user.name)", creator: user.name, watermark: wm,
                            progress: { d, t in done = d; total = t }) { r in
            running = false
            if !r.failures.isEmpty { library.lastError = "Export: " + r.failures.joined(separator: "; ") }
            NSWorkspace.shared.activateFileViewerSelecting(r.written.prefix(1).map { $0 })
            dismiss()
        }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var library: Library
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($library.settings.exportPresets) { $p in
                HStack(spacing: 8) {
                    TextField("Name", text: $p.name).frame(width: 110)
                    TextField("px", value: $p.longEdge, format: .number).frame(width: 60).help("Long edge in px, 0 = original")
                    TextField("q", value: $p.quality, format: .number).frame(width: 44).help("JPEG quality")
                    TextField("suffix", text: $p.suffix).frame(width: 70)
                    Toggle("No GPS", isOn: $p.stripGPS)
                    Toggle("No metadata", isOn: $p.stripAllMetadata)
                    Toggle("©", isOn: $p.copyrightStamp).help("Stamp copyright and creator")
                    Toggle("sRGB", isOn: $p.convertToSRGB)
                    TextField("watermark text", text: $p.watermarkText).frame(width: 120).help("Text watermark; variables like {copyright} or {username} work")
                    Picker("", selection: $p.watermarkCorner) { Text("TL").tag(0); Text("TR").tag(1); Text("BL").tag(2); Text("BR").tag(3); Text("Centre").tag(4) }.labelsHidden().frame(width: 70)
                    Button { library.settings.exportPresets.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }.font(.caption)
            }
            Button("Add Preset") { library.settings.exportPresets.append(ExportPreset(name: "New", longEdge: 2048, quality: 90)) }.font(.caption)
        }
        .onDisappear { library.saveSettings() }
    }
}

struct CopyMoveView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var move = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(move ? "Move" : "Copy") \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            Picker("", selection: $move) { Text("Copy").tag(false); Text("Move").tag(true) }.pickerStyle(.segmented).frame(width: 160)
            HStack {
                TextField("Destination folder", text: $folder).truncationMode(.middle)
                Button("…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { folder = u.path }
                }
            }
            Text("RAW+JPEG pairs and sidecars travel together. Existing files are never overwritten.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(move ? "Move" : "Copy") {
                    let r = ExportEngine.copyOrMove(items: library.targets, to: URL(fileURLWithPath: folder), move: move)
                    if !r.failures.isEmpty { library.lastError = r.failures.joined(separator: "; ") }
                    if move { library.rescan() }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(folder.isEmpty)
            }
        }.padding(16).frame(width: 520)
    }
}
