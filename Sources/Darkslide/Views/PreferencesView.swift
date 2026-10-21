import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var user = UserInfo.load()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text("General").tag(0); Text("Color Classes").tag(1); Text("User").tag(2); Text("Shortcuts").tag(3); Text("Captions").tag(4); Text("AI").tag(5) }
                .pickerStyle(.segmented).padding()
            Group {
                switch tab {
                case 0: general
                case 1: classes
                case 2: userTab
                case 3: shortcuts
                case 4: captions
                default: ai
                }
            }.padding([.horizontal, .bottom])
            HStack { Spacer(); Button("Done") { user.save(); library.saveSettings(); dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }.frame(width: 560, height: 440)
    }

    private var general: some View {
        Form {
            HStack {
                TextField("Editor", text: $library.settings.editorApp).truncationMode(.middle)
                Button("Choose…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let u = p.url { library.settings.editorApp = u.path }
                }
            }
            Toggle("Advance to next photo after rating in preview", isOn: $library.advanceAfterRating)
            LabeledContent("exiftool") { Text(ExifTool.executable).font(.caption).textSelection(.enabled) }
            LabeledContent("Settings folder") { Text(AppPaths.support.path).font(.caption).textSelection(.enabled) }
            Text("Shortcuts, templates, counters and presets are plain JSON files in that folder.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var classes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Names are written as xmp:Label, so keep Adobe's names if Affinity or Lightroom should read them.").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<8, id: \.self) { i in
                HStack {
                    Text("⌘\(i + 1)").frame(width: 36)
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: library.colorClasses.hex(i + 1))) },
                        set: { c in library.colorClasses.hexColors[i] = NSColor(c).hexString })).labelsHidden()
                    TextField("", text: $library.colorClasses.names[i])
                }
            }
            Button("Reset to the legacy app names") { library.colorClasses = ColorClassSet() }.font(.caption)
        }
    }

    private var userTab: some View {
        Form {
            TextField("Name ({username})", text: $user.name)
            TextField("Company", text: $user.company)
            TextField("Email", text: $user.email)
            TextField("Web", text: $user.web)
            TextField("Phone", text: $user.phone)
            TextField("City", text: $user.city)
            TextField("State", text: $user.state)
            TextField("Country", text: $user.country)
            TextField("Custom 1", text: $user.custom1)
        }
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields shown in IPTC Info (legacy app: Customize IPTC Info)").font(.caption.bold())
            FlowLayout(spacing: 6) {
                ForEach(IPTCTemplate.fieldKeys, id: \.self) { k in
                    Toggle(IPTCTemplate.fieldLabels[k] ?? k, isOn: Binding(get: { !library.settings.hiddenCaptionFields.contains(k) },
                        set: { on in if on { library.settings.hiddenCaptionFields.remove(k) } else { library.settings.hiddenCaptionFields.insert(k) } })).toggleStyle(.checkbox)
                }
            }.font(.caption)
            Divider()
            Text("Preview info line (variables)").font(.caption.bold())
            TextField("", text: $library.settings.infoTemplate).font(.system(.caption, design: .monospaced))
            Text("Use \\n for a new group. Default shows file, date, camera, exposure, GPS.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Toggle("Code replacements", isOn: $library.settings.codeReplacementsEnabled)
                Text("delimiter").font(.caption)
                TextField("", text: $library.settings.codeReplacementDelimiter).frame(width: 36)
                Button("Open code-replacements.txt") { NSWorkspace.shared.open(CodeReplacements.file) }
                Button("Reload") { library.codeMap = CodeReplacements.load() }
            }.font(.caption)
            Text("\\code\\ in any caption field expands to its text. One per line: code<TAB>text.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @State private var aiKeyDraft = ""
    @State private var aiKeyStored = false
    @State private var ollamaStatus = ""
    @State private var ollamaModels: [String] = []

    private var ai: some View {
        let p = library.settings.aiProvider
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("The Suggest button in IPTC Info sends a 1024 px preview of the photo to a vision model and fills caption and keywords for you to review. Nothing is written until you press Save.").font(.caption).foregroundStyle(.secondary)
                Picker("Provider", selection: Binding(get: { library.settings.aiProvider }, set: { library.settings.aiProvider = $0; library.saveSettings(); loadKeyState() })) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                if p == .ollama {
                    GroupBox("Local model with Ollama (free, private)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Install Ollama from ollama.com (or `brew install ollama`).\n2. In Terminal, pull a vision model: `ollama pull gemma3:12b` (about 8 GB; `gemma3:4b` for small Macs, `qwen3.8:27b` for the best captions on 32 GB+ Macs).\n3. Make sure Ollama is running (menu bar icon), then press Check.").font(.caption)
                            HStack {
                                TextField("Ollama URL", text: $library.settings.ollamaURL).frame(width: 220)
                                Button("Check") { checkOllama() }
                                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                                Button("Copy pull command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("ollama pull gemma3:12b", forType: .string) }
                            }.font(.caption)
                            if !ollamaStatus.isEmpty { Text(ollamaStatus).font(.caption).foregroundStyle(ollamaStatus.hasPrefix("Connected") ? Color.green : Color.red) }
                            HStack {
                                Text("Model").font(.caption)
                                if ollamaModels.isEmpty {
                                    TextField("model name", text: $library.settings.ollamaModel).frame(width: 220)
                                } else {
                                    Picker("", selection: $library.settings.ollamaModel) { ForEach(ollamaModels, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 240)
                                }
                            }
                        }
                    }
                } else {
                    GroupBox(p.label) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.keyHelp).font(.caption)
                            HStack {
                                SecureField(aiKeyStored ? "A key is saved in your Keychain; paste a new one to replace it" : "API key", text: $aiKeyDraft).frame(width: 340)
                                Button("Save Key") { CaptionAI.setKey(aiKeyDraft, for: p); aiKeyDraft = ""; loadKeyState() }.disabled(aiKeyDraft.isEmpty)
                                if aiKeyStored { Button("Remove") { CaptionAI.setKey("", for: p); loadKeyState() } }
                            }
                            HStack {
                                Text("Model").font(.caption)
                                TextField(p.defaultModel, text: Binding(get: { library.settings.aiModels[p.rawValue] ?? "" }, set: { library.settings.aiModels[p.rawValue] = $0 })).frame(width: 240)
                                Text("blank = \(p.defaultModel)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Your key is stored in the macOS Keychain, not in settings.json. Each suggestion uploads one small preview to \(p.label) and is billed to your account.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(2)
        }
        .onAppear { loadKeyState(); if p == .ollama { checkOllama() } }
    }

    private func loadKeyState() { aiKeyStored = CaptionAI.key(for: library.settings.aiProvider) != nil }

    private func checkOllama() {
        ollamaStatus = "Checking…"
        CaptionAI.ollamaModels(base: library.settings.ollamaURL) { r in
            switch r {
            case .success(let models):
                ollamaModels = models
                ollamaStatus = models.isEmpty ? "Connected, but no models yet. Run the pull command in Terminal." : "Connected: \(models.count) model\(models.count == 1 ? "" : "s") available"
                if !models.contains(library.settings.ollamaModel), let first = models.first { library.settings.ollamaModel = first }
            case .failure: ollamaModels = []; ollamaStatus = "Ollama is not running at \(library.settings.ollamaURL). Install it, open it, then press Check."
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edit shortcuts.json and choose Reload. Keys look like \"3\", \"cmd+3\", \"shift+t\", \"space\".").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading) {
                    ForEach(ShortcutAction.allCases, id: \.self) { a in
                        GridRow { Text(a.rawValue).font(.system(.caption, design: .monospaced)); Text(Shortcuts.current.map[a] ?? "").font(.caption) }
                    }
                }
            }
            HStack {
                Button("Open shortcuts.json") { NSWorkspace.shared.open(Shortcuts.file) }
                Button("Reload") { Shortcuts.current = Shortcuts.load() }
            }
        }
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.deviceRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
