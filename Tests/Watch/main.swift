import Foundation
import AppKit
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ c: Bool, _ m: String) { print((c ? "  ok   " : "  FAIL ") + m); if !c { failures += 1 } }
let src = URL(fileURLWithPath: CommandLine.arguments[1])
let work = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
try? fm.removeItem(at: work); try! fm.createDirectory(at: work, withIntermediateDirectories: true)
let srcFiles = try! fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "cr2" }.sorted { $0.path < $1.path }
for u in srcFiles.prefix(8) { try! fm.copyItem(at: u, to: work.appendingPathComponent(u.lastPathComponent)) }
UserDefaults.standard.removeObject(forKey: "lastFolder")

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
func ext(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool"); p.arguments = ["-overwrite_original", "-q"] + args; try! p.run(); p.waitUntilExit() }

@MainActor func run() async {
    let lib = Library()
    lib.open(work)
    for _ in 0..<100 { await sleep(0.1); if lib.items.count == 8 && lib.metaLoaded >= 8 { break } }
    check(lib.items.count == 8 && lib.metaLoaded >= 8, "opened 8 items, metadata loaded \(lib.metaLoaded)")
    let a = lib.items[0].url, b = lib.items[1].url, c = lib.items[2].url
    lib.currentIndex = 2; lib.selection = [c]
    _ = ThumbnailCache.shared.cached(a)   // nothing cached yet, that's fine

    print("A. another app writes a rating")
    ext(["-XMP-xmp:Rating=4", "-XMP-photomech:ColorClass=3", a.path])
    for _ in 0..<60 { await sleep(0.1); if lib.meta[a]?.rating == 4 { break } }
    check(lib.meta[a]?.rating == 4 && lib.meta[a]?.colorClass == 3, "rating/class from disk picked up: \(lib.meta[a]?.rating ?? -1)/\(lib.meta[a]?.colorClass ?? -1)")
    check(lib.currentIndex == 2 && lib.selection == [c], "current and selection survive a rescan")

    print("B. new file appears")
    let newURL = work.appendingPathComponent("zz_new.cr2"); try! fm.copyItem(at: srcFiles[9], to: newURL)
    ext(["-XMP-xmp:Rating=2", newURL.path])
    for _ in 0..<60 { await sleep(0.1); if lib.meta[newURL]?.rating == 2 { break } }
    check(lib.items.count == 9 && lib.meta[newURL]?.rating == 2, "new file listed with its metadata (\(lib.items.count) items)")
    check(lib.currentIndex == 2 && lib.items[2].url == c, "current frame unchanged")

    print("C. current file renamed externally")
    let moved = work.appendingPathComponent("aa_renamed.cr2"); try! fm.moveItem(at: c, to: moved)
    for _ in 0..<60 { await sleep(0.1); if lib.meta[moved] != nil { break } }
    check(lib.items.contains { $0.url == moved } && !lib.items.contains { $0.url == c }, "renamed file re-listed under its new name")
    check(lib.currentIndex != nil && lib.currentIndex! < lib.items.count, "current index still valid: \(String(describing: lib.currentIndex))")
    check(!lib.selection.contains(c), "stale selection dropped")

    print("D. file removed externally")
    let gone = work.appendingPathComponent("gone"); try! fm.createDirectory(at: gone, withIntermediateDirectories: true)
    try! fm.moveItem(at: b, to: gone.appendingPathComponent(b.lastPathComponent))
    for _ in 0..<60 { await sleep(0.1); if !lib.items.contains(where: { $0.url == b }) { break } }
    check(!lib.items.contains { $0.url == b } && lib.items.count == 8, "removed file gone from the list (\(lib.items.count))")

    print("E. our own write then watcher rescan must not revert it")
    lib.currentIndex = 0; lib.selection = []
    let target = lib.items[0].url
    lib.setRating(5)
    for _ in 0..<60 { await sleep(0.1); if lib.meta[target]?.rating == 5 { break } }
    await sleep(3)   // let the watcher's coalesced rescan + reload run
    check(lib.meta[target]?.rating == 5, "rating 5 still there after rescan: \(lib.meta[target]?.rating ?? -1)")

    print("F. burst of 20 external writes")
    let t0 = Date()
    for i in 1...20 { ext(["-XMP-xmp:Rating=\(i % 5 + 1)", lib.items[i % lib.items.count].url.path]) }
    await sleep(4)
    let expectLast = 20 % 5 + 1
    let lastURL = lib.items[20 % lib.items.count].url
    check(lib.meta[lastURL]?.rating == expectLast, "last write of the burst visible (\(lib.meta[lastURL]?.rating ?? -1) vs \(expectLast)) in \(Int(Date().timeIntervalSince(t0)))s")

    print("G. thumbnail evicted when a file is rewritten")
    let url = lib.items[1].url
    let img = await withCheckedContinuation { k in ThumbnailCache.shared.request(url) { k.resume(returning: $0) } }
    check(img != nil && ThumbnailCache.shared.cached(url) != nil, "thumbnail cached")
    ext(["-XMP-xmp:Rating=1", url.path])
    await sleep(3)
    check(ThumbnailCache.shared.cached(url) == nil, "thumbnail dropped after the file changed on disk")

    ExifTool.shared.shutdown()
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await run() }
RunLoop.main.run()
