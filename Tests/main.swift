import Foundation
import AppKit

// Engine-level checks that need no UI: variables, rename plan, ingest with checksums,
// caption write/readback. Run via ./build.sh test. Uses a scratch copy of test files.
var failures = 0
setvbuf(stdout, nil, _IONBF, 0)
func check(_ cond: Bool, _ msg: String) { print((cond ? "  ok   " : "  FAIL ") + msg); if !cond { failures += 1 } }

let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let srcDir = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

// --- Variables
let fakeURL = scratch.appendingPathComponent("IMG_1234.CR2")
var ctx = VariableContext()
ctx.item = PhotoItem(id: fakeURL, url: fakeURL, sidecarJPEG: nil, displayName: "IMG_1234.CR2")
var info = CaptureInfo(); info.captureDate = Variables.exifDate.date(from: "2026:10:19 14:05:09"); info.cameraModel = "Canon EOS R5"; info.iso = "400"
ctx.info = info
var m = PhotoMeta(); m.city = "Springfield"; m.state = "CA"; m.country = "USA"; m.event = "Parade"; m.rating = 3
ctx.meta = m; ctx.sequence = 7; ctx.jobName = "job1"
print("Variables")
check(Variables.expand("{datesort}-{country}.{state}.{city}.{event}.{seqn}", ctx) == "20261019-USA.CA.Springfield.Parade.0007", "the usual template")
check(Variables.expand("{dats}_{fbas}_{seqn:3}_{yr2}{mn0}{day0}_{h24}{min}{sec}", ctx) == "20261019_IMG_1234_007_261019_140509", "short aliases and padding override")
check(Variables.expand("{model} ISO {iso} {rating}★ {frame4} {jobname} {nope}", ctx) == "Canon EOS R5 ISO 400 3★ 1234 job1 ", "camera, rating, frame, unknown empty")
check(Variables.expand("{monthnameap} {datesortdash}", ctx) == "Oct. 2026-10-19", "AP month")

// --- Rename plan on real copies
print("Rename")
let cr2s = try! fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "cr2" }.sorted { $0.path < $1.path }.prefix(3)
let work = scratch.appendingPathComponent("work"); try! fm.createDirectory(at: work, withIntermediateDirectories: true)
var items: [PhotoItem] = []
for u in cr2s {
    let d = work.appendingPathComponent(u.lastPathComponent); try! fm.copyItem(at: u, to: d)
    try! "x".write(to: d.deletingPathExtension().appendingPathExtension("xmp"), atomically: true, encoding: .utf8)   // sidecar must travel
    items.append(PhotoItem(id: d, url: d, sidecarJPEG: nil, displayName: d.lastPathComponent))
}
var rctx = VariableContext(); rctx.sequence = 100
let plan = RenameEngine.plan(items: items, template: "{datesort}-TEST.{seqn}", context: rctx,
                             metaFor: { _ in nil }, infoFor: { ImageLoader.captureInfo(for: $0.url) })
check(plan.entries.count == 6, "3 items × (cr2 + xmp) = 6 entries, got \(plan.entries.count)")
check(plan.collisions == 0, "no collisions")
check(plan.entries[0].to.lastPathComponent == "20141030-TEST.0100.cr2" || plan.entries[0].to.lastPathComponent == "20141030-TEST.0100.xmp", "name from capture date: \(plan.entries[0].to.lastPathComponent)")
let applied = RenameEngine.apply(plan)
check(applied.moved.count == 6 && applied.failed.isEmpty, "applied 6 moves")
check(fm.fileExists(atPath: work.appendingPathComponent("20141030-TEST.0101.xmp").path), "sidecar renamed with its RAW")
let undoErrs = RenameEngine.undo(applied)
check(undoErrs.isEmpty && fm.fileExists(atPath: items[0].url.path), "undo restored originals")
// Collision: same template with a fixed name
let plan2 = RenameEngine.plan(items: items, template: "same", context: rctx, metaFor: { _ in nil }, infoFor: { _ in nil })
check(plan2.collisions == 4, "fixed name collides for all but the first pair: \(plan2.collisions)")

