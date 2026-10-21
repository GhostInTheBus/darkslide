import Foundation

/// One row in the contact sheet. A RAW+JPEG pair is a single item: `url` is the
/// RAW (the one we read previews and metadata from), `sidecarJPEG` is the mate.
struct PhotoItem: Identifiable, Hashable {
    let id: URL          // primary file
    let url: URL
    let sidecarJPEG: URL?
    let displayName: String
    var editOf: URL? = nil          // this file is an edited version of that original
    var affinityOnly = false        // an .afphoto exists with no exported TIFF/JPEG beside it

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "rw2", "orf",
        "dng", "pef", "3fr", "fff", "iiq", "erf", "mrw", "mos", "x3f", "srw"
    ]
    static let imageExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp", "psd", "webp"
    ])
    static let editorDocExtensions: Set<String> = ["afphoto", "pxd", "xcf", "psb"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "crm"]
    var isVideo: Bool { PhotoItem.videoExtensions.contains(url.pathExtension.lowercased()) }

    var isRaw: Bool { PhotoItem.rawExtensions.contains(url.pathExtension.lowercased()) }
}

/// Capture info shown in the preview overlay and the info bar.
struct CaptureInfo {
    var captureDate: Date?
    var shutter: String?
    var aperture: String?
    var iso: String?
    var lens: String?
    var cameraModel: String?
    var cameraMake: String?
    var serial: String?
    var focalLength: String?
    var latitude: Double?
    var longitude: Double?
    var orientation: Int = 1
    var firmware: String?
    var exposureComp: String?
    var program: String?
    var whiteBalance: String?
    var flash: String?
    var frameNumber: String?
    var duration: Double?          // video only, seconds
    var pixelWidth: Int?
    var pixelHeight: Int?

    var summary: String {
        var parts: [String] = []
        if let d = captureDate { parts.append(CaptureInfo.dateFormatter.string(from: d)) }
        if let s = shutter { parts.append(s) }
        if let a = aperture { parts.append(a) }
        if let i = iso { parts.append("ISO \(i)") }
        if let l = lens { parts.append(l) }
        if let m = cameraModel { parts.append(m) }
        if let w = pixelWidth, let h = pixelHeight { parts.append("\(w)×\(h)") }
        if let d = duration { parts.append(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)) }
        return parts.joined(separator: "   ")
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
