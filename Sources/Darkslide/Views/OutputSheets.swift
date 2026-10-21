import AVFoundation
import SwiftUI

struct HTMLExportView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var folder = ""
    @State private var large = 1600
    @State private var thumb = 320
    @State private var done = 0
    @State private var total = 0
    @State private var running = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTML gallery of \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            TextField("Gallery title", text: $title)
            HStack {
                TextField("Output folder", text: $folder).truncationMode(.middle)
                Button("…") { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { folder = u.path } }
            }
            HStack { Text("Large edge"); TextField("", value: $large, format: .number).frame(width: 70); Text("Thumbnail edge"); TextField("", value: $thumb, format: .number).frame(width: 70) }.font(.callout)
            if total > 0 { ProgressView(value: Double(done), total: Double(max(total, 1))) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    running = true; total = library.targets.count
                    ExportEngine.htmlGallery(items: library.targets, meta: library.meta, title: title.isEmpty ? (library.folder?.lastPathComponent ?? "Gallery") : title,
                                             to: URL(fileURLWithPath: folder), largeEdge: large, thumbEdge: thumb, progress: { d, t in done = d; total = t }) { r in
                        running = false
                        if !r.failures.isEmpty { library.lastError = r.failures.joined(separator: "; ") }
                        if let idx = r.written.first { NSWorkspace.shared.open(idx) }
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction).disabled(running || folder.isEmpty)
            }
        }.padding(16).frame(width: 520)
        .onAppear { title = library.folder?.lastPathComponent ?? ""; folder = library.settings.lastExportFolder }
    }
}

/// the legacy app's Export Video Clip: trim without re-encoding.
struct VideoClipView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var duration = 0.0
    @State private var status = ""
    private var item: PhotoItem? { library.current.flatMap { $0.isVideo ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export clip from \(item?.displayName ?? "no video selected")").font(.title3.bold())
            HStack { Text("Start"); TextField("", value: $start, format: .number).frame(width: 70); Text("End"); TextField("", value: $end, format: .number).frame(width: 70); Text(String(format: "of %.1f s", duration)).foregroundStyle(.secondary) }
            Text("Passthrough: the clip is cut on keyframes with no re-encoding, so it is instant and lossless.").font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Export") { export() }.keyboardShortcut(.defaultAction).disabled(item == nil || end <= start) }
        }.padding(16).frame(width: 460)
        .onAppear { if let i = item { duration = CMTimeGetSeconds(AVURLAsset(url: i.url).duration); end = duration } }
    }
    private func export() {
        guard let i = item else { return }
        let dest = IngestEngine.uniqueDestination(i.url.deletingPathExtension().appendingPathExtension("clip.mov"))
        let asset = AVURLAsset(url: i.url)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { status = "cannot export"; return }
        s.outputURL = dest; s.outputFileType = .mov
        s.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        status = "Exporting…"
        s.exportAsynchronously {
            DispatchQueue.main.async {
                if s.status == .completed { library.rescan(); dismiss() } else { status = "Failed: \(s.error?.localizedDescription ?? "unknown")" }
            }
        }
    }
}

/// the legacy app's Print Contact Sheet: a paginated grid of thumbnails with filenames.
struct PrintView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var columns = 5
    @State private var header = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Print contact sheet of \(library.targets.isEmpty ? library.visible.count : library.targets.count) photos").font(.title3.bold())
            HStack { Text("Columns"); Stepper(value: $columns, in: 2...10) { Text("\(columns)") } }
            TextField("Header (variables allowed, e.g. {folder} {today})", text: $header)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Print…") {
                    let items = library.targets.isEmpty ? library.visible : library.targets
                    var ctx = library.variableContext(); ctx.item = items.first
                    let view = ContactSheetPrintView(items: items, columns: columns, header: Variables.expand(header, ctx))
                    let op = NSPrintOperation(view: view)
                    op.printInfo.orientation = .portrait
                    op.printInfo.horizontalPagination = .fit; op.printInfo.verticalPagination = .automatic
                    dismiss()
                    op.run()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 460)
        .onAppear { header = "{folder}  {today}" }
    }
}

