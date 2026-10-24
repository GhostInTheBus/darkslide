import Foundation

/// Reads and writes the legacy app fields through exiftool. Reads are batched in chunks so a big
/// folder fills in progressively; writes go straight through, one command per keypress.
final class MetadataStore {
    static let shared = MetadataStore()
    private let readQueue = DispatchQueue(label: "meta.read", qos: .utility)
    private var generation = 0

    /// Load metadata for every item. `progress` is called on the main thread with each
    /// chunk of results.
    func loadAll(_ items: [PhotoItem], cancelPrevious: Bool = true, progress: @escaping ([URL: PhotoMeta]) -> Void) {
        if cancelPrevious { generation += 1 }
        let gen = generation
        let urls = items.map(\.url)
        readQueue.async {
            for chunk in stride(from: 0, to: urls.count, by: 64).map({ Array(urls[$0..<min($0 + 64, urls.count)]) }) {
                guard gen == self.generation else { return }
                let r = ExifTool.shared.run(PhotoMeta.readArgs + chunk.map(\.path))
                var out: [URL: PhotoMeta] = [:]
                if let data = r.output.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for obj in arr {
                        guard let src = obj["SourceFile"] as? String else { continue }
                        out[URL(fileURLWithPath: src)] = PhotoMeta(json: obj)
                    }
                }
                DispatchQueue.main.async { if gen == self.generation { progress(out) } }
            }
        }
    }

    /// Re-read a few files without blocking the caller; the result lands on the main queue.
    func reloadAsync(_ urls: [URL], completion: @escaping ([URL: PhotoMeta]) -> Void) {
        ExifTool.shared.runAsync(PhotoMeta.readArgs + urls.map(\.path)) { r in
            var out: [URL: PhotoMeta] = [:]
            if let data = r.output.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for obj in arr { if let src = obj["SourceFile"] as? String { out[URL(fileURLWithPath: src)] = PhotoMeta(json: obj) } }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    func reload(_ urls: [URL]) -> [URL: PhotoMeta] {
        let r = ExifTool.shared.run(PhotoMeta.readArgs + urls.map(\.path))
        var out: [URL: PhotoMeta] = [:]
        if let data = r.output.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in arr {
                guard let src = obj["SourceFile"] as? String else { continue }
                out[URL(fileURLWithPath: src)] = PhotoMeta(json: obj)
            }
        }
        return out
    }

    /// Write IPTC fields through MWG so XMP, IPTC and EXIF stay in step (the legacy app writes all).
    func writeFields(_ fields: [String: String], appendKeywords: Bool, appendCaption: Bool, to files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors", "-use", "MWG", "-IPTC:CodedCharacterSet=UTF8"]
        let map: [String: String] = [
            "caption": "MWG:Description", "headline": "IPTC:Headline", "byline": "MWG:Creator", "credit": "IPTC:Credit",
            "copyright": "MWG:Copyright", "source": "IPTC:Source", "city": "MWG:City", "state": "MWG:State",
            "country": "MWG:Country", "location": "MWG:Location", "event": "XMP-iptcExt:Event", "instructions": "IPTC:SpecialInstructions",
        ]
        // MWG only writes legacy IPTC when the file already has an IPTC record; the legacy app always
        // adds one, so the IPTC tags are written explicitly as well.
        let iptc: [String: String] = [
            "caption": "IPTC:Caption-Abstract", "byline": "IPTC:By-line", "copyright": "IPTC:CopyrightNotice",
            "city": "IPTC:City", "state": "IPTC:Province-State", "country": "IPTC:Country-PrimaryLocationName",
            "location": "IPTC:Sub-location",
        ]
        for (key, value) in fields {
            if key == "keywords" {
                let kws = value.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !appendKeywords { args.append("-MWG:Keywords="); args.append("-IPTC:Keywords=") }
                for k in kws { args.append("-MWG:Keywords+=\(k)"); args.append("-IPTC:Keywords+=\(k)") }
            } else if key == "caption" && appendCaption {
                // The < form interpolates $tag, so a literal "$5" must be "$$5"; -f keeps the write
                // when the file has no caption yet (the string would otherwise be skipped entirely).
                let lit = value.replacingOccurrences(of: "$", with: "$$")
                args.append("-f")
                args.append("-MWG:Description<${MWG:Description} \(lit)")
                args.append("-IPTC:Caption-Abstract<${MWG:Description} \(lit)")
            } else if let tag = map[key] {
                args.append("-\(tag)=\(value)")
                if let legacy = iptc[key] { args.append("-\(legacy)=\(value)") }
            }
        }
        // XMP-dc:Creator and dc:Rights mirror for byline/copyright also land in IPTC via MWG.
        args.append("-XMP-photomech:PMVersion=PM6")
        args += files.map(\.path)
        ExifTool.shared.runAsync(args, completion: completion)
    }

    /// Soft rotation: write the EXIF Orientation tag (what the legacy app does unless you ask for
    /// lossless pixel rotation). Every reader honours it.
    func setOrientation(_ o: Int, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        ExifTool.shared.runAsync(["-overwrite_original_in_place", "-ignoreMinorErrors", "-Orientation#=\(o)"] + files.map(\.path), completion: completion)
    }

    func writeGPS(latitude: Double?, longitude: Double?, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors"]
        if let lat = latitude, let lon = longitude {
            args += ["-GPSLatitude=\(abs(lat))", "-GPSLatitudeRef=\(lat < 0 ? "S" : "N")", "-GPSLongitude=\(abs(lon))", "-GPSLongitudeRef=\(lon < 0 ? "W" : "E")",
                     "-XMP:GPSLatitude=\(lat)", "-XMP:GPSLongitude=\(lon)"]
        } else {
            args += ["-gps:all=", "-XMP-exif:GPS*="]
        }
        ExifTool.shared.runAsync(args + files.map(\.path), completion: completion)
    }

    func deleteMetadata(xmp: Bool, iptc: Bool, exif: Bool, gps: Bool, keepOrientation: Bool, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors"]
        if xmp { args.append("-XMP:all=") }
        if iptc { args.append("-IPTC:all=") }
        if exif { args.append("-EXIF:all="); if keepOrientation { args += ["-tagsFromFile", "@", "-EXIF:Orientation"] } }
        if gps { args += ["-gps:all=", "-XMP-exif:GPS*="] }
        ExifTool.shared.runAsync(args + files.map(\.path), completion: completion)
    }

    /// Crop as Adobe crs fractions; nil removes the crop.
    func writeCrop(_ c: CropRect?, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors"]
        if let c, c.hasCrop {
            args += ["-XMP-crs:HasCrop=True", "-XMP-crs:CropLeft=\(c.left)", "-XMP-crs:CropTop=\(c.top)", "-XMP-crs:CropRight=\(c.right)", "-XMP-crs:CropBottom=\(c.bottom)", "-XMP-crs:CropAngle=0"]
        } else {
            args += ["-XMP-crs:HasCrop=", "-XMP-crs:CropLeft=", "-XMP-crs:CropTop=", "-XMP-crs:CropRight=", "-XMP-crs:CropBottom=", "-XMP-crs:CropAngle="]
        }
        ExifTool.shared.runAsync(args + files.map(\.path), completion: completion)
    }

    func setDPI(_ dpi: Int, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        ExifTool.shared.runAsync(["-overwrite_original_in_place", "-ignoreMinorErrors", "-XResolution=\(dpi)", "-YResolution=\(dpi)", "-ResolutionUnit=inches"] + files.map(\.path), completion: completion)
    }

    /// Clear chosen caption fields (legacy app: Clear IPTC Fields).
    func clearFields(_ keys: Set<String>, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        let tags: [String: [String]] = [
            "caption": ["MWG:Description", "IPTC:Caption-Abstract"], "headline": ["IPTC:Headline", "XMP-photoshop:Headline"],
            "byline": ["MWG:Creator", "IPTC:By-line"], "credit": ["IPTC:Credit", "XMP-photoshop:Credit"], "copyright": ["MWG:Copyright", "IPTC:CopyrightNotice"],
            "source": ["IPTC:Source", "XMP-photoshop:Source"], "city": ["MWG:City", "IPTC:City"], "state": ["MWG:State", "IPTC:Province-State"],
            "country": ["MWG:Country", "IPTC:Country-PrimaryLocationName"], "location": ["MWG:Location", "IPTC:Sub-location"],
            "event": ["XMP-iptcExt:Event"], "keywords": ["MWG:Keywords", "IPTC:Keywords"], "instructions": ["IPTC:SpecialInstructions", "XMP-photoshop:Instructions"],
        ]
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors", "-use", "MWG", "-IPTC:CodedCharacterSet=UTF8"]
        for k in keys { for t in tags[k] ?? [] { args.append("-\(t)=") } }
        ExifTool.shared.runAsync(args + files.map(\.path), completion: completion)
    }

    /// Copy IPTC/XMP descriptive metadata (not EXIF camera data) from one file to another.
    func copyMetadata(from: URL, to: URL, completion: @escaping (ExifTool.Result) -> Void) {
        let args = ["-overwrite_original_in_place", "-ignoreMinorErrors", "-tagsFromFile", from.path,
                    "-IPTC:all", "-XMP-dc:all", "-XMP-photoshop:all", "-XMP-iptcCore:all", "-XMP-iptcExt:all",
                    "-XMP-xmpRights:all", "-XMP-xmp:Rating", "-XMP-xmp:Label", "-XMP-photomech:all", "-XMP-lr:all", to.path]
        ExifTool.shared.runAsync(args, completion: completion)
    }

    /// Shift every date tag (AllDates = DateTimeOriginal, CreateDate, ModifyDate) by seconds.
    func shiftAllDates(seconds: Int, files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        let sign = seconds < 0 ? "-=" : "+="
        let s = abs(seconds)
        let shift = String(format: "0:0:%d %d:%d:%d", s / 86400, (s % 86400) / 3600, (s % 3600) / 60, s % 60)
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors", "-AllDates\(sign)\(shift)", "-XMP-photoshop:DateCreated\(sign)\(shift)", "-IPTC:DateCreated\(sign)\(shift)", "-IPTC:TimeCreated\(sign)\(shift)"]
        args += files.map(\.path)
        ExifTool.shared.runAsync(args, completion: completion)
    }

    /// Write rating / class / tag the way the legacy app does: xmp:Rating, photomechanic:ColorClass,
    /// photomechanic:Tagged, photomechanic:Prefs, IPTC Prefs, plus xmp:Label for Adobe.
    func writeCull(_ meta: PhotoMeta, label: String, to files: [URL], completion: @escaping (ExifTool.Result) -> Void) {
        var args = ["-overwrite_original_in_place", "-ignoreMinorErrors"]
        args.append("-XMP-xmp:Rating=\(meta.rating)")
        args.append("-XMP-photomech:ColorClass=\(meta.colorClass)")
        args.append("-XMP-photomech:Tagged#=\(meta.tagged ? "True" : "False")")
        args.append("-XMP-photomech:Prefs=\(meta.prefsString)")
        args.append("-IPTC:Prefs=\(meta.prefsString)")
        args.append("-XMP-photomech:PMVersion=PM6")
        args.append(meta.colorClass == 0 ? "-XMP-xmp:Label=" : "-XMP-xmp:Label=\(label)")
        args += files.map(\.path)
        ExifTool.shared.runAsync(args, completion: completion)
    }
}