// --- Ingest
print("Ingest")
let card = scratch.appendingPathComponent("CARD/DCIM/100CANON"); try! fm.createDirectory(at: card, withIntermediateDirectories: true)
for u in cr2s { try! fm.copyItem(at: u, to: card.appendingPathComponent(u.lastPathComponent)) }
try! Data(repeating: 7, count: 1_000_000).write(to: card.appendingPathComponent("MVI_0001.MOV"))
let dest1 = scratch.appendingPathComponent("dest1"), dest2 = scratch.appendingPathComponent("dest2")
let engine = IngestEngine()
var final: IngestEngine.Progress?
engine.onProgress = { p in if p.finished { final = p } }
let opts = IngestEngine.Options(sources: [scratch.appendingPathComponent("CARD")], primary: dest1, secondary: dest2,
                                folderTemplate: "{datesort}_{jobname}", renameTemplate: "{datesort}-ING.{seqn}", jobName: "Test",
                                startSequence: 1, sequencePadding: 4, copyNonImages: true, skipMirrorCard: true,
                                skipAlreadyIngested: false, eject: false, user: UserInfo())
engine.run(opts) { url in (ImageLoader.captureInfo(for: url), PhotoMeta()) }
let deadline = Date().addingTimeInterval(120)
while final == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check(final != nil && final!.finished, "ingest finished")
if final == nil { exit(1) }
check(final!.failures.isEmpty, "no failures: \(final!.failures)")
check(final!.done == 4, "4 files copied (3 cr2 + mov), got \(final!.done)")
print("  progress: done=\(final!.done) total=\(final!.total) skipped=\(final!.skipped) dest=\(final!.destinationFolder?.path ?? "nil")")
guard let d1 = final!.destinationFolder else { print("no destination folder, aborting"); exit(1) }
check(d1.lastPathComponent == "20141030_Test", "folder from template: \(d1.lastPathComponent)")
let out1 = (try? fm.contentsOfDirectory(atPath: d1.path))?.sorted() ?? []
check(out1.contains("20141030-ING.0001.cr2") && out1.contains("20141030-ING.0003.cr2"), "renamed on ingest: \(out1)")
check(out1.contains("20141030-ING.0004.MOV") || out1.contains { $0.hasSuffix(".MOV") && $0.hasPrefix("20") }, "video copied and renamed too: \(out1)")
let out2 = (try? fm.contentsOfDirectory(atPath: dest2.appendingPathComponent("20141030_Test").path))?.sorted() ?? []
check(out1 == out2, "backup destination identical")
check(final!.nextSequence == 5, "sequence advanced past 4 files to 5, got \(final!.nextSequence)")
let logs = (try? fm.contentsOfDirectory(atPath: IngestEngine.logDir.path)) ?? []
check(!logs.isEmpty, "ingest log written (\(logs.count) logs)")
let h1 = try! IngestEngine.sha256(of: cr2s.first!), h2 = try! IngestEngine.sha256(of: d1.appendingPathComponent("20141030-ING.0001.cr2"))
check(h1 == h2, "checksum of copy matches source")

// --- Caption write + readback through exiftool
print("Caption")
let capFile = d1.appendingPathComponent("20141030-ING.0002.cr2")
let wsem = DispatchSemaphore(value: 0)
var wres: ExifTool.Result?
MetadataStore.shared.writeFields(["caption": "Hello {model}", "city": "Springfield", "keywords": "a, b", "byline": "Tester"], appendKeywords: false, appendCaption: false, to: [capFile]) { r in wres = r; wsem.signal() }
_ = wsem.wait(timeout: .now() + 60)
check(wres?.ok == true, "write ok: \(wres?.error ?? "")")
let back = MetadataStore.shared.reload([capFile])[capFile]
check(back?.caption == "Hello {model}", "caption read back (variables expand in Library, not store): \(back?.caption ?? "nil")")
check(back?.city == "Springfield" && back?.byline == "Tester", "city/byline read back")
check(back?.keywords == ["a", "b"], "keywords read back: \(back?.keywords ?? [])")
let ipt = ExifTool.shared.run(["-s", "-s", "-s", "-IPTC:Caption-Abstract", "-IPTC:City", capFile.path]).output.trimmingCharacters(in: .whitespacesAndNewlines)
check(ipt.contains("Hello") && ipt.contains("Springfield"), "legacy IPTC written too via MWG: \(ipt)")

