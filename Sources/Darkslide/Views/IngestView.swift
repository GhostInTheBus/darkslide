import SwiftUI

/// the legacy app's Ingest dialog: sources, two destinations with a folder template, rename on
/// ingest, sequence, caption template, verify, eject. Shows progress in place.
struct IngestView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [URL] = []
    @State private var selectedSources: Set<URL> = []
    @State private var progress: IngestEngine.Progress?
    @State private var engine: IngestEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ingest").font(.title3.bold())
            GroupBox("Source") {
                VStack(alignment: .leading) {
                    if sources.isEmpty { Text("No cards mounted (a card is any volume with a DCIM folder).").foregroundStyle(.secondary) }
                    ForEach(sources, id: \.self) { s in
                        Toggle(isOn: Binding(get: { selectedSources.contains(s) }, set: { on in if on { selectedSources.insert(s) } else { selectedSources.remove(s) } })) {
                            Text("\(s.lastPathComponent)  ").bold() + Text(s.path).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Rescan") { refreshSources() }
                        Button("Choose Folder…") { if let u = pickFolder() { sources.append(u); selectedSources.insert(u) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Destination") {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Primary")
                        pathField($library.settings.ingestPrimary)
                    }
                    GridRow {
                        Toggle("Backup", isOn: $library.settings.ingestSecondaryEnabled)
                        pathField($library.settings.ingestSecondary).disabled(!library.settings.ingestSecondaryEnabled)
                    }
                    GridRow {
                        Text("Folder")
                        HStack {
                            TextField("{datesort}_{jobname}", text: $library.settings.ingestFolderTemplate).font(.system(.body, design: .monospaced))
                            Text("→ " + previewFolder).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    GridRow {
                        Text("Job name")
                        TextField("", text: $library.settings.jobName)
                    }
                }
            }
            GroupBox("Rename and caption") {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Toggle("Rename", isOn: $library.settings.ingestRename)
                        HStack {
                            TextField("{datesort}-{seqn}", text: $library.settings.renameTemplate).font(.system(.body, design: .monospaced)).disabled(!library.settings.ingestRename)
                            Text("seq").foregroundStyle(.secondary)
                            TextField("", value: $library.settings.sequence, format: .number).frame(width: 70)
                        }
                    }
                    GridRow {
                        Text("Caption template")
                        Picker("", selection: $library.settings.ingestApplyTemplate) {
                            Text("None").tag("")
                            ForEach(library.settings.captionTemplates.keys.sorted(), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 220)
                    }
                }
            }
            HStack(spacing: 16) {
                Toggle("Copy everything, including video and unknown files", isOn: $library.settings.ingestCopyNonImages)
                Toggle("Skip mirror card", isOn: $library.settings.ingestSkipMirrorCard)
                Toggle("Eject when done", isOn: $library.settings.ingestEject)
                Toggle("Open when done", isOn: $library.settings.ingestOpenWhenDone)
            }.font(.callout)
            HStack { Toggle("Live ingest: keep pulling new files from the card while it is plugged in", isOn: $library.liveIngest); Spacer(); Text(library.liveIngestStatus).font(.caption).foregroundStyle(.secondary) }.font(.callout)

            if let p = progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    HStack {
                        Text(p.finished ? "Done: \(p.done) files, \(p.failures.count) failures, \(p.skipped) skipped" : "\(p.done)/\(p.total)  \(p.current)")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: p.bytesDone, countStyle: .file)).foregroundStyle(.secondary)
                    }.font(.caption)
                    ForEach(p.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
            HStack {
                Text("The card is never written to.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let p = progress, !p.finished {
                    Button("Cancel") { engine?.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Ingest") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedSources.isEmpty || library.settings.ingestPrimary.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 700)
        .onAppear { refreshSources() }
        .onDisappear { library.saveSettings() }
    }

    private var previewFolder: String {
        var ctx = library.variableContext()
        ctx.jobName = library.settings.jobName
        ctx.now = Date()
        return RenameEngine.sanitize(Variables.expand(library.settings.ingestFolderTemplate, ctx))
    }

    private func pathField(_ binding: Binding<String>) -> some View {
        HStack {
            TextField("Choose…", text: binding).truncationMode(.middle)
            Button("…") { if let u = pickFolder() { binding.wrappedValue = u.path } }
        }
    }

    private func pickFolder() -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    private func refreshSources() {
        sources = CardWatcher.mountedCards()
        selectedSources = Set(sources)
    }

    private func start() {
        library.saveSettings()
        let s = library.settings
        let e = IngestEngine()
        var opts = IngestEngine.Options(
            sources: sources.filter { selectedSources.contains($0) },
            primary: URL(fileURLWithPath: s.ingestPrimary),
            secondary: s.ingestSecondaryEnabled && !s.ingestSecondary.isEmpty ? URL(fileURLWithPath: s.ingestSecondary) : nil,
            folderTemplate: s.ingestFolderTemplate,
            renameTemplate: s.ingestRename ? s.renameTemplate : nil,
            jobName: s.jobName, startSequence: s.sequence, sequencePadding: s.sequencePadding,
            copyNonImages: s.ingestCopyNonImages, skipMirrorCard: s.ingestSkipMirrorCard,
            skipAlreadyIngested: true, eject: s.ingestEject, user: UserInfo.load())
        opts.sources = opts.sources.isEmpty ? sources : opts.sources
        engine = e
        e.onProgress = { p in
            progress = p
            if p.finished {
                library.settings.sequence = max(p.nextSequence, library.settings.sequence)
                library.saveSettings()
                if let d = p.destinationFolder {
                    if !s.ingestApplyTemplate.isEmpty, let t = s.captionTemplates[s.ingestApplyTemplate] {
                        let just = (p.copied + p.copiedSecondary).filter { PhotoItem.imageExtensions.contains($0.pathExtension.lowercased()) }   // the mirror gets the caption too
                        library.applyTemplate(t, to: just.map { PhotoItem(id: $0, url: $0, sidecarJPEG: nil, displayName: $0.lastPathComponent) })
                    }
                    if s.ingestOpenWhenDone { library.open(d) }
                }
            }
        }
        progress = IngestEngine.Progress()
        e.run(opts) { url in
            let info = ImageLoader.captureInfo(for: url)
            return (info, PhotoMeta())
        }
    }
}
