import AppKit
import SwiftUI

/// App state: the open folder, its items, the selection, metadata, filters, preview mode.
@MainActor
final class Library: ObservableObject {
    @Published var folder: URL?
    @Published var items: [PhotoItem] = [] { didSet { visibleCache = nil } }          // everything in the folder
    private var visibleCache: [PhotoItem]?
    @Published var selection: Set<URL> = []
    @Published var currentIndex: Int? = nil         // index into `visible`
    @Published var isPreviewing = false
    @Published var zoomToggle = false
    @Published var thumbSize: CGFloat = 192 { didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") } }
    @Published var scanTime: TimeInterval = 0
    @Published var infoCache: [URL: CaptureInfo] = [:]
    @Published var meta: [URL: PhotoMeta] = [:] { didSet { if filtersActive { visibleCache = nil } } }
    @Published var metaLoaded = 0
    @Published var lastError: String?
    @Published var colorClasses = ColorClassSet()
    @Published var settings = AppSettings.load()
    @Published var showRename = false
    @Published var showIngest = false
    @Published var showCaption = false
    @Published var showAdjustTime = false
    @Published var showExport = false
    @Published var showCopyMove = false
    @Published var showPreferences = false
    @Published var showFind = false
    @Published var showClearFields = false
    @Published var showGPS = false
    @Published var showGPSTrack = false
    @Published var reloadToken = 0           // bump to make the grid redraw its cells
    @Published var liveIngest = false { didSet { liveIngest ? startLiveIngest() : stopLiveIngest() } }
    @Published var liveIngestStatus = ""
    private var liveTimer: Timer?
    private var liveRunning = false
    var codeMap: [String: String] = CodeReplacements.load()
    @Published var lastRename: RenameEngine.Applied?
    private var cardWatcher: CardWatcher?
    private let folderWatcher = FolderWatcher()
    @Published var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey"); resort() }
    }
    @Published var sortReversed = UserDefaults.standard.bool(forKey: "sortReversed") {
        didSet { UserDefaults.standard.set(sortReversed, forKey: "sortReversed"); resort() }
    }
    enum SortKey: String, CaseIterable { case name = "Name", captureTime = "Capture time", rating = "Rating", colorClass = "Color class", modified = "Modified" }

