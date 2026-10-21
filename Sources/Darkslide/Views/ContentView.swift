import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { library.showNavigator ? .all : .detailOnly }, set: { library.showNavigator = $0 != .detailOnly })) {
            NavigatorView().navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 400)
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    if library.folder == nil && library.virtualTitle == nil {
                        emptyState
                    } else {
                        FilterBar()
                        ThumbnailGridView()
                    }
                    statusBar
                }
                if library.compareMode {
                    CompareView()
                } else if library.isPreviewing {
                    VStack(spacing: 0) {
                        PreviewView()
                        if library.showFilmstrip { FilmstripView() }
                    }
                    .transition(.opacity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { library.promptOpenFolder() } label: { Label("Open Folder", systemImage: "folder") }
            }
            ToolbarItem(placement: .principal) {
                Text(library.virtualTitle ?? library.folder?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { library.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.help("Rotate counterclockwise (⌘[)")
                Button { library.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.help("Rotate clockwise (⌘])")
                Button { library.togglePreview() } label: { Image(systemName: "rectangle.expand.vertical") }.help("Preview (Space or double-click)")
            }
            ToolbarItem(placement: .primaryAction) {
                Slider(value: $library.thumbSize, in: 96...512, step: 16)
                    .frame(width: 160)
                    .help("Thumbnail size")
            }
        }
        .sheet(isPresented: $library.showRename) { RenameView().environmentObject(library) }
        .sheet(isPresented: $library.showIngest) { IngestView().environmentObject(library) }
        .sheet(isPresented: $library.showCaption) { CaptionView().environmentObject(library) }
        .sheet(isPresented: $library.showAdjustTime) { AdjustTimeView().environmentObject(library) }
        .sheet(isPresented: $library.showExport) { ExportView().environmentObject(library) }
        .sheet(isPresented: $library.showCopyMove) { CopyMoveView().environmentObject(library) }
        .sheet(isPresented: $library.showPreferences) { PreferencesView().environmentObject(library) }
        .sheet(isPresented: $library.showFind) { FindView().environmentObject(library) }
        .sheet(isPresented: $library.showClearFields) { ClearFieldsView().environmentObject(library) }
        .sheet(isPresented: $library.showGPS) { GPSView().environmentObject(library) }
        .sheet(isPresented: $library.showGPSTrack) { GPSTrackView().environmentObject(library) }
        .sheet(isPresented: $library.showDateRange) { DateRangeView().environmentObject(library) }
        .sheet(isPresented: $library.showSelectRange) { SelectRangeView().environmentObject(library) }
        .sheet(isPresented: $library.showRemap) { RemapView().environmentObject(library) }
        .sheet(isPresented: $library.showDeleteMetadata) { DeleteMetadataView().environmentObject(library) }
        .sheet(isPresented: $library.showSetDPI) { SetDPIView().environmentObject(library) }
        .sheet(isPresented: $library.showKeywords) { KeywordsView().environmentObject(library) }
        .sheet(isPresented: $library.showHTMLExport) { HTMLExportView().environmentObject(library) }
        .sheet(isPresented: $library.showVideoClip) { VideoClipView().environmentObject(library) }
        .sheet(isPresented: $library.showPrint) { PrintView().environmentObject(library) }
        .sheet(isPresented: $library.showUpload) { UploadView().environmentObject(library) }
        .sheet(isPresented: $library.showCatalog) { CatalogView().environmentObject(library) }
        .sheet(isPresented: $library.showHelp) { ShortcutsHelpView() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var isDir: ObjCBool = false
                let target = (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
                    ? url : url.deletingLastPathComponent()
                DispatchQueue.main.async { library.open(target) }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Open a folder or drop one here").foregroundStyle(.secondary)
            Button("Open Folder…") { library.promptOpenFolder() }.keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack {
            Text(library.items.isEmpty ? "No images" : (library.filtersActive ? "\(library.visible.count) of \(library.items.count)" : "\(library.items.count) items"))
            if !library.selection.isEmpty { Text("\(library.selection.count) selected").foregroundStyle(.secondary) }
            if library.metaLoaded < library.items.count { Text("reading metadata \(library.metaLoaded)/\(library.items.count)…").foregroundStyle(.secondary) }
            if let v = library.updateAvailable {
                Button("Darkslide \(v) is available") { NSWorkspace.shared.open(UpdateCheck.releasesPage) }.buttonStyle(.link).font(.caption)
            }
            if let err = library.lastError, !err.isEmpty {
                Text(err).foregroundStyle(.red).lineLimit(1).help(err)
                    .onTapGesture { library.lastError = nil }
            }
            Spacer()
            if let item = library.current {
                Text(item.displayName).lineLimit(1)
                Text(library.info(for: item).summary).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }
}
