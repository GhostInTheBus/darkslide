import Foundation

enum FolderScanner {
    /// Lists image files in `folder` (non-recursive), sorted by name, pairing RAW+JPEG
    /// with the same base name into one item.
    static func scan(_ folder: URL) -> [PhotoItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var byBase: [String: [URL]] = [:]
        var editorDocs = Set<String>()
        for url in entries {
            let ext = url.pathExtension.lowercased()
            if PhotoItem.editorDocExtensions.contains(ext) { editorDocs.insert(url.deletingPathExtension().lastPathComponent); continue }
            guard PhotoItem.imageExtensions.contains(ext) || PhotoItem.videoExtensions.contains(ext) else { continue }
            byBase[url.deletingPathExtension().lastPathComponent, default: []].append(url)
        }

        var items: [PhotoItem] = []
        for (base, urls) in byBase {
            let raws = urls.filter { PhotoItem.rawExtensions.contains($0.pathExtension.lowercased()) }
            let jpegs = urls.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            let affinity = editorDocs.contains(base) && urls.allSatisfy { PhotoItem.rawExtensions.contains($0.pathExtension.lowercased()) }
            if let raw = raws.first {
                // Pair: RAW is primary, the first JPEG is its mate. Anything else (a TIFF
                // saved from the editor, say) is an edit of the RAW.
                var primary = PhotoItem(id: raw, url: raw, sidecarJPEG: jpegs.first, displayName: raw.lastPathComponent)
                primary.affinityOnly = affinity
                items.append(primary)
                for extra in urls where extra != raw && extra != jpegs.first {
                    var e = PhotoItem(id: extra, url: extra, sidecarJPEG: nil, displayName: extra.lastPathComponent)
                    e.editOf = raw
                    items.append(e)
                }
            } else {
                // No RAW: a JPEG is the original (a camera JPEG, a phone, a compact) and any
                // TIFF/PSD/PNG sharing its name is an edit saved beside it.
                let jpegOriginal = jpegs.first
                for u in urls {
                    var e = PhotoItem(id: u, url: u, sidecarJPEG: nil, displayName: u.lastPathComponent)
                    if let j = jpegOriginal, u != j { e.editOf = j }
                    e.affinityOnly = editorDocs.contains(base) && urls.count == 1 && ["jpg", "jpeg"].contains(u.pathExtension.lowercased())
                    items.append(e)
                }
            }
        }
        return items.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
