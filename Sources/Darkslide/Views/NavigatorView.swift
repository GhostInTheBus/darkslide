import SwiftUI

/// Left-hand folder navigator: Favorites, mounted volumes, and a lazy folder tree.
struct NavigatorView: View {
    @EnvironmentObject var library: Library
    @State private var volumes: [URL] = NavigatorView.mountedVolumes()
    @State private var expanded: Set<URL> = []

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(library.settings.favoriteFolders, id: \.self) { path in
                    let u = URL(fileURLWithPath: path)
                    FolderRow(url: u, expanded: $expanded)
                        .contextMenu { Button("Remove from Favorites") { library.settings.favoriteFolders.removeAll { $0 == path }; library.saveSettings() } }
                }
                if let f = library.folder, !library.settings.favoriteFolders.contains(f.path) {
                    Button { library.settings.favoriteFolders.append(f.path); library.saveSettings() } label: { Label("Add \(f.lastPathComponent)", systemImage: "star") }.buttonStyle(.plain).font(.caption)
                }
            }
            Section("Places") {
                ForEach(NavigatorView.places, id: \.self) { u in FolderRow(url: u, expanded: $expanded) }
            }
            Section("Volumes") {
                ForEach(volumes, id: \.self) { u in FolderRow(url: u, expanded: $expanded, icon: CardWatcher.looksLikeCard(u) ? "sdcard" : "externaldrive") }
            }
        }
        .listStyle(.sidebar)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumes = NavigatorView.mountedVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumes = NavigatorView.mountedVolumes() }
        .onAppear { if let f = library.folder { expandAncestors(of: f) } }
        .onChange(of: library.folder) { _, f in if let f { expandAncestors(of: f) } }
    }

    /// Expand the path down to the open folder, but stop at a Places root or the home
    /// folder so the sidebar does not unfold the whole home directory.
    private func expandAncestors(of url: URL) {
        let roots = Set(NavigatorView.places.map(\.path) + [FileManager.default.homeDirectoryForCurrentUser.path])
        if roots.contains(url.path) { return }
        var u = url.deletingLastPathComponent()
        while u.path.count > 1 {
            expanded.insert(u)
            if roots.contains(u.path) { break }
            u = u.deletingLastPathComponent()
        }
    }

    static var places: [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for d in [FileManager.SearchPathDirectory.picturesDirectory, .desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first, fm.fileExists(atPath: u.path) { out.append(u) }
        }
        out.append(fm.homeDirectoryForCurrentUser)
        return out
    }

    static func mountedVolumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" }
    }
}

/// One folder with a disclosure triangle; children are read only when expanded.
struct FolderRow: View {
    @EnvironmentObject var library: Library
    let url: URL
    @Binding var expanded: Set<URL>
    var icon: String = "folder"
    @State private var children: [URL]? = nil

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(url) }, set: { on in
            if on { expanded.insert(url); if children == nil { children = FolderRow.subfolders(of: url) } } else { expanded.remove(url) }
        })) {
            if let kids = children ?? (expanded.contains(url) ? FolderRow.subfolders(of: url) : nil) {
                ForEach(kids, id: \.self) { k in FolderRow(url: k, expanded: $expanded) }
            }
        } label: {
            let current = library.folder == url
            Label(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, systemImage: icon).lineLimit(1)
                .fontWeight(current ? .semibold : .regular)
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(current ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { if library.folder != url { library.open(url) } }
        }
        .onAppear { if expanded.contains(url) && children == nil { children = FolderRow.subfolders(of: url) } }
    }

    static func subfolders(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
