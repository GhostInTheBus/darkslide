import Foundation

/// Rename with the legacy app variables. Pairs (RAW + JPEG + XMP sidecars) move together; nothing is
/// ever overwritten; the last batch can be undone.
struct RenamePlan {
    struct Entry: Identifiable {
        var id: URL { from }
        let from: URL
        let to: URL
        let collision: Bool
    }
    var entries: [Entry]
    var collisions: Int { entries.filter(\.collision).count }
}

enum RenameEngine {
    /// Every file that must travel with `item`: the primary, its JPEG mate and any sidecar
    /// sharing the base name (.xmp, .wav, .thm…).
    static func companions(of item: PhotoItem) -> [URL] {
        var urls = [item.url]
        if let j = item.sidecarJPEG { urls.append(j) }
        let base = item.url.deletingPathExtension().lastPathComponent
        let dir = item.url.deletingLastPathComponent()
        if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for e in entries where e.deletingPathExtension().lastPathComponent == base && !urls.contains(e) {
                urls.append(e)
            }
        }
        return urls
    }

    /// Build the plan without touching disk. The sequence counter advances per *item*.
    static func plan(items: [PhotoItem], template: String, context base: VariableContext,
                     metaFor: (PhotoItem) -> PhotoMeta?, infoFor: (PhotoItem) -> CaptureInfo?) -> RenamePlan {
        var entries: [RenamePlan.Entry] = []
        var seen = Set<String>()
        var seq = base.sequence
        for item in items {
            var ctx = base
            ctx.item = item; ctx.meta = metaFor(item); ctx.info = infoFor(item); ctx.sequence = seq
            let newBase = sanitize(Variables.expand(template, ctx))
            seq += 1
            for file in companions(of: item) {
                // An empty name would resolve to the parent folder itself; never move anything there.
                let dest = newBase.isEmpty ? file : file.deletingLastPathComponent().appendingPathComponent(newBase).appendingPathExtension(file.pathExtension)
                let key = dest.path.lowercased()
                let exists = FileManager.default.fileExists(atPath: dest.path) && dest.path != file.path
                let collision = newBase.isEmpty || exists || seen.contains(key)
                seen.insert(key)
                entries.append(RenamePlan.Entry(from: file, to: dest, collision: collision))
            }
        }
        return RenamePlan(entries: entries)
    }

    /// Characters that can't live in a filename on macOS or Windows.
    static func sanitize(_ s: String) -> String {
        var out = s
        for c in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] { out = out.replacingOccurrences(of: c, with: "-") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    struct Applied { let moved: [(from: URL, to: URL)]; let failed: [(URL, String)] }

    /// Execute a plan. Collisions are skipped, never overwritten. Returns what moved so it
    /// can be undone.
    static func apply(_ plan: RenamePlan) -> Applied {
        var moved: [(URL, URL)] = []
        var failed: [(URL, String)] = []
        let fm = FileManager.default
        for e in plan.entries where !e.collision && e.from != e.to {
            do {
                guard !e.to.deletingPathExtension().lastPathComponent.isEmpty, e.to.deletingLastPathComponent() == e.from.deletingLastPathComponent() else { failed.append((e.from, "empty name")); continue }
                if fm.fileExists(atPath: e.to.path) { failed.append((e.from, "exists")); continue }
                try fm.moveItem(at: e.from, to: e.to)
                moved.append((e.from, e.to))
            } catch { failed.append((e.from, error.localizedDescription)) }
        }
        return Applied(moved: moved, failed: failed)
    }

    static func undo(_ applied: Applied) -> [String] {
        var errors: [String] = []
        for (from, to) in applied.moved.reversed() {
            do { try FileManager.default.moveItem(at: to, to: from) } catch { errors.append("\(to.lastPathComponent): \(error.localizedDescription)") }
        }
        return errors
    }
}
