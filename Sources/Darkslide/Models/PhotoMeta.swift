import Foundation

/// What we read from and write to the file: the legacy app's rating/class/tag triple plus the IPTC
/// fields the caption panel edits.
struct PhotoMeta: Equatable {
    var crop: CropRect? = nil
    var rating = 0                 // 0…5
    var colorClass = 0             // 0 = none, 1…8
    var tagged = false
    var frameNum: String = ""      // 4th part of photomechanic:Prefs, kept as the legacy app wrote it

    var caption = ""
    var headline = ""
    var byline = ""
    var credit = ""
    var copyright = ""
    var source = ""
    var city = ""
    var state = ""
    var country = ""
    var location = ""
    var event = ""
    var keywords: [String] = []
    var instructions = ""
    var captureDate: String = ""   // "yyyy:MM:dd HH:mm:ss" as exiftool prints it

    func field(_ key: String) -> String {
        switch key {
        case "caption": return caption
        case "headline": return headline
        case "byline": return byline
        case "credit": return credit
        case "copyright": return copyright
        case "source": return source
        case "city": return city
        case "state": return state
        case "country": return country
        case "location": return location
        case "event": return event
        case "keywords": return keywords.joined(separator: ", ")
        case "instructions": return instructions
        default: return ""
        }
    }

    /// photomechanic:Prefs = "Tagged:ColorClass:Rating:FrameNum"
    var prefsString: String { "\(tagged ? 1 : 0):\(colorClass):\(rating):\(frameNum)" }

    static func parsePrefs(_ s: String) -> (tagged: Bool, colorClass: Int, rating: Int, frame: String)? {
        let p = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, let t = Int(p[0]), let c = Int(p[1]), let r = Int(p[2]) else { return nil }
        return (t != 0, c, r, p[3])
    }

    /// Build from exiftool -j output for one file.
    init(json: [String: Any]) {
        func str(_ k: String) -> String {
            if let s = json[k] as? String { return s }
            if let n = json[k] as? NSNumber { return n.stringValue }
            if let a = json[k] as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
            return ""
        }
        func int(_ k: String) -> Int { Int(str(k).split(separator: " ").first.map(String.init) ?? "") ?? 0 }
        rating = int("Rating")
        colorClass = min(max(int("ColorClass"), 0), 8)
        tagged = ["true", "yes", "1"].contains(str("Tagged").lowercased())
        if let p = PhotoMeta.parsePrefs(str("Prefs")) {
            frameNum = p.frame
            // Prefs is the legacy app's authoritative copy; prefer it when the discrete tags are absent.
            if json["Rating"] == nil { rating = p.rating }
            if json["ColorClass"] == nil { colorClass = p.colorClass }
            if json["Tagged"] == nil { tagged = p.tagged }
        }
        caption = str("Description")
        headline = str("Headline")
        byline = str("Creator")
        credit = str("Credit")
        copyright = str("Rights")
        source = str("Source")
        city = str("City")
        state = str("State")
        country = str("Country")
        location = str("Location")
        event = str("Event")
        if let k = json["Keywords"] as? [Any] { keywords = k.map { "\($0)" } }
        else if let k = json["Keywords"] as? String, !k.isEmpty { keywords = [k] }
        instructions = str("Instructions")
        captureDate = str("DateTimeOriginal")
        if ["true", "1", "yes"].contains(str("HasCrop").lowercased()) {
            crop = CropRect(left: Double(str("CropLeft")) ?? 0, top: Double(str("CropTop")) ?? 0, right: Double(str("CropRight")) ?? 1, bottom: Double(str("CropBottom")) ?? 1)
        }
    }
    init() {}

    /// The exiftool read arguments that `init(json:)` understands. MWG merges XMP, IPTC
    /// and EXIF the way the legacy app and Adobe do.
    static let readArgs: [String] = [
        "-j", "-n", "-fast2", "-use", "MWG",
        "-XMP-xmp:Rating", "-XMP-xmp:Label", "-XMP-photomech:ColorClass", "-XMP-photomech:Tagged",
        "-XMP-photomech:Prefs", "-MWG:Description", "-Headline", "-MWG:Creator", "-Credit",
        "-MWG:Rights", "-Source", "-MWG:City", "-MWG:State", "-MWG:Country", "-MWG:Location",
        "-XMP-iptcExt:Event", "-MWG:Keywords", "-Instructions", "-EXIF:DateTimeOriginal",
        "-XMP-crs:HasCrop", "-XMP-crs:CropLeft", "-XMP-crs:CropTop", "-XMP-crs:CropRight", "-XMP-crs:CropBottom",
    ]
}

/// Color class names and colors. Plain color names, which is also what Adobe's xmp:Label understands.
struct ColorClassSet: Codable {
    var names: [String] = ["Red", "Yellow", "Green", "Blue", "Purple", "Cyan", "Brown", "Trash"]
    var hexColors: [String] = ["#E5484D", "#F5D90A", "#46A758", "#3E63DD", "#8E4EC6", "#05A2C2", "#AD7F58", "#6F6F6F"]

    func name(_ i: Int) -> String { (1...8).contains(i) && names.count >= i ? names[i - 1] : "" }
    func hex(_ i: Int) -> String { (1...8).contains(i) && hexColors.count >= i ? hexColors[i - 1] : "#888888" }
}