final class ContactSheetPrintView: NSView {
    let items: [PhotoItem]; let columns: Int; let header: String
    let pageSize = NSSize(width: 8.5 * 72, height: 11 * 72)
    let margin: CGFloat = 36
    init(items: [PhotoItem], columns: Int, header: String) {
        self.items = items; self.columns = columns; self.header = header
        let rowsPerPage = Self.rowsPerPage(columns: columns, pageSize: NSSize(width: 8.5 * 72, height: 11 * 72), margin: 36)
        let pages = max(1, Int(ceil(Double(items.count) / Double(columns * rowsPerPage))))
        super.init(frame: NSRect(x: 0, y: 0, width: 8.5 * 72, height: 11 * 72 * CGFloat(pages)))
    }
    required init?(coder: NSCoder) { nil }
    static func rowsPerPage(columns: Int, pageSize: NSSize, margin: CGFloat) -> Int {
        let cell = (pageSize.width - 2 * margin) / CGFloat(columns)
        return max(1, Int((pageSize.height - 2 * margin - 30) / (cell + 14)))
    }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: Int(frame.height / pageSize.height)); return true
    }
    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: frame.height - CGFloat(page) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        let cell = (pageSize.width - 2 * margin) / CGFloat(columns)
        let rows = Self.rowsPerPage(columns: columns, pageSize: pageSize, margin: margin)
        let perPage = rows * columns
        let pages = Int(frame.height / pageSize.height)
        let hAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
        let cAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.darkGray]
        for page in 0..<pages {
            let top = CGFloat(page) * pageSize.height
            NSAttributedString(string: header + "   page \(page + 1)/\(pages)", attributes: hAttrs).draw(at: NSPoint(x: margin, y: top + margin - 20))
            for i in 0..<perPage {
                let idx = page * perPage + i
                guard idx < items.count else { break }
                let r = i / columns, c = i % columns
                let x = margin + CGFloat(c) * cell, y = top + margin + 10 + CGFloat(r) * (cell + 14)
                let box = NSRect(x: x + 3, y: y + 3, width: cell - 6, height: cell - 6)
                if let cg = ImageLoader.embeddedPreview(for: items[idx].url, maxPixel: 600) ?? ImageLoader.decoded(for: items[idx].url, maxPixel: 600) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    let s = min(box.width / img.size.width, box.height / img.size.height)
                    let w = img.size.width * s, h = img.size.height * s
                    img.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                NSAttributedString(string: items[idx].displayName, attributes: cAttrs).draw(in: NSRect(x: x + 2, y: y + cell - 2, width: cell - 4, height: 12))
            }
        }
    }
}

final class ProofsPrintView: NSView {
    let items: [PhotoItem]; let meta: [URL: PhotoMeta]
    let pageSize = NSSize(width: 8.5 * 72, height: 11 * 72)
    init(items: [PhotoItem], meta: [URL: PhotoMeta]) {
        self.items = items; self.meta = meta
        super.init(frame: NSRect(x: 0, y: 0, width: 8.5 * 72, height: 11 * 72 * CGFloat(max(1, items.count))))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool { range.pointee = NSRange(location: 1, length: items.count); return true }
    override func rectForPage(_ page: Int) -> NSRect { NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        let m: CGFloat = 36
        for (i, item) in items.enumerated() {
            let top = CGFloat(i) * pageSize.height
            guard dirtyRect.intersects(NSRect(x: 0, y: top, width: pageSize.width, height: pageSize.height)) else { continue }
            let box = NSRect(x: m, y: top + m, width: pageSize.width - 2 * m, height: pageSize.height - 2 * m - 70)
            if let cg = ImageLoader.embeddedPreview(for: item.url, maxPixel: 2400) ?? ImageLoader.decoded(for: item.url, maxPixel: 2400) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                let s = min(box.width / img.size.width, box.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: NSRect(x: box.midX - w / 2, y: box.minY, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let mm = meta[item.url] ?? PhotoMeta()
            let text = item.displayName + (mm.caption.isEmpty ? "" : "\n" + mm.caption) + (mm.byline.isEmpty ? "" : "\n" + mm.byline)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
                .draw(in: NSRect(x: m, y: top + pageSize.height - m - 60, width: pageSize.width - 2 * m, height: 60))
        }
    }
}
