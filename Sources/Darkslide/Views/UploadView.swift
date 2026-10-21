import SwiftUI

/// the legacy app's FTP Photos As / Upload: pick a connection, optionally export with a preset
/// first, send. Connections live in settings; passwords in the Keychain.
struct UploadView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var connID: UUID?
    @State private var password = ""
    @State private var exportFirst = true
    @State private var presetID: UUID?
    @State private var done = 0
    @State private var total = 0
    @State private var running = false
    @State private var status = ""

    private var conn: UploadConnection? { library.settings.uploadConnections.first { $0.id == connID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upload \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            HStack {
                Picker("Connection", selection: $connID) { ForEach(library.settings.uploadConnections) { c in Text(c.name).tag(Optional(c.id)) } }
                Button("New") { let c = UploadConnection(); library.settings.uploadConnections.append(c); connID = c.id }
                Button("Delete") { if let id = connID { library.settings.uploadConnections.removeAll { $0.id == id }; connID = library.settings.uploadConnections.first?.id } }.disabled(conn == nil)
            }
            if let idx = library.settings.uploadConnections.firstIndex(where: { $0.id == connID }) {
                let b = $library.settings.uploadConnections[idx]
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow { Text("Name"); TextField("", text: b.name) }
                    GridRow { Text("Protocol"); Picker("", selection: b.proto) { Text("FTP").tag("ftp"); Text("FTPS").tag("ftps"); Text("SFTP (ssh keys)").tag("sftp") }.labelsHidden().frame(width: 160) }
                    GridRow { Text("Host"); HStack { TextField("host", text: b.host); Text("port"); TextField("", value: b.port, format: .number).frame(width: 60) } }
                    GridRow { Text("User"); TextField("", text: b.user) }
                    if b.proto.wrappedValue != "sftp" {
                        GridRow { Text("Password"); SecureField("stored in Keychain", text: $password) }
                    }
                    GridRow { Text("Remote folder"); TextField("/", text: b.path) }
                    GridRow { Text(""); Toggle("Passive mode", isOn: b.passive).disabled(b.proto.wrappedValue == "sftp") }
                }
            }
            Divider()
            HStack {
                Toggle("Export with preset first", isOn: $exportFirst)
                Picker("", selection: $presetID) { ForEach(library.settings.exportPresets) { p in Text(p.name).tag(Optional(p.id)) } }.labelsHidden().frame(width: 160).disabled(!exportFirst)
            }
            if total > 0 { ProgressView(value: Double(done), total: Double(max(total, 1))); Text("\(done)/\(total)").font(.caption) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(status.hasPrefix("Sent") ? Color.secondary : Color.red) }
            HStack {
                Spacer()
                Button("Close") { save(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Upload") { save(); run() }.keyboardShortcut(.defaultAction).disabled(running || conn == nil || conn!.host.isEmpty)
            }
        }
        .padding(16).frame(width: 600)
        .onAppear { connID = library.settings.uploadConnections.first?.id; presetID = library.settings.exportPresets.first?.id }
    }

    private func save() {
        if let c = conn, !password.isEmpty { Uploader.setPassword(password, for: c) }
        library.saveSettings()
    }

    private func run() {
        guard let c = conn else { return }
        running = true; status = ""
        let send: ([URL]) -> Void = { files in
            total = files.count; done = 0
            Uploader.upload(files, via: c, progress: { d, t in done = d; total = t }) { r in
                running = false
                status = r.failures.isEmpty ? "Sent \(r.sent.count) file\(r.sent.count == 1 ? "" : "s")" : r.failures.joined(separator: "\n")
            }
        }
        if exportFirst, let p = library.settings.exportPresets.first(where: { $0.id == presetID }) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("darkslide-upload-\(UUID().uuidString)")
            let user = UserInfo.load()
            ExportEngine.export(items: library.targets, preset: p, to: tmp, meta: library.meta, copyright: "", creator: user.name, progress: { d, t in done = d; total = t }) { r in
                if !r.failures.isEmpty { status = r.failures.joined(separator: "; ") }
                send(r.written)
            }
        } else {
            send(library.targets.map(\.url))
        }
    }
}
