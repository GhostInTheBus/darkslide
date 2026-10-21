import SwiftUI

@main
struct DarkslideApp: App {
    @StateObject private var library = Library()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Darkslide") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.promptOpenFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Ingest…") { library.showIngest = true }
                    .keyboardShortcut("g", modifiers: .command)
                Divider()
                Button("Rename Photos…") { library.showRename = true }
                    .keyboardShortcut("m", modifiers: .command)
                Button("IPTC Info…") { library.showCaption = true }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Adjust Capture Dates and Times…") { library.showAdjustTime = true }
                Button("Clear IPTC Fields…") { library.showClearFields = true }
                Button("Set GPS Coordinates…") { library.showGPS = true }
                Button("Import GPS Coordinates from Track…") { library.showGPSTrack = true }
                Button("Show on Map") {
                    if let c = library.current, let lat = library.info(for: c).latitude, let lon = library.info(for: c).longitude,
                       let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(c.displayName)") { NSWorkspace.shared.open(u) }
                }
                Divider()
                Button("Find…") { library.showFind = true }.keyboardShortcut("f", modifiers: .command)
                Button("Catalog…") { library.showCatalog = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Add Current Folder to Catalog") { if let f = library.folder { Catalog.shared.index(folder: f, recursive: false, progress: { _, _ in }) { n in library.lastError = "Catalog: indexed \(n) files" } } }
                Divider()
                Button("Open in Editor") { library.openInEditor() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Export…") { library.showExport = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Copy/Move Photos…") { library.showCopyMove = true }
                    .keyboardShortcut("y", modifiers: .command)
                Button("HTML Gallery…") { library.showHTMLExport = true }
                Button("Upload (FTP/SFTP)…") { library.showUpload = true }.keyboardShortcut("u", modifiers: .command)
                Button("Export Video Clip…") { library.showVideoClip = true }
                Button("Print Contact Sheet…") { library.showPrint = true }.keyboardShortcut("p", modifiers: .command)
                Button("Print Proofs (one per page)…") { library.printProofs() }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(library.targets.map(\.url)) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { library.showPreferences = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All") { library.selectAll() }.keyboardShortcut("a", modifiers: .command)
                Button("Select None") { library.selectNone() }.keyboardShortcut("d", modifiers: .command)
                Button("Select Tagged") { library.selectTagged() }.keyboardShortcut("t", modifiers: .command)
                Button("Select Others (invert)") { library.invertSelection() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Select Similar Rating") { if let c = library.current { library.selectSimilar(rating: library.meta[c.url]?.rating ?? 0) } }
                Button("Select Similar Color Class") { if let c = library.current { library.selectSimilar(colorClass: library.meta[c.url]?.colorClass ?? 0) } }
                Button("Select Date Range…") { library.showDateRange = true }
                Button("Select Range…") { library.showSelectRange = true }
                Divider()
                Button("Save Selection…") { library.saveSelection() }
                Button("Load Selection…") { library.loadSelection() }
                Divider()
                Button("Move to Trash") { library.moveToTrash() }.keyboardShortcut(.delete, modifiers: .command)
            }
            CommandMenu("Cull") {
                ForEach(0...5, id: \.self) { r in
                    Button(r == 0 ? "Clear Rating" : "\(r) Star\(r == 1 ? "" : "s")") { library.setRating(r) }
                        .keyboardShortcut(KeyEquivalent(Character("\(r)")), modifiers: [])
                }
                Divider()
                ForEach(0...8, id: \.self) { c in
                    Button(c == 0 ? "Clear Color Class" : library.colorClasses.name(c)) { library.setColorClass(c) }
                        .keyboardShortcut(KeyEquivalent(Character("\(c)")), modifiers: .command)
                }
                Divider()
                Button("Toggle Tag") { library.toggleTag() }.keyboardShortcut("t", modifiers: [])
                Divider()
                Button("Rotate Clockwise") { library.rotate(clockwise: true) }.keyboardShortcut("]", modifiers: .command)
                Button("Rotate Counterclockwise") { library.rotate(clockwise: false) }.keyboardShortcut("[", modifiers: .command)
                Button("Mirror Horizontal") { library.mirror(horizontal: true) }.keyboardShortcut("[", modifiers: [.command, .option])
                Button("Mirror Vertical") { library.mirror(horizontal: false) }.keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("Remap Ratings and Color Classes…") { library.showRemap = true }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { library.showHelp = true }.keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Check for Updates") { UpdateCheck.check(force: true) { v in library.updateAvailable = v; if v == nil { library.lastError = "Darkslide \(UpdateCheck.currentVersion) is the latest version" } } }
                Toggle("Check for Updates Daily", isOn: $library.checkForUpdates)
                Button("Open Settings Folder") { NSWorkspace.shared.open(AppPaths.support) }
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.file]) }
            }
            CommandMenu("Tools") {
                Button("Delete Metadata…") { library.showDeleteMetadata = true }
                Button("Set DPI…") { library.showSetDPI = true }
                Button("Extract JPEG Previews") { library.extractPreviews(to: nil) }
                Button("Convert RAW to DNG") { library.lastError = ExportEngine.convertToDNG(items: library.targets, to: nil); library.rescan() }
                Button("Structured Keywords…") { library.showKeywords = true }.keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Set GPS Home from Current Photo") {
                    if let c = library.current, let lat = library.info(for: c).latitude, let lon = library.info(for: c).longitude { library.gpsHome = (lat, lon) }
                    else { library.lastError = "Current photo has no GPS" }
                }
                Button("Set GPS to Home") { if let h = library.gpsHome { library.setGPS(latitude: h.0, longitude: h.1) } else { library.lastError = "No GPS home set" } }
                Divider()
                Button("Send via Email") { library.share(.composeEmail) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Share via AirDrop") { library.share(.sendViaAirDrop) }
                Button("Share via Messages") { library.share(.composeMessage) }
            }
            CommandMenu("View") {
                Button(library.isPreviewing ? "Close Preview" : "Preview") { library.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Toggle 100% Zoom") { library.zoomToggle.toggle() }
                    .keyboardShortcut("z", modifiers: [])
                Button(library.cropMode ? "Leave Crop Mode" : "Crop") { if library.isPreviewing { library.cropMode.toggle() } else { library.togglePreview(); library.cropMode = true } }
                    .keyboardShortcut("c", modifiers: [])
                Button("Remove Crop") { library.setCrop(nil) }
                Toggle("Show Navigator", isOn: $library.showNavigator).keyboardShortcut("1", modifiers: [.command, .option])
                Toggle("Show Filmstrip in Preview", isOn: $library.showFilmstrip).keyboardShortcut("2", modifiers: [.command, .option])
                Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button(library.compareMode ? "Leave Compare" : "Compare Selected") { library.compareMode ? (library.compareMode = false) : library.startCompare() }
                    .keyboardShortcut("x", modifiers: [])
                Button(library.showSlideshow ? "Stop Slideshow" : "Slideshow") { library.showSlideshow ? library.stopSlideshow() : library.startSlideshow() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Picker("Sort By", selection: $library.sortKey) { ForEach(Library.SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Then By", selection: $library.secondarySortKey) {
                    Text("None").tag(Optional<Library.SortKey>.none)
                    ForEach(Library.SortKey.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Toggle("Reverse Sort", isOn: $library.sortReversed)
                Button("Rescan Folder") { library.rescan() }.keyboardShortcut("/", modifiers: .command)
                Divider()
                Button("Larger Thumbnails") { library.thumbSize = min(512, library.thumbSize + 32) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Thumbnails") { library.thumbSize = max(96, library.thumbSize - 32) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.start()
        _ = Shortcuts.current   // load (and migrate) shortcuts.json now, not on the first keypress
        // Cull and navigation keys work no matter which view has focus (sidebar, grid,
        // preview), as long as nobody is typing in a text field and no sheet is up.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let lib = Library.shared, let w = e.window, w == NSApp.mainWindow, w.attachedSheet == nil,
                  !(w.firstResponder is NSTextView), !(w.firstResponder is NSTextField) else { return e }
            return lib.handle(e) ? nil : e
        }
        // A killed app must not leave its exiftool child behind.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // A SIGTERM must end the process even if a sheet is open; NSApp.terminate can be
        // cancelled by a modal, which left a zombie instance behind once.
        sigterm?.setEventHandler { ExifTool.shared.shutdown(); exit(0) }
        sigterm?.resume()
    }
    func applicationWillTerminate(_ notification: Notification) { ExifTool.shared.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