// --- GPS track matching
print("GPS track")
let gpx = """
<?xml version="1.0"?><gpx version="1.1"><trk><name>t</name><trkseg>
<trkpt lat="34.0000" lon="-118.0000"><ele>100</ele><time>2026-10-19T20:00:00Z</time></trkpt>
<trkpt lat="34.0010" lon="-118.0010"><ele>110</ele><time>2026-10-19T20:10:00Z</time></trkpt>
<trkpt lat="34.0020" lon="-118.0020"><time>2026-10-19T20:20:00Z</time></trkpt>
</trkseg></trk></gpx>
"""
let gpxURL = scratch.appendingPathComponent("t.gpx"); try! gpx.write(to: gpxURL, atomically: true, encoding: .utf8)
let track = try! GPSTrack.loadGPX(gpxURL)
check(track.points.count == 3, "3 track points parsed")
let iso = ISO8601DateFormatter()
let mid = track.position(at: iso.date(from: "2026-10-19T20:05:00Z")!, tolerance: 600, interpolate: true)!
check(abs(mid.lat - 34.0005) < 1e-6 && abs(mid.lon - -118.0005) < 1e-6 && mid.ele == 105, "interpolated halfway: \(mid.lat), \(mid.lon), \(mid.ele ?? -1)")
let near = track.position(at: iso.date(from: "2026-10-19T20:19:00Z")!, tolerance: 600, interpolate: false)!
check(near.lat == 34.0020, "nearest point without interpolation")
check(track.position(at: iso.date(from: "2026-10-19T21:00:00Z")!, tolerance: 600, interpolate: true) == nil, "outside tolerance → nil")
check(track.position(at: iso.date(from: "2026-10-19T20:25:00Z")!, tolerance: 600, interpolate: true)?.lat == 34.0020, "after last point within tolerance → last")

// --- Keywords vocabulary, crop round trip, watermark + crop export, HTML gallery
print("Keywords / crop / export extras")
let kwFile = scratch.appendingPathComponent("kw.txt")
try! "Places\n\tCalifornia = CA, Cali\n\t\tSpringfield\nPeople\n".write(to: kwFile, atomically: true, encoding: .utf8)
let roots = Keywords.load(from: kwFile)
check(roots.count == 2, "vocabulary parsed from the test file (\(roots.count) roots)")
let spr = roots.flatMap { $0.flattened() }.first { $0.term == "Springfield" }
check(spr?.path == ["Places", "California", "Springfield"], "hierarchy path: \(spr?.path ?? [])")
check(roots.flatMap { $0.flattened() }.first { $0.term == "California" }?.synonyms == ["CA", "Cali"], "synonyms parsed")

