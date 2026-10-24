import SwiftUI

/// the legacy app's IPTC Info / Stationery Pad: the full field set, per-field apply checkboxes,
/// named templates, snapshot from the current photo, variables in every field.
struct CaptionView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var template = IPTCTemplate()
    @State private var templateName = ""
    @State private var settled = false
    @State private var showSave = false
    @State private var showVariables = false
    @State private var aiBusy = false
    @State private var aiError = ""

    private var items: [PhotoItem] { library.targets }
    private var shownKeys: [String] { IPTCTemplate.fieldKeys.filter { !library.settings.hiddenCaptionFields.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(items.count == 1 ? "IPTC Info: \(items[0].displayName)" : "IPTC Stationery Pad: \(items.count) photos").font(.title3.bold())
                Spacer()
                Menu("Templates") {
                    ForEach(library.settings.captionTemplates.keys.sorted(), id: \.self) { name in
                        Button(name) { template = library.settings.captionTemplates[name] ?? template; library.settings.lastCaptionTemplate = name }
                    }
                    if !library.settings.captionTemplates.isEmpty { Divider() }
                    Button("Save Current As…") { templateName = library.settings.lastCaptionTemplate; showSave = true }
                    if !library.settings.lastCaptionTemplate.isEmpty {
                        Button("Delete \"\(library.settings.lastCaptionTemplate)\"") {
                            library.settings.captionTemplates[library.settings.lastCaptionTemplate] = nil
                            library.settings.lastCaptionTemplate = ""; library.saveSettings()
                        }
                    }
                }.frame(width: 110)
                Button("Snapshot from Photo") { if let c = library.current, let m = library.meta[c.url] { template = IPTCTemplate.from(meta: m) } }
                Button("Variables") { showVariables.toggle() }
                    .popover(isPresented: $showVariables) { VariablesPalette(insert: { _ in }) }
                Button("Keywords…") { library.showKeywords = true }
                Button(aiBusy ? "Thinking…" : "Suggest (\(library.settings.aiProvider == .ollama ? "local AI" : library.settings.aiProvider.label))") { suggest() }.disabled(aiBusy || library.current == nil)
                    .help(library.settings.aiProvider == .ollama ? "Caption and keyword suggestions from \(library.settings.ollamaModel) on this Mac. Nothing leaves the machine and nothing is written until you save." : "Sends a 1024 px preview of this photo to \(library.settings.aiProvider.label) with your API key. Nothing is written until you save.")
            }
            if !aiError.isEmpty { Text(aiError).font(.caption).foregroundStyle(.red) }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(shownKeys, id: \.self) { key in
                    GridRow {
                        Toggle("", isOn: Binding(get: { template.apply.contains(key) }, set: { on in if on { template.apply.insert(key) } else { template.apply.remove(key) } })).labelsHidden()
                        Text(IPTCTemplate.fieldLabels[key] ?? key).frame(width: 120, alignment: .trailing)
                        if key == "caption" || key == "instructions" || key == "keywords" {
                            TextEditor(text: binding(key)).frame(height: key == "caption" ? 70 : 40).font(.body)
                                .onChange(of: template.fields[key] ?? "") { _, _ in if settled { template.apply.insert(key) } }
                        } else {
                            HStack(spacing: 2) {
                                TextField("", text: binding(key))
                                    .onChange(of: template.fields[key] ?? "") { _, _ in if settled { template.apply.insert(key) } }
                                if let recent = Keywords.history[key], !recent.isEmpty {
                                    Menu { ForEach(recent, id: \.self) { v in Button(v) { template.fields[key] = v; template.apply.insert(key) } } }
                                        label: { Image(systemName: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).frame(width: 22).help("Recent values")
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Toggle("Append keywords", isOn: $template.keywordsAppend)
                Toggle("Append caption", isOn: $template.captionAppend)
                Spacer()
                Menu("Location Presets") {
                    ForEach(library.settings.locationPresets) { p in
                        Button(p.name) {
                            template.fields["city"] = p.city; template.fields["state"] = p.state; template.fields["country"] = p.country; template.fields["location"] = p.location
                            template.apply.formUnion(["city", "state", "country", "location"])
                        }
                    }
                    Divider()
                    Button("Save Current Location As…") {
                        let name = [template.fields["city"], template.fields["state"], template.fields["country"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                        guard !name.isEmpty else { return }
                        library.settings.locationPresets.append(LocationPreset(name: name, city: template.fields["city"] ?? "", state: template.fields["state"] ?? "", country: template.fields["country"] ?? "", location: template.fields["location"] ?? ""))
                        library.saveSettings()
                    }
                }.frame(width: 150)
            }.font(.callout)
            HStack {
                Text("Checked fields are written; variables like {datesort} expand per photo.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(items.count == 1 ? "Save" : "Apply to \(items.count)") {
                    library.applyTemplate(template, to: items)
                    library.saveSettings()
                    dismiss()
                }.keyboardShortcut("s", modifiers: .command).disabled(items.isEmpty || template.apply.isEmpty)
                    .help("Save (⌘S). Return adds a line inside a caption.")
            }
        }
        .padding(16)
        .frame(width: 720)
        .onAppear {
            if items.count == 1 {
                // Metadata may not be loaded yet right after opening a big folder; an empty record is
                // still this photo's record, never the stationery pad.
                template = IPTCTemplate.from(meta: library.meta[items[0].url] ?? PhotoMeta())
                template.apply = []     // editing one photo: only changed fields get written
                template.keywordsAppend = false
            } else if let name = Optional(library.settings.lastCaptionTemplate), let t = library.settings.captionTemplates[name] {
                template = t
            }
            // The field onChange handlers fire once for the initial fill; only edits after that count.
            DispatchQueue.main.async { settled = true }
        }
        .sheet(isPresented: $showSave) {
            VStack(spacing: 12) {
                Text("Save template as").font(.headline)
                TextField("Name", text: $templateName).frame(width: 260)
                HStack {
                    Button("Cancel") { showSave = false }
                    Button("Save") {
                        if !templateName.isEmpty {
                            library.settings.captionTemplates[templateName] = template
                            library.settings.lastCaptionTemplate = templateName
                            library.saveSettings()
                        }
                        showSave = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
    }

    private func suggest() {
        guard let cur = library.current else { return }
        aiBusy = true; aiError = ""
        let m = library.meta[cur.url] ?? PhotoMeta()
        let context = [m.event, m.city, m.state, m.country, m.caption].filter { !$0.isEmpty }.joined(separator: "; ")
        let p = library.settings.aiProvider
        CaptionAI.suggest(provider: p, model: library.settings.aiModel(for: p), ollamaURL: library.settings.ollamaURL, image: cur.url, context: context) { r in
            aiBusy = false
            switch r {
            case .success(let s):
                let existing = (template.fields["caption"] ?? "").trimmingCharacters(in: .whitespaces)
                template.fields["caption"] = existing.isEmpty ? s.caption : existing + " -- " + s.caption
                let kws = (template.fields["keywords"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                template.fields["keywords"] = (kws + s.keywords.filter { !kws.contains($0) }).joined(separator: ", ")
                template.apply.formUnion(["caption", "keywords"])
            case .failure(let e): aiError = "\(library.settings.aiProvider.label): \(e.localizedDescription)"
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { template.fields[key] ?? "" }, set: { template.fields[key] = $0 })
    }
}

/// the legacy app's Adjust Capture Dates and Times.
struct AdjustTimeView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var days = 0
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var subtract = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust capture time of \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            Picker("", selection: $subtract) { Text("Add").tag(false); Text("Subtract").tag(true) }.pickerStyle(.segmented).frame(width: 200)
            HStack {
                ForEach([("Days", $days), ("Hours", $hours), ("Minutes", $minutes), ("Seconds", $seconds)], id: \.0) { label, b in
                    VStack { Text(label).font(.caption); TextField("", value: b, format: .number).frame(width: 60) }
                }
            }
            Text("Shifts EXIF DateTimeOriginal, CreateDate, ModifyDate and the IPTC/XMP created dates together, like the legacy app.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let total = days * 86400 + hours * 3600 + minutes * 60 + seconds
                    library.shiftCaptureTime(seconds: subtract ? -total : total)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(days == 0 && hours == 0 && minutes == 0 && seconds == 0)
            }
        }.padding(16).frame(width: 420)
    }
}
