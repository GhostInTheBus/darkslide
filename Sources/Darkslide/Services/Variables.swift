import Foundation

/// the legacy app variable expansion: `{datesort}`, `{seqn}`, `{city}` and friends, with
/// the legacy app's short aliases ({dats}, {fbas}…). Everything the legacy app lists is accepted; unknown names
/// expand to nothing rather than erroring, matching the legacy app.
struct VariableContext {
    var item: PhotoItem?
    var info: CaptureInfo?
    var meta: PhotoMeta?
    var sequence: Int = 1
    var sequencePadding: Int = 4
    var ingestSequence: Int = 1
    var jobName: String = ""
    var user: UserInfo = UserInfo.load()
    var now = Date()
    var colorClassName: (Int) -> String = { _ in "" }

    var captureDate: Date? {
        if let m = meta, let d = Variables.exifDate.date(from: m.captureDate) { return d }
        if let d = info?.captureDate { return d }
        if let u = item?.url, let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
           let c = attrs[.creationDate] as? Date { return c }
        return nil
    }
}

/// {username}, {usercompany}… from Preferences, same slots the legacy app offers.
struct UserInfo: Codable {
    var name = "", company = "", address = "", address2 = "", city = "", state = "", zip = "", country = ""
    var phone = "", mobile = "", web = "", email = "", custom1 = "", custom2 = "", custom3 = ""
    static let file = AppPaths.support.appendingPathComponent("user.json")
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        name = get(.name); company = get(.company); address = get(.address); address2 = get(.address2); city = get(.city)
        state = get(.state); zip = get(.zip); country = get(.country); phone = get(.phone); mobile = get(.mobile)
        web = get(.web); email = get(.email); custom1 = get(.custom1); custom2 = get(.custom2); custom3 = get(.custom3)
    }
    static func load() -> UserInfo {
        if let d = try? Data(contentsOf: file), let u = try? JSONDecoder().decode(UserInfo.self, from: d) { return u }
        return UserInfo()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: UserInfo.file) } }
}

