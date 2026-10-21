import Foundation
import AppKit

// Command-line ingest using the app's engine and settings.json.
// usage: darkslide-ingest <source volume> [--eject]
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: darkslide-ingest <source> [--eject]"); exit(2) }
let source = URL(fileURLWithPath: args[1])
let s = AppSettings.load()
guard !s.ingestPrimary.isEmpty else { print("settings.json has no ingestPrimary"); exit(2) }
let opts = IngestEngine.Options(
    sources: [source], primary: URL(fileURLWithPath: s.ingestPrimary),
    secondary: s.ingestSecondaryEnabled && !s.ingestSecondary.isEmpty ? URL(fileURLWithPath: s.ingestSecondary) : nil,
    folderTemplate: s.ingestFolderTemplate, renameTemplate: s.ingestRename ? s.renameTemplate : nil,
    jobName: s.jobName, startSequence: s.sequence, sequencePadding: s.sequencePadding,
    copyNonImages: s.ingestCopyNonImages, skipMirrorCard: s.ingestSkipMirrorCard, skipAlreadyIngested: true,
    eject: args.contains("--eject"), user: UserInfo.load())
print("source   \(source.path)\nprimary  \(opts.primary.path)\nfolder   \(opts.folderTemplate)\nrename   \(opts.renameTemplate ?? "(keep names)")  seq \(opts.startSequence)")
let engine = IngestEngine()
var final: IngestEngine.Progress?
var lastShown = -1
engine.onProgress = { p in
    if p.done != lastShown && p.done % 25 == 0 { print("  \(p.done)/\(p.total)  \(p.current)"); lastShown = p.done }
    if p.finished { final = p }
}
engine.run(opts) { url in (ImageLoader.captureInfo(for: url), PhotoMeta()) }
while final == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
let f = final!
print("done     \(f.done) copied, \(f.skipped) skipped, \(f.failures.count) failures")
for e in f.failures { print("  FAIL \(e)") }
print("dest     \(f.destinationFolder?.path ?? "none")")
print("next seq \(f.nextSequence)")
var updated = s; updated.sequence = max(s.sequence, f.nextSequence); updated.save()
exit(f.failures.isEmpty ? 0 : 1)
