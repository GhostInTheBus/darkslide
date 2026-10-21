import Foundation

/// Everything the legacy app keeps in its prefs that we need, as one JSON file in Application
/// Support. Hand-editable, syncable, no binary plist.
struct AppSettings: Codable {
    // Rename
    var renameTemplate = "{datesort}-{seqn}"
    var savedRenameTemplates: [String: String] = [:]       // name → template
    var sequence = 1
    var sequencePadding = 4
    var namedCounters: [String: Int] = [:]
    // Ingest
    var ingestPrimary: String = ""                           // folder path
    var ingestSecondary: String = ""
    var ingestSecondaryEnabled = false
    var ingestFolderTemplate = "{datesort}_{jobname}"
    var ingestRename = true
    var ingestApplyTemplate: String = ""                     // name of saved IPTC template, "" = none
    var ingestEject = false
    var ingestCopyNonImages = true
    var ingestSkipMirrorCard = true
    var ingestOpenWhenDone = true
    var jobName = ""
    // Export / editor
    var editorApp: String = ""                               // path to .app
    var exportPresets: [ExportPreset] = ExportPreset.defaults
    var lastExportFolder = ""
    // Caption
    var captionTemplates: [String: IPTCTemplate] = [:]       // name → template
    var lastCaptionTemplate = ""
    var locationPresets: [LocationPreset] = []
    var colorClasses = ColorClassSet()
    var uploadConnections: [UploadConnection] = []
    var savedSearches: [String: String] = [:]      // name → catalog search text
    // Code replacements: \code\ expands to its text in caption fields, like the legacy app.
    var codeReplacementDelimiter = "\\"
    var codeReplacementsEnabled = true
    // Which caption fields the Stationery Pad shows (legacy app: Customize IPTC Info).
    var hiddenCaptionFields: Set<String> = []
    // Preview info overlay template (legacy app: Info variable string).
    var infoTemplate = "{filename}\n{date} {time}\n{model}  {lens}\n{shutter}  {fstop}  ISO {iso}  {focallength}\n{latitude} {longitude}"
    // Local LLM (Ollama) for caption and keyword suggestions.
    var ollamaURL = "http://localhost:11434"
    var ollamaModel = "qwen3.8:27b-q8_0"

    static let file = AppPaths.support.appendingPathComponent("settings.json")

    init() {}

    /// Tolerant decoding: a hand-edited or older settings.json may lack keys; every
    /// missing key keeps its default instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? def }
        renameTemplate = get(.renameTemplate, renameTemplate)
        savedRenameTemplates = get(.savedRenameTemplates, savedRenameTemplates)
        sequence = get(.sequence, sequence)
        sequencePadding = get(.sequencePadding, sequencePadding)
        namedCounters = get(.namedCounters, namedCounters)
        ingestPrimary = get(.ingestPrimary, ingestPrimary)
        ingestSecondary = get(.ingestSecondary, ingestSecondary)
        ingestSecondaryEnabled = get(.ingestSecondaryEnabled, ingestSecondaryEnabled)
        ingestFolderTemplate = get(.ingestFolderTemplate, ingestFolderTemplate)
        ingestRename = get(.ingestRename, ingestRename)
        ingestApplyTemplate = get(.ingestApplyTemplate, ingestApplyTemplate)
        ingestEject = get(.ingestEject, ingestEject)
        ingestCopyNonImages = get(.ingestCopyNonImages, ingestCopyNonImages)
        ingestSkipMirrorCard = get(.ingestSkipMirrorCard, ingestSkipMirrorCard)
        ingestOpenWhenDone = get(.ingestOpenWhenDone, ingestOpenWhenDone)
        jobName = get(.jobName, jobName)
        editorApp = get(.editorApp, editorApp)
        exportPresets = get(.exportPresets, exportPresets)
        lastExportFolder = get(.lastExportFolder, lastExportFolder)
        captionTemplates = get(.captionTemplates, captionTemplates)
        lastCaptionTemplate = get(.lastCaptionTemplate, lastCaptionTemplate)
        locationPresets = get(.locationPresets, locationPresets)
        colorClasses = get(.colorClasses, colorClasses)
        codeReplacementDelimiter = get(.codeReplacementDelimiter, codeReplacementDelimiter)
        codeReplacementsEnabled = get(.codeReplacementsEnabled, codeReplacementsEnabled)
        hiddenCaptionFields = get(.hiddenCaptionFields, hiddenCaptionFields)
        infoTemplate = get(.infoTemplate, infoTemplate)
        ollamaURL = get(.ollamaURL, ollamaURL)
        ollamaModel = get(.ollamaModel, ollamaModel)
        uploadConnections = get(.uploadConnections, uploadConnections)
        savedSearches = get(.savedSearches, savedSearches)
    }

    static func load() -> AppSettings {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(AppSettings.self, from: d) { return s }
        return AppSettings()
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: AppSettings.file) }
    }
}

struct LocationPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var city = "", state = "", country = "", countryCode = "", location = ""
}

/// A caption template: field values plus which fields to apply. Mirrors the legacy app's Stationery
/// Pad with its per-field checkboxes.
struct IPTCTemplate: Codable, Equatable {
    var fields: [String: String] = [:]      // field key → value (may contain {variables})
    var apply: Set<String> = []             // field keys to apply
    var keywordsAppend = true               // append keywords instead of replacing
    var captionAppend = false

    static let fieldKeys = ["caption", "headline", "byline", "credit", "copyright", "source", "city", "state", "country",
                            "location", "event", "keywords", "instructions"]
    static let fieldLabels: [String: String] = [
        "caption": "Caption", "headline": "Headline", "byline": "Byline / Creator", "credit": "Credit", "copyright": "Copyright",
        "source": "Source", "city": "City", "state": "State / Province", "country": "Country", "location": "Location",
        "event": "Event", "keywords": "Keywords", "instructions": "Instructions",
    ]

    static func from(meta: PhotoMeta) -> IPTCTemplate {
        var t = IPTCTemplate()
        t.fields = ["caption": meta.caption, "headline": meta.headline, "byline": meta.byline, "credit": meta.credit,
                    "copyright": meta.copyright, "source": meta.source, "city": meta.city, "state": meta.state,
                    "country": meta.country, "location": meta.location, "event": meta.event,
                    "keywords": meta.keywords.joined(separator: ", "), "instructions": meta.instructions]
        t.apply = Set(t.fields.filter { !$0.value.isEmpty }.keys)
        return t
    }
}

struct ExportPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var longEdge: Int           // 0 = original size
    var quality: Int            // JPEG 1…100
    var stripGPS = false
    var stripAllMetadata = false
    var copyrightStamp = false  // ensure copyright/creator present in output
    var convertToSRGB = true
    var suffix = ""
    var watermarkText = ""           // e.g. © {username}; variables allowed
    var watermarkCorner = 3           // 0 TL, 1 TR, 2 BL, 3 BR, 4 centre
    var watermarkOpacity = 0.6
    var watermarkScale = 0.03         // text height as a fraction of the long edge

    static let defaults: [ExportPreset] = [
        ExportPreset(name: "Instagram", longEdge: 2048, quality: 90, stripGPS: true, suffix: "_ig"),
        ExportPreset(name: "Web", longEdge: 1600, quality: 85, stripGPS: true, suffix: "_web"),
        ExportPreset(name: "Print", longEdge: 0, quality: 100, suffix: "_print"),
        ExportPreset(name: "Editor copy", longEdge: 0, quality: 100),
    ]
}