enum Variables {
    static let exifDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f
    }()

    /// the legacy app short aliases → long names (from the legacy app binary's own table).
    static let aliases: [String: String] = [
        "shot": "date", "datm": "datemil", "dats": "datesort", "dtsd": "datesortdash", "hr0": "hour0", "h24": "hour24",
        "min": "minute", "mdat": "moddate", "mtim": "modtime", "mdts": "moddatesort", "mtms": "modtimesort", "mn": "month",
        "mn0": "month0", "mnn": "monthname", "mnn3": "monthname3", "mnap": "monthnameap", "sec": "second", "ssec": "subsecond",
        "tims": "timesort", "tmsd": "timesortdash", "tmsl": "timesortlong", "tday": "today", "tdy": "todayday", "tdy0": "todayday0",
        "tdow": "todaydow", "tdw3": "todaydow3", "tmn": "todaymonth", "tmn0": "todaymonth0", "tmnn": "todaymonthname",
        "tmn3": "todaymonthname3", "tmap": "todaymonthnameap", "tdys": "todaysort", "tyr2": "todayyear2", "tyr4": "todayyear4",
        "yr2": "year2", "yr4": "year4", "seqn": "sequence", "auto": "sequence", "iseq": "ingestseq",
        "file": "filename", "fbas": "filenamebase", "fldr": "folder", "fldn": "foldernum", "fpth": "folderpath", "pfpt": "parentfolderpath",
        "fnum": "frame", "fnm4": "frame4", "size": "filesize", "byte": "bytes", "ext": "extension",
        "modl": "model", "snum": "serialnum", "serial": "serialnum", "f": "aperture", "ss": "shutter", "lt": "lenstype",
        "w": "width", "x": "width", "h": "height", "y": "height", "pxls": "pixels", "stars": "rating", "rate": "rating",
        "color": "colorclass", "colr": "colorclass", "clrv": "colorclassval", "colorval": "colorclassval",
        "capt": "caption", "head": "headline", "name": "byline", "cred": "credit", "copy": "copyright", "srce": "source",
        "cty": "city", "stat": "state", "cnty": "country", "ccod": "countrycode", "loc": "location", "evnt": "event",
        "keyw": "keywords", "inst": "instructions", "cwrt": "captionwriter", "objt": "object", "titl": "title", "tref": "transref",
        "job": "jobname", "urna": "username", "urco": "usercompany", "ura1": "useraddress", "ura2": "useraddress2", "urcy": "usercity",
        "urst": "userstate", "urzp": "userzip", "urcn": "usercountry", "urph": "userphone", "urmb": "usermobile", "urwb": "userweb",
        "urem": "useremail", "urc1": "usercustom1", "urc2": "usercustom2", "urc3": "usercustom3",
        "glat": "latitude", "glon": "longitude", "firm": "firmware", "comp": "exposurecomp", "fcmp": "flashcomp",
        "prgm": "program", "fmod": "focusmode", "baln": "whitebalance", "icc": "iccprofile", "tone": "tonecomp",
        "shrp": "sharpness", "qlty": "quality", "flsh": "flash", "rot": "rotation",
    ]

    static let token = try! NSRegularExpression(pattern: #"\{([a-zA-Z0-9]+)(?::([^}]*))?\}"#)

    /// Expand every `{var}` in `template`. `{seqn:3}` style padding overrides are accepted.
    static func expand(_ template: String, _ ctx: VariableContext) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in token.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let raw = ns.substring(with: m.range(at: 1)).lowercased()
            let arg = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            let name = aliases[raw] ?? raw
            out += value(name, arg, ctx)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func value(_ name: String, _ arg: String?, _ ctx: VariableContext) -> String {
        let cal = Calendar.current
        let d = ctx.captureDate
        let now = ctx.now
        func fmt(_ date: Date?, _ pattern: String) -> String {
            guard let date else { return "" }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern
            return f.string(from: date)
        }
        func pad(_ n: Int, _ width: Int) -> String { String(format: "%0\(width)d", n) }
        let meta = ctx.meta ?? PhotoMeta()
        let info = ctx.info ?? CaptureInfo()
        let url = ctx.item?.url

        switch name {
        // Dates and times (capture)
        case "date": return fmt(d, "MM/dd/yyyy")
        case "datesort": return fmt(d, "yyyyMMdd")
        case "datesortdash": return fmt(d, "yyyy-MM-dd")
        case "datemil": return fmt(d, "ddMMMyyyy").uppercased()
        case "year4": return fmt(d, "yyyy")
        case "year2": return fmt(d, "yy")
        case "month": return fmt(d, "M")
        case "month0": return fmt(d, "MM")
        case "monthname": return fmt(d, "MMMM")
        case "monthname3": return fmt(d, "MMM")
        case "monthnameap": return apMonth(d)
        case "day": return fmt(d, "d")
        case "day0": return fmt(d, "dd")
        case "dow": return fmt(d, "EEEE")
        case "dow3": return fmt(d, "EEE")
        case "hour": return fmt(d, "h")
        case "hour0": return fmt(d, "hh")
        case "hour24": return fmt(d, "HH")
        case "minute": return fmt(d, "mm")
        case "second": return fmt(d, "ss")
        case "subsecond": return fmt(d, "SSS")
        case "ampm": return fmt(d, "a")
        case "time": return fmt(d, "h:mm:ss a")
        case "timesort": return fmt(d, "HHmmss")
        case "timesortdash": return fmt(d, "HH-mm-ss")
        case "timesortlong": return fmt(d, "HHmmssSSS")
        // Dates and times (now)
        case "today": return fmt(now, "MM/dd/yyyy")
        case "todaysort": return fmt(now, "yyyyMMdd")
        case "todaymil": return fmt(now, "ddMMMyyyy").uppercased()
        case "todayyear4": return fmt(now, "yyyy")
        case "todayyear2": return fmt(now, "yy")
        case "todaymonth": return fmt(now, "M")
        case "todaymonth0": return fmt(now, "MM")
        case "todaymonthname": return fmt(now, "MMMM")
        case "todaymonthname3": return fmt(now, "MMM")
        case "todaymonthnameap": return apMonth(now)
        case "todayday": return fmt(now, "d")
        case "todayday0": return fmt(now, "dd")
        case "todaydow": return fmt(now, "EEEE")
        case "todaydow3": return fmt(now, "EEE")
        case "tomorrow": return fmt(cal.date(byAdding: .day, value: 1, to: now), "MM/dd/yyyy")
        case "yesterday": return fmt(cal.date(byAdding: .day, value: -1, to: now), "MM/dd/yyyy")
        case "nowhour": return fmt(now, "h")
        case "nowhour0": return fmt(now, "hh")
        case "nowhour24": return fmt(now, "HH")
        case "nowminute": return fmt(now, "mm")
        case "nowsecond": return fmt(now, "ss")
        case "nowampm": return fmt(now, "a")
        case "nowsort": return fmt(now, "HHmmss")
        case "nowsortlong": return fmt(now, "HHmmssSSS")
        // File
        case "filename": return url?.lastPathComponent ?? ""
        case "filenamebase": return url?.deletingPathExtension().lastPathComponent ?? ""
        case "extension": return url?.pathExtension ?? ""
        case "folder": return url?.deletingLastPathComponent().lastPathComponent ?? ""
        case "folderpath": return url?.deletingLastPathComponent().path ?? ""
        case "parentfolderpath": return url?.deletingLastPathComponent().deletingLastPathComponent().path ?? ""
        case "frame": return trailingDigits(url, pad: 0)
        case "frame4": return trailingDigits(url, pad: 4)
        case "filesize", "bytes":
            guard let u = url, let a = try? FileManager.default.attributesOfItem(atPath: u.path), let n = a[.size] as? Int else { return "" }
            return name == "bytes" ? "\(n)" : ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
        // Sequence
        case "sequence": return pad(ctx.sequence, Int(arg ?? "") ?? ctx.sequencePadding)
        case "ingestseq": return pad(ctx.ingestSequence, Int(arg ?? "") ?? ctx.sequencePadding)
        // Camera and exposure
        case "make": return info.cameraMake ?? ""
        case "model": return info.cameraModel ?? ""
        case "serialnum": return info.serial ?? ""
        case "lens": return info.lens ?? ""
        case "lenstype": return info.lens ?? ""
        case "iso": return info.iso ?? ""
        case "aperture": return info.aperture?.replacingOccurrences(of: "f/", with: "") ?? ""
        case "fstop": return info.aperture ?? ""
        case "shutter": return info.shutter ?? ""
        case "focallength": return info.focalLength ?? ""
        case "width": return info.pixelWidth.map(String.init) ?? ""
        case "height": return info.pixelHeight.map(String.init) ?? ""
        case "pixels": if let w = info.pixelWidth, let h = info.pixelHeight { return "\(w)x\(h)" } else { return "" }
        case "latitude": return info.latitude.map { String(format: "%.6f", $0) } ?? ""
        case "longitude": return info.longitude.map { String(format: "%.6f", $0) } ?? ""
        case "firmware": return info.firmware ?? ""
        case "exposurecomp": return info.exposureComp ?? ""
        case "program": return info.program ?? ""
        case "whitebalance": return info.whiteBalance ?? ""
        case "flash": return info.flash ?? ""
        case "rotation": return ["", "0", "0 mirror", "180", "180 mirror", "90 CW mirror", "90 CW", "90 CCW mirror", "90 CCW"][safe: info.orientation] ?? ""
        case "iccprofile", "tonecomp", "sharpness", "quality", "focusmode", "flashcomp": return ""   // maker-note fields; exiftool later
        // IPTC
        case "caption", "description": return meta.caption
        case "headline": return meta.headline
        case "byline", "creator", "photog": return meta.byline
        case "credit": return meta.credit
        case "copyright": return meta.copyright
        case "source": return meta.source
        case "city": return meta.city
        case "state", "province": return meta.state
        case "country": return meta.country
        case "location": return meta.location
        case "event": return meta.event
        case "keywords": return meta.keywords.joined(separator: ", ")
        case "instructions": return meta.instructions
        // Job and rating
        case "jobname": return ctx.jobName
        case "rating": return "\(meta.rating)"
        case "colorclass": return ctx.colorClassName(meta.colorClass)
        case "colorclassval": return "\(meta.colorClass)"
        case "tag": return meta.tagged ? "T" : ""
        // User
        case "username": return ctx.user.name
        case "usercompany": return ctx.user.company
        case "useraddress": return ctx.user.address
        case "useraddress2": return ctx.user.address2
        case "usercity": return ctx.user.city
        case "userstate": return ctx.user.state
        case "userzip": return ctx.user.zip
        case "usercountry": return ctx.user.country
        case "userphone": return ctx.user.phone
        case "usermobile": return ctx.user.mobile
        case "userweb": return ctx.user.web
        case "useremail": return ctx.user.email
        case "usercustom1": return ctx.user.custom1
        case "usercustom2": return ctx.user.custom2
        case "usercustom3": return ctx.user.custom3
        default: return ""
        }
    }

    private static func apMonth(_ d: Date?) -> String {
        guard let d else { return "" }
        let m = Calendar.current.component(.month, from: d)
        return ["Jan.", "Feb.", "March", "April", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."][m - 1]
    }

    static func trailingDigits(_ url: URL?, pad: Int) -> String {
        guard let base = url?.deletingPathExtension().lastPathComponent else { return "" }
        let digits = String(base.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed())
        guard let n = Int(digits) else { return "" }
        return pad > 0 ? String(format: "%0\(pad)d", n) : "\(n)"
    }
}