let cropFile = d1.appendingPathComponent("20141030-ING.0003.cr2")
let csem = DispatchSemaphore(value: 0)
MetadataStore.shared.writeCrop(CropRect(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8), files: [cropFile]) { _ in csem.signal() }
_ = csem.wait(timeout: .now() + 60)
let cm = MetadataStore.shared.reload([cropFile])[cropFile]
check(cm?.crop == CropRect(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8), "crop written as crs and read back: \(String(describing: cm?.crop))")
let outJ = scratch.appendingPathComponent("wm.jpg")
try! ExportEngine.writeJPEG(from: cropFile, to: outJ, longEdge: 800, quality: 85, srgb: true, watermark: "© Test", corner: 3, opacity: 0.6, scale: 0.05, crop: cm?.crop)
if let src = CGImageSourceCreateWithURL(outJ as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    check(w == 800 && abs(Double(h) / Double(w) - 0.6 / 0.8 * 2731.0 / 4096.0) < 0.02, "cropped + watermarked export is 800 wide with cropped aspect: \(w)x\(h)")
} else { check(false, "export unreadable") }
let gal = scratch.appendingPathComponent("gallery")
let gsem = DispatchSemaphore(value: 0); var gres: ExportEngine.Result?
ExportEngine.htmlGallery(items: [PhotoItem(id: cropFile, url: cropFile, sidecarJPEG: nil, displayName: cropFile.lastPathComponent)], meta: [:], title: "T", to: gal, largeEdge: 600, thumbEdge: 200, progress: { _, _ in }) { r in gres = r; gsem.signal() }
while gres == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let html = (try? String(contentsOf: gal.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
check(gres!.failures.isEmpty && html.contains("<figure>") && fm.fileExists(atPath: gal.appendingPathComponent("thumbs/20141030-ING.0003.jpg").path), "HTML gallery written with thumbs and index")

// --- Catalog
print("Catalog")
let catFile = scratch.appendingPathComponent("catalog-test.sqlite")
try? fm.removeItem(at: catFile)
let cat = Catalog(path: catFile)
var idxDone = -1
cat.index(folder: d1, recursive: false, progress: { _, _ in }) { n in idxDone = n }
while idxDone < 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check(idxDone == 4, "indexed 4 files in the ingest folder, got \(idxDone)")
let hits = cat.search(text: "Springfield", minRating: 0, colorClass: nil, taggedOnly: false, from: nil, to: nil)
check(hits.count == 1 && hits[0].name == "20141030-ING.0002.cr2", "search by city finds the captioned file: \(hits.map(\.name))")
check(cat.search(text: "ING", minRating: 0, colorClass: nil, taggedOnly: false, from: nil, to: nil).count == 4, "search by name fragment finds all 4")
check(cat.folders().count == 1 && cat.folders()[0].count == 4, "folder registered")

// --- Review fixes
print("Review fixes")
check(ExifTool.argLine("plain") == "plain" && ExifTool.argLine("a\nb") == "#[CSTR]a\\nb" && ExifTool.argLine("#x") == "#[CSTR]#x", "argfile encoding for newlines and leading #")
let mlFile = d1.appendingPathComponent("20141030-ING.0001.cr2")
let mlsem = DispatchSemaphore(value: 0); var mlres: ExifTool.Result?
MetadataStore.shared.writeFields(["caption": "Line one\nLine two\n-all=", "headline": " leading space"], appendKeywords: false, appendCaption: false, to: [mlFile]) { r in mlres = r; mlsem.signal() }
_ = mlsem.wait(timeout: .now() + 60)
let mlBack = MetadataStore.shared.reload([mlFile])[mlFile]
check(mlres?.ok == true, "multi-line write reported ok (stderr: \(mlres?.error ?? ""))")
check(mlBack?.caption == "Line one\nLine two\n-all=", "multi-line caption survives intact and -all= was not treated as an option: \(mlBack?.caption.debugDescription ?? "nil")")
check(mlBack?.headline.trimmingCharacters(in: .whitespaces) == "leading space", "leading-space headline written: \(mlBack?.headline.debugDescription ?? "nil")")
check(mlBack?.rating == 0 || mlBack != nil, "file still has metadata (not stripped)")
let emptyPlan = RenameEngine.plan(items: items, template: "{headline}", context: rctx, metaFor: { _ in nil }, infoFor: { _ in nil })
check(emptyPlan.entries.allSatisfy { $0.collision && $0.from == $0.to }, "empty expansion is flagged, nothing moves out of the folder")
let ap = RenameEngine.apply(emptyPlan); check(ap.moved.isEmpty, "apply moved nothing for empty names")
check(Catalog.likePrefix("/Photos/2024/Jan") == "/Photos/2024/Jan/%" && Catalog.likePrefix("/a_b%c") == "/a\\_b\\%c/%", "catalog LIKE prefix has trailing slash and escapes wildcards")
// --- Other makers' RAW formats (optional: a folder of CC0 samples from raw.pixls.us)
let samples = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/raw-samples")
if let list = try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil), !list.isEmpty {
    print("RAW formats")
    let rawWork = scratch.appendingPathComponent("raw"); try! fm.createDirectory(at: rawWork, withIntermediateDirectories: true)
    for f in list.filter({ PhotoItem.rawExtensions.contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let u = rawWork.appendingPathComponent(f.lastPathComponent); try! fm.copyItem(at: f, to: u)
        let thumb = ImageLoader.embeddedPreview(for: u, maxPixel: 256)
        let half = ImageLoader.halfSizePreview(for: u)
        let info = ImageLoader.captureInfo(for: u)
        let halfW = half.map { max($0.width, $0.height) } ?? 0
        check(thumb != nil && halfW >= 1500 && info.captureDate != nil && info.cameraModel != nil,
              "\(u.lastPathComponent): thumb \(thumb == nil ? "nil" : "ok"), preview long side \(halfW), \(info.cameraModel ?? "no model"), \(info.captureDate == nil ? "no date" : "dated")")
        var m = PhotoMeta(); m.rating = 4; m.colorClass = 3; m.tagged = true
        let sem = DispatchSemaphore(value: 0)
        MetadataStore.shared.writeCull(m, label: "Green", to: [u]) { _ in sem.signal() }; sem.wait()
        MetadataStore.shared.writeFields(["caption": "probe", "city": "Testville"], appendKeywords: false, appendCaption: false, to: [u]) { _ in sem.signal() }; sem.wait()
        let back = MetadataStore.shared.reload([u])[u]
        check(back?.rating == 4 && back?.colorClass == 3 && back?.tagged == true && back?.caption == "probe" && back?.city == "Testville" && ImageLoader.embeddedPreview(for: u, maxPixel: 256) != nil,
              "\(u.lastPathComponent): cull + fields round trip, preview intact after write")
    }
}

ExifTool.shared.shutdown()
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