    // Filters
    @Published var filterRatings: Set<Int> = [] { didSet { visibleCache = nil } }      // empty = all
    @Published var filterClasses: Set<Int> = [] { didSet { visibleCache = nil } }      // empty = all
    @Published var filterTaggedOnly = false { didSet { visibleCache = nil } }
    @Published var quickSearch = "" { didSet { visibleCache = nil } }                 // Quick Search: filename + any caption field
    @Published var filterDateFrom: Date? = nil { didSet { visibleCache = nil } }
    @Published var filterDateTo: Date? = nil { didSet { visibleCache = nil } }
    @Published var secondarySortKey: SortKey? = nil
    @Published var showDateRange = false
    @Published var showSelectRange = false
    @Published var showRemap = false
    @Published var showDeleteMetadata = false
    @Published var showSetDPI = false
    @Published var showSlideshow = false
    @Published var showKeywords = false
    @Published var showHTMLExport = false
    @Published var showVideoClip = false
    @Published var showPrint = false
    @Published var cropMode = false
    @Published var showUpload = false
    @Published var showCatalog = false
    @Published var showHelp = false
    @Published var showNavigator = UserDefaults.standard.object(forKey: "showNavigator") as? Bool ?? true { didSet { UserDefaults.standard.set(showNavigator, forKey: "showNavigator") } }
    @Published var showFilmstrip = UserDefaults.standard.object(forKey: "showFilmstrip") as? Bool ?? true { didSet { UserDefaults.standard.set(showFilmstrip, forKey: "showFilmstrip") } }
    @Published var virtualTitle: String? = nil     // set when showing search results instead of a folder
    @Published var slideshowSeconds: Double = 4
    private var slideshowTimer: Timer?
    @Published var advanceAfterRating = UserDefaults.standard.object(forKey: "advanceAfterRating") as? Bool ?? true {
        didSet { UserDefaults.standard.set(advanceAfterRating, forKey: "advanceAfterRating") }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "thumbSize")
        if saved >= 96 { thumbSize = saved }
        ExifTool.shared.log = { [weak self] msg in DispatchQueue.main.async { self?.lastError = msg.trimmingCharacters(in: .whitespacesAndNewlines) } }
        if let last = UserDefaults.standard.url(forKey: "lastFolder"), FileManager.default.fileExists(atPath: last.path) {
            open(last)
        }
        colorClasses = settings.colorClasses
        cardWatcher = CardWatcher()
        cardWatcher?.onCard = { [weak self] _ in self?.showIngest = true }
        folderWatcher.onChange = { [weak self] in self?.rescan() }
    }

    func resort() {
        items = sorted(items)
    }

    func sorted(_ list: [PhotoItem]) -> [PhotoItem] {
        var out = sortedOnce(list, by: sortKey)
        if let s = secondarySortKey, s != sortKey {
            // Stable secondary: sort by secondary first, then stable-sort by primary.
            out = sortedOnce(sortedOnce(list, by: s), by: sortKey)
        }
        return sortReversed ? out.reversed() : out
    }

    private func sortedOnce(_ list: [PhotoItem], by key: SortKey) -> [PhotoItem] {
        let out: [PhotoItem]
        switch key {
        case .name: out = list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .captureTime: out = list.sorted { (meta[$0.url]?.captureDate ?? "") < (meta[$1.url]?.captureDate ?? "") }
        case .rating: out = list.sorted { (meta[$0.url]?.rating ?? 0) > (meta[$1.url]?.rating ?? 0) }
        case .colorClass: out = list.sorted { (meta[$0.url]?.colorClass ?? 9) < (meta[$1.url]?.colorClass ?? 9) }
        case .modified:
            func mod(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            out = list.sorted { mod($0.url) < mod($1.url) }
        }
        return out
    }

    // MARK: Selection helpers

    func selectAll() { selection = Set(visible.map(\.id)) }
    func selectNone() { selection = [] }
    func selectSimilar(rating: Int? = nil, colorClass: Int? = nil) {
        selection = Set(visible.filter { item in
            let m = meta[item.url] ?? PhotoMeta()
            if let r = rating { return m.rating == r }
            if let c = colorClass { return m.colorClass == c }
            return false
        }.map(\.id))
    }

    /// the legacy app's Move to Trash: Finder trash, never rm. Companions go too.
    func moveToTrash() {
        let ts = targets
        guard !ts.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(ts.count) photo\(ts.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "RAW+JPEG pairs and sidecars go together. You can put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in ts {
            for f in RenameEngine.companions(of: item) { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) }
        }
        selection = []
        rescan()
    }

    func saveSettings() { settings.colorClasses = colorClasses; settings.save() }

    func variableContext() -> VariableContext {
        var ctx = VariableContext()
        ctx.sequence = settings.sequence
        ctx.sequencePadding = settings.sequencePadding
        ctx.jobName = settings.jobName
        ctx.colorClassName = { [colorClasses] in colorClasses.name($0) }
        return ctx
    }

    // MARK: Rename

    func applyRename(_ plan: RenamePlan, advanceSequenceBy n: Int) {
        let applied = RenameEngine.apply(plan)
        lastRename = applied
        settings.sequence += n
        saveSettings()
        if !applied.failed.isEmpty { lastError = "Rename: \(applied.failed.count) failed, first: \(applied.failed[0].1)" }
        // Keep metadata keyed by the new names so nothing re-reads.
        var newMeta = meta
        for (from, to) in applied.moved { if let m = newMeta.removeValue(forKey: from) { newMeta[to] = m } }
        meta = newMeta
        rescan()
    }

    func undoRename() {
        guard let last = lastRename else { return }
        let errs = RenameEngine.undo(last)
        if !errs.isEmpty { lastError = "Undo: " + errs.joined(separator: "; ") }
        var newMeta = meta
        for (from, to) in last.moved { if let m = newMeta.removeValue(forKey: to) { newMeta[from] = m } }
        meta = newMeta
        lastRename = nil
        rescan()
    }

    // MARK: Caption

    /// Apply a caption template to items: variables expand per photo.
    func applyTemplate(_ t: IPTCTemplate, to items: [PhotoItem]) {
        for item in items {
            var ctx = variableContext()
            ctx.item = item; ctx.meta = meta[item.url]; ctx.info = info(for: item)
            var fields: [String: String] = [:]
            for key in t.apply {
                var v = Variables.expand(t.fields[key] ?? "", ctx)
                if settings.codeReplacementsEnabled { v = CodeReplacements.expand(v, delimiter: settings.codeReplacementDelimiter, map: codeMap) }
                fields[key] = v
            }
            Keywords.remember(fields)
            var files = [item.url]
            if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.writeFields(fields, appendKeywords: t.keywordsAppend, appendCaption: t.captionAppend, to: files) { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !r.ok { self.lastError = "Caption write failed: \(r.error)"; return }
                    MetadataStore.shared.reloadAsync([item.url]) { fresh in self.meta.merge(fresh) { _, new in new } }
                }
            }
        }
    }

    func applyTemplate(_ t: IPTCTemplate, toFolder folder: URL) {
        applyTemplate(t, to: FolderScanner.scan(folder))
    }

    /// Shift capture time on the targets by a signed number of seconds.
    func shiftCaptureTime(seconds: Int) {
        let ts = targets
        var files: [URL] = []
        for item in ts { files.append(item.url); if let j = item.sidecarJPEG { files.append(j) } }
        MetadataStore.shared.shiftAllDates(seconds: seconds, files: files) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if !r.ok { self.lastError = "Time shift failed: \(r.error)"; return }
                MetadataStore.shared.reloadAsync(ts.map(\.url)) { fresh in self.meta.merge(fresh) { _, new in new } }
                for item in ts { self.infoCache[item.url] = nil }
            }
        }
    }

    // MARK: Items and filtering

    var filtersActive: Bool { !filterRatings.isEmpty || !filterClasses.isEmpty || filterTaggedOnly || !quickSearch.isEmpty || filterDateFrom != nil || filterDateTo != nil }

    var visible: [PhotoItem] {
        guard filtersActive else { return items }
        if let v = visibleCache { return v }
        let v = items.filter { item in
            let m = meta[item.url] ?? PhotoMeta()
            if !filterRatings.isEmpty && !filterRatings.contains(m.rating) { return false }
            if !filterClasses.isEmpty && !filterClasses.contains(m.colorClass) { return false }
            if filterTaggedOnly && !m.tagged { return false }
            if filterDateFrom != nil || filterDateTo != nil {
                let d = captureDate(of: item)
                if let from = filterDateFrom, (d ?? .distantPast) < from { return false }
                if let to = filterDateTo, (d ?? .distantFuture) > to { return false }
            }
            if !quickSearch.isEmpty {
                let q = quickSearch.lowercased()
                let hay = ([item.displayName] + IPTCTemplate.fieldKeys.map { m.field($0) }).joined(separator: "\n").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        visibleCache = v
        return v
    }

    var current: PhotoItem? {
        let v = visible
        guard let i = currentIndex, v.indices.contains(i) else { return nil }
        return v[i]
    }

    /// Items a cull/caption action applies to: the selection, or the current item.
    var targets: [PhotoItem] {
        let sel = items.filter { selection.contains($0.id) }
        if !sel.isEmpty { return sel }
        return current.map { [$0] } ?? []
    }

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        ThumbnailCache.shared.cancelAll()
        let t0 = Date()
        let scanned = FolderScanner.scan(url)
        scanTime = Date().timeIntervalSince(t0)
        folder = url
        virtualTitle = nil
        items = scanned
        selection = []
        currentIndex = scanned.isEmpty ? nil : 0
        infoCache = [:]
        meta = [:]
        metaLoaded = 0
        isPreviewing = false
        UserDefaults.standard.set(url, forKey: "lastFolder")
        folderWatcher.watch(url)
        MetadataStore.shared.loadAll(scanned) { [weak self] chunk in
            guard let self else { return }
            meta.merge(chunk) { _, new in new }
            metaLoaded += chunk.count
            if metaLoaded >= items.count && sortKey != .name { resort() }
        }
    }

    /// Show an arbitrary set of files as a contact sheet (catalog search results).
    func openVirtual(_ urls: [URL], title: String) {
        ThumbnailCache.shared.cancelAll()
        folderWatcher.stop()
        folder = nil
        virtualTitle = title
        items = sorted(urls.map { PhotoItem(id: $0, url: $0, sidecarJPEG: nil, displayName: $0.lastPathComponent) })
        selection = []; currentIndex = items.isEmpty ? nil : 0; infoCache = [:]; meta = [:]; metaLoaded = 0; isPreviewing = false
        MetadataStore.shared.loadAll(items) { [weak self] chunk in
            guard let self else { return }
            meta.merge(chunk) { _, new in new }; metaLoaded += chunk.count
        }
    }

    func rescan() {
        if virtualTitle != nil { return }
        guard let folder else { return }
        let scanned = sorted(FolderScanner.scan(folder))
        let known = Set(items.map(\.url))
        let newOnes = scanned.filter { !known.contains($0.url) }      // genuinely new files, not "metadata not loaded yet"
        let currentID = current?.id
        items = scanned
        if let id = currentID, let i = visible.firstIndex(where: { $0.id == id }) { currentIndex = i }
        else if let i = currentIndex { currentIndex = visible.isEmpty ? nil : min(i, visible.count - 1) }
        if !newOnes.isEmpty {
            MetadataStore.shared.loadAll(newOnes, cancelPrevious: false) { [weak self] chunk in
                guard let self else { return }
                meta.merge(chunk) { _, new in new }
                metaLoaded += chunk.count
                carryMetadataIntoEdits(chunk)
            }
        }
    }

    /// An editor saved a new file beside its original: copy the original's caption,
    /// keywords, rating and class into it, whatever app wrote it. Only when the new
    /// file has no caption of its own yet.
    private func carryMetadataIntoEdits(_ fresh: [URL: PhotoMeta]) {
        for item in items where item.editOf != nil {
            func hasDescriptive(_ m: PhotoMeta) -> Bool { !(m.caption.isEmpty && m.keywords.isEmpty && m.byline.isEmpty && m.city.isEmpty && m.headline.isEmpty && m.copyright.isEmpty) }
            guard let edit = fresh[item.url], !hasDescriptive(edit), edit.rating == 0, edit.colorClass == 0, !item.isVideo,
                  let orig = item.editOf, let om = meta[orig], hasDescriptive(om) || om.rating > 0 || om.colorClass > 0 else { continue }
            MetadataStore.shared.copyMetadata(from: orig, to: item.url) { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if r.ok { MetadataStore.shared.reloadAsync([item.url]) { fresh in self.meta.merge(fresh) { _, new in new } } }
                    else { self.lastError = "Carry metadata into \(item.displayName): \(r.error)" }
                }
            }
        }
    }

    func captureDate(of item: PhotoItem) -> Date? {
        if let s = meta[item.url]?.captureDate, let d = Variables.exifDate.date(from: s) { return d }
        if let d = info(for: item).captureDate { return d }
        return (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    // MARK: Selection save / load / range

    func selectRange(from a: Int, to b: Int) {
        let v = visible
        guard !v.isEmpty else { return }
        let lo = max(1, min(a, b)), hi = min(v.count, max(a, b))
        selection = Set(v[(lo - 1)..<hi].map(\.id))
    }

    func saveSelection() {
        let p = NSSavePanel(); p.nameFieldStringValue = "selection.txt"; p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let u = p.url else { return }
        let names = targets.map(\.displayName).joined(separator: "\n")
        try? names.write(to: u, atomically: true, encoding: .utf8)
    }

    func loadSelection() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        let names = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        selection = Set(visible.filter { names.contains($0.displayName) || names.contains($0.url.deletingPathExtension().lastPathComponent) }.map(\.id))
    }

    // MARK: Remap / delete metadata / DPI / mirror / previews

    /// the legacy app's Remap Rating and Remap Color Class: old value → new value across the targets.
    func remap(ratings: [Int: Int], classes: [Int: Int]) {
        let ts = targets
        for item in ts {
            var m = meta[item.url] ?? PhotoMeta()
            var changed = false
            if let r = ratings[m.rating], r != m.rating { m.rating = r; changed = true }
            if let c = classes[m.colorClass], c != m.colorClass { m.colorClass = c; changed = true }
            guard changed else { continue }
            if m.frameNum.isEmpty { m.frameNum = Library.frameNumber(for: item) }
            meta[item.url] = m
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.writeCull(m, label: colorClasses.name(m.colorClass), to: files) { [weak self] r in
                if !r.ok { DispatchQueue.main.async { self?.lastError = "Remap \(item.displayName): \(r.error)" } }
            }
        }
    }

    func deleteMetadata(xmp: Bool, iptc: Bool, exif: Bool, gps: Bool, keepOrientation: Bool) {
        let ts = targets
        var files: [URL] = []
        for i in ts { files.append(i.url); if let j = i.sidecarJPEG { files.append(j) } }
        MetadataStore.shared.deleteMetadata(xmp: xmp, iptc: iptc, exif: exif, gps: gps, keepOrientation: keepOrientation, files: files) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if !r.ok { self.lastError = "Delete metadata: \(r.error)"; return }
                MetadataStore.shared.reloadAsync(ts.map(\.url)) { fresh in self.meta.merge(fresh) { _, new in new } }
                for i in ts { self.infoCache[i.url] = nil }
            }
        }
    }

    func setDPI(_ dpi: Int) {
        var files: [URL] = []
        for i in targets { files.append(i.url); if let j = i.sidecarJPEG { files.append(j) } }
        MetadataStore.shared.setDPI(dpi, files: files) { [weak self] r in
            if !r.ok { DispatchQueue.main.async { self?.lastError = "Set DPI: \(r.error)" } }
        }
    }

    func mirror(horizontal: Bool) {
        let ts = targets
        for item in ts {
            let cur = info(for: item).orientation
            // Mirror composes with the current orientation: flip the "mirrored" bit.
            let h: [Int: Int] = [1: 2, 2: 1, 3: 4, 4: 3, 5: 6, 6: 5, 7: 8, 8: 7]
            let v: [Int: Int] = [1: 4, 4: 1, 2: 3, 3: 2, 5: 8, 8: 5, 6: 7, 7: 6]
            let next = (horizontal ? h : v)[cur] ?? (horizontal ? 2 : 4)
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.setOrientation(next, files: files) { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !r.ok { self.lastError = "Mirror: \(r.error)"; return }
                    self.infoCache[item.url] = nil
                    ThumbnailCache.shared.remove(item.url); PreviewCache.shared.remove(item.url)
                    self.reloadToken += 1
                }
            }
        }
    }

    /// the legacy app's Extract JPEG Previews: write each RAW's embedded JPEG next to it (or to a folder).
    func extractPreviews(to folder: URL?) {
        let ts = targets.filter(\.isRaw)
        var n = 0, failed = 0
        for item in ts {
            let dest = (folder ?? item.url.deletingLastPathComponent()).appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "_preview").appendingPathExtension("jpg")
            if let strip = TIFFPreview.ifd0JPEG(item.url) {
                do { try strip.data.write(to: IngestEngine.uniqueDestination(dest)); n += 1 } catch { failed += 1 }
            } else {
                let r = ExifTool.shared.run(["-b", "-JpgFromRaw", "-w", "%d%f_preview.jpg", item.url.path])
                if r.ok { n += 1 } else { failed += 1 }
            }
        }
        lastError = failed > 0 ? "Extracted \(n) previews, \(failed) failed" : nil
        rescan()
    }

    func setCrop(_ c: CropRect?) {
        let ts = targets
        for item in ts {
            var m = meta[item.url] ?? PhotoMeta(); m.crop = (c?.hasCrop == true) ? c : nil; meta[item.url] = m
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.writeCrop(m.crop, files: files) { [weak self] r in
                if !r.ok { DispatchQueue.main.async { self?.lastError = "Crop: \(r.error)" } }
            }
        }
        cropMode = false
    }

    // MARK: GPS home

    var gpsHome: (Double, Double)? {
        get { let d = UserDefaults.standard; return d.object(forKey: "gpsHomeLat") == nil ? nil : (d.double(forKey: "gpsHomeLat"), d.double(forKey: "gpsHomeLon")) }
        set { let d = UserDefaults.standard; if let v = newValue { d.set(v.0, forKey: "gpsHomeLat"); d.set(v.1, forKey: "gpsHomeLon") } else { d.removeObject(forKey: "gpsHomeLat"); d.removeObject(forKey: "gpsHomeLon") } }
    }

    // MARK: Slideshow

    func startSlideshow() {
        guard !visible.isEmpty else { return }
        if !isPreviewing { togglePreview() }
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            if (currentIndex ?? 0) >= visible.count - 1 { step(-(currentIndex ?? 0)) } else { step(1) }
        }
        showSlideshow = true
    }
    func stopSlideshow() { slideshowTimer?.invalidate(); slideshowTimer = nil; showSlideshow = false }

    /// One photo per page with its filename and caption.
    func printProofs() {
        let items = targets.isEmpty ? visible : targets
        guard !items.isEmpty else { return }
        let view = ProofsPrintView(items: items, meta: meta)
        let op = NSPrintOperation(view: view)
        op.printInfo.horizontalPagination = .fit; op.printInfo.verticalPagination = .automatic
        op.run()
    }

    // MARK: Share

    func share(_ service: NSSharingService.Name) {
        let urls = targets.map(\.url)
        guard !urls.isEmpty, let s = NSSharingService(named: service) else { lastError = "That share service is not available"; return }
        s.perform(withItems: urls)
    }

    // MARK: Navigation

    func togglePreview() {
        guard !visible.isEmpty else { return }
        if currentIndex == nil { currentIndex = 0 }
        isPreviewing.toggle()
        if isPreviewing { prefetchAround(currentIndex ?? 0) }
    }

    func step(_ delta: Int) {
        let v = visible
        guard !v.isEmpty else { return }
        let next = min(max((currentIndex ?? 0) + delta, 0), v.count - 1)
        currentIndex = next
        selection = [v[next].id]
        prefetchAround(next)
    }

    func prefetchAround(_ index: Int) {
        let v = visible
        for offset in [0, 1, -1, 2, -2] {
            let i = index + offset
            guard v.indices.contains(i) else { continue }
            PreviewCache.shared.request(v[i].url)
        }
    }

    func info(for item: PhotoItem) -> CaptureInfo {
        if let c = infoCache[item.url] { return c }
        let c = ImageLoader.captureInfo(for: item.url)
        infoCache[item.url] = c
        return c
    }

    // MARK: Culling

    func setRating(_ r: Int) { applyCull { $0.rating = r } }
    func setColorClass(_ c: Int) { applyCull { $0.colorClass = c } }
    func toggleTag() {
        // the legacy app semantics: if every target is tagged, untag all; otherwise tag all.
        let all = targets.allSatisfy { meta[$0.url]?.tagged ?? false }
        applyCull { $0.tagged = !all }
    }

    private func applyCull(_ change: (inout PhotoMeta) -> Void) {
        let ts = targets
        guard !ts.isEmpty else { return }
        for item in ts {
            var m = meta[item.url] ?? PhotoMeta()
            let before = m
            change(&m)
            if m.frameNum.isEmpty { m.frameNum = Library.frameNumber(for: item) }
            meta[item.url] = m                              // optimistic
            var files = [item.url]
            if let j = item.sidecarJPEG { files.append(j) }
            let label = colorClasses.name(m.colorClass)
            MetadataStore.shared.writeCull(m, label: label, to: files) { [weak self] r in
                guard let self else { return }
                if !r.ok {
                    DispatchQueue.main.async {
                        self.meta[item.url] = before
                        self.lastError = "Write failed for \(item.displayName): \(r.error)"
                    }
                }
            }
        }
        if isPreviewing && advanceAfterRating && ts.count == 1 {
            if visible.contains(where: { $0.id == ts[0].id }) { step(1) }
            else if let i = currentIndex { currentIndex = visible.isEmpty ? nil : min(i, visible.count - 1); if let c = current { selection = [c.id]; prefetchAround(currentIndex ?? 0) } }
        }
    }

    /// the legacy app fills FrameNum from the camera's image number when it has one, else zero.
    static func frameNumber(for item: PhotoItem) -> String {
        let base = item.url.deletingPathExtension().lastPathComponent
        let digits = base.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
        let n = Int(String(digits.reversed())) ?? 0
        return String(format: "%06d", n)
    }

    // MARK: Rotate, GPS, clear, find

    /// Soft rotate the targets by ±90°: new orientation = current composed with the turn.
    func rotate(clockwise: Bool) {
        let ts = targets
        for item in ts {
            let cur = info(for: item).orientation
            let cw: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
            let ccw: [Int: Int] = [1: 8, 8: 3, 3: 6, 6: 1, 2: 5, 5: 4, 4: 7, 7: 2]
            let next = (clockwise ? cw : ccw)[cur] ?? (clockwise ? 6 : 8)
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.setOrientation(next, files: files) { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !r.ok { self.lastError = "Rotate: \(r.error)"; return }
                    self.infoCache[item.url] = nil
                    ThumbnailCache.shared.remove(item.url); PreviewCache.shared.remove(item.url)
                    self.reloadToken += 1
                }
            }
        }
    }

    func setGPS(latitude: Double?, longitude: Double?) {
        let ts = targets
        var files: [URL] = []
        for i in ts { files.append(i.url); if let j = i.sidecarJPEG { files.append(j) } }
        MetadataStore.shared.writeGPS(latitude: latitude, longitude: longitude, files: files) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if !r.ok { self.lastError = "GPS: \(r.error)"; return }
                for i in ts { self.infoCache[i.url] = nil }
                self.objectWillChange.send()
            }
        }
    }

    func clearFields(_ keys: Set<String>) {
        let ts = targets
        var files: [URL] = []
        for i in ts { files.append(i.url); if let j = i.sidecarJPEG { files.append(j) } }
        MetadataStore.shared.clearFields(keys, files: files) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if !r.ok { self.lastError = "Clear fields: \(r.error)"; return }
                MetadataStore.shared.reloadAsync(ts.map(\.url)) { fresh in self.meta.merge(fresh) { _, new in new } }
            }
        }
    }

    /// Find: select every visible item whose chosen fields contain the text.
    func find(_ text: String, in keys: Set<String>, caseSensitive: Bool, filenames: Bool) -> Int {
        let needle = caseSensitive ? text : text.lowercased()
        func has(_ s: String) -> Bool { (caseSensitive ? s : s.lowercased()).contains(needle) }
        let hits = visible.filter { item in
            if filenames && has(item.displayName) { return true }
            let m = meta[item.url] ?? PhotoMeta()
            for k in keys where has(m.field(k)) { return true }
            return false
        }
        selection = Set(hits.map(\.id))
        if let first = hits.first, let i = visible.firstIndex(of: first) { currentIndex = i }
        return hits.count
    }

    /// Find and replace inside chosen fields of the targets (or everything visible).
    func replace(_ text: String, with replacement: String, in keys: Set<String>, caseSensitive: Bool, scopeAll: Bool) -> Int {
        let pool = scopeAll ? visible : targets
        var count = 0
        for item in pool {
            let m = meta[item.url] ?? PhotoMeta()
            var fields: [String: String] = [:]
            for k in keys {
                let v = m.field(k)
                let new = v.replacingOccurrences(of: text, with: replacement, options: caseSensitive ? [] : [.caseInsensitive])
                if new != v { fields[k] = new }
            }
            guard !fields.isEmpty else { continue }
            count += 1
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.writeFields(fields, appendKeywords: false, appendCaption: false, to: files) { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !r.ok { self.lastError = "Replace: \(r.error)"; return }
                    MetadataStore.shared.reloadAsync([item.url]) { fresh in self.meta.merge(fresh) { _, new in new } }
                }
            }
        }
        return count
    }

    // MARK: Live ingest

    private func startLiveIngest() {
        liveIngestStatus = "Live ingest on: watching cards every 10 s"
        liveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.liveIngestTick() }
    }
    private func stopLiveIngest() { liveTimer?.invalidate(); liveTimer = nil; liveIngestStatus = "" }

    private func liveIngestTick() {
        guard !liveRunning, !settings.ingestPrimary.isEmpty else { return }
        let cards = CardWatcher.mountedCards()
        guard !cards.isEmpty else { liveIngestStatus = "Live ingest on: no card"; return }
        liveRunning = true
        let s = settings
        let e = IngestEngine()
        let opts = IngestEngine.Options(
            sources: cards, primary: URL(fileURLWithPath: s.ingestPrimary),
            secondary: s.ingestSecondaryEnabled && !s.ingestSecondary.isEmpty ? URL(fileURLWithPath: s.ingestSecondary) : nil,
            folderTemplate: s.ingestFolderTemplate, renameTemplate: s.ingestRename ? s.renameTemplate : nil,
            jobName: s.jobName, startSequence: s.sequence, sequencePadding: s.sequencePadding,
            copyNonImages: s.ingestCopyNonImages, skipMirrorCard: s.ingestSkipMirrorCard,
            skipAlreadyIngested: true, eject: false, user: UserInfo.load())
        e.onProgress = { [weak self] p in
            guard let self else { return }
            if p.finished {
                liveRunning = false
                if p.done > 0 {
                    settings.sequence = max(p.nextSequence, settings.sequence); saveSettings()
                    liveIngestStatus = "Live ingest: +\(p.done) at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
                    if let d = p.destinationFolder, folder != d { open(d) } else { rescan() }
                } else {
                    liveIngestStatus = "Live ingest on: nothing new"
                }
                if !p.failures.isEmpty { lastError = p.failures.joined(separator: "; ") }
            } else if p.total > 0 {
                liveIngestStatus = "Live ingest: \(p.done)/\(p.total)"
            }
        }
        e.run(opts) { url in (ImageLoader.captureInfo(for: url), PhotoMeta()) }
    }

    // MARK: Editor / export

    func openInEditor() {
        let files = targets.map(\.url)
        guard !files.isEmpty else { return }
        if settings.editorApp.isEmpty || !FileManager.default.fileExists(atPath: settings.editorApp) {
            let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
            p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
            p.message = "Choose the editor to open photos in"
            guard p.runModal() == .OK, let u = p.url else { return }
            settings.editorApp = u.path; saveSettings()
        }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(files, withApplicationAt: URL(fileURLWithPath: settings.editorApp), configuration: cfg) { _, err in
            if let err { DispatchQueue.main.async { self.lastError = "Open in editor: \(err.localizedDescription)" } }
        }
    }

    // MARK: Keyboard

    /// Handles a cull/navigation shortcut; returns false if the key is not ours.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let action = Shortcuts.current.action(for: event) else { return false }
        switch action {
        case .rate0: setRating(0)
        case .rate1: setRating(1)
        case .rate2: setRating(2)
        case .rate3: setRating(3)
        case .rate4: setRating(4)
        case .rate5: setRating(5)
        case .class0: setColorClass(0)
        case .class1: setColorClass(1)
        case .class2: setColorClass(2)
        case .class3: setColorClass(3)
        case .class4: setColorClass(4)
        case .class5: setColorClass(5)
        case .class6: setColorClass(6)
        case .class7: setColorClass(7)
        case .class8: setColorClass(8)
        case .toggleTag: toggleTag()
        case .preview: togglePreview()
        case .closePreview: if isPreviewing { stopSlideshow(); isPreviewing = false } else { return false }
        case .next: if isPreviewing { step(1) } else { return false }
        case .previous: if isPreviewing { step(-1) } else { return false }
        case .first: if isPreviewing { step(-(currentIndex ?? 0)) } else { return false }
        case .last: if isPreviewing { step(visible.count) } else { return false }
        case .zoom: if isPreviewing { zoomToggle.toggle() } else { return false }
        case .rename: showRename = true
        case .caption: showCaption = true
        case .openInEditor: openInEditor()
        case .rotateCW: rotate(clockwise: true)
        case .rotateCCW: rotate(clockwise: false)
        }
        return true
    }
}
