import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Save As / export presets: resize from the embedded preview or full decode, JPEG
/// quality, metadata carried over by exiftool, optional GPS strip and copyright stamp.
enum ExportEngine {
    struct Result { var written: [URL] = []; var failures: [String] = [] }

    static func export(items: [PhotoItem], preset: ExportPreset, to folder: URL, meta: [URL: PhotoMeta],
                       copyright: String, creator: String, watermark: ((PhotoItem) -> String)? = nil,
                       progress: @escaping (Int, Int) -> Void, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = Result()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, item) in items.enumerated() {
                let base = item.url.deletingPathExtension().lastPathComponent + preset.suffix
                let dest = IngestEngine.uniqueDestination(folder.appendingPathComponent(base).appendingPathExtension("jpg"))
                do {
                    try writeJPEG(from: item.url, to: dest, longEdge: preset.longEdge, quality: preset.quality, srgb: preset.convertToSRGB,
                                  watermark: watermark?(item), corner: preset.watermarkCorner, opacity: preset.watermarkOpacity, scale: preset.watermarkScale, crop: meta[item.url]?.crop)
                    // Metadata: copy everything from the source, then apply the preset's rules.
                    var args = ["-overwrite_original", "-ignoreMinorErrors", "-tagsFromFile", item.url.path, "-all:all", "-unsafe"]
                    if preset.stripAllMetadata { args = ["-overwrite_original", "-all="] }
                    if preset.stripGPS { args += ["-gps:all=", "-XMP-exif:GPS*="] }
                    if preset.copyrightStamp {
                        let m = meta[item.url]
                        let c = (m?.copyright.isEmpty == false) ? m!.copyright : copyright
                        let who = (m?.byline.isEmpty == false) ? m!.byline : creator
                        if !c.isEmpty { args += ["-MWG:Copyright=\(c)", "-XMP-xmpRights:Marked=True"] }
                        if !who.isEmpty { args += ["-MWG:Creator=\(who)"] }
                    }
                    args.append(dest.path)
                    let r = ExifTool.shared.run(args)
                    if !r.ok { result.failures.append("\(dest.lastPathComponent): \(r.error)") }
                    result.written.append(dest)
                } catch {
                    result.failures.append("\(item.displayName): \(error.localizedDescription)")
                }
                DispatchQueue.main.async { progress(i + 1, items.count) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    enum ExportError: Error, LocalizedError {
        case decode, encode
        var errorDescription: String? { self == .decode ? "could not decode image" : "could not write JPEG" }
    }

    static func writeJPEG(from src: URL, to dest: URL, longEdge: Int, quality: Int, srgb: Bool,
                          watermark: String? = nil, corner: Int = 3, opacity: Double = 0.6, scale: Double = 0.03, crop: CropRect? = nil) throws {
        // With a crop, decode large enough that the cropped result still reaches longEdge.
        let cropScale = (crop?.hasCrop == true) ? max(crop!.right - crop!.left, crop!.bottom - crop!.top) : 1
        let maxPixel = longEdge > 0 ? Int(Double(longEdge) / max(cropScale, 0.01)) : 20000
        // Full-size export from a RAW uses the embedded JPEG at its native size; that is what
        // the legacy app does too unless RAW rendering is turned on.
        var cg = ImageLoader.embeddedPreview(for: src, maxPixel: maxPixel)
        if cg == nil { cg = ImageLoader.decoded(for: src, maxPixel: maxPixel) }
        guard var image = cg else { throw ExportError.decode }
        if let c = crop, c.hasCrop, let cropped = image.cropping(to: c.pixelRect(width: image.width, height: image.height)) { image = cropped }
        if longEdge > 0, max(image.width, image.height) > longEdge, let r = resample(image, longEdge: longEdge) { image = r }
        if let text = watermark, !text.isEmpty { image = stamp(image, text: text, corner: corner, opacity: opacity, scale: scale) }
        if srgb, let space = image.colorSpace, space.name != CGColorSpace.sRGB, let converted = image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            image = converted
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ExportError.encode }
    }

    static func resample(_ cg: CGImage, longEdge: Int) -> CGImage? {
        let s = Double(longEdge) / Double(max(cg.width, cg.height))
        let w = Int(Double(cg.width) * s), h = Int(Double(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Copy or move the selection (with companions) to a folder. Never overwrites.
    static func copyOrMove(items: [PhotoItem], to folder: URL, move: Bool) -> Result {
        var result = Result()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            for file in RenameEngine.companions(of: item) {
                let dest = IngestEngine.uniqueDestination(folder.appendingPathComponent(file.lastPathComponent))
                do {
                    if move { try fm.moveItem(at: file, to: dest) } else { try fm.copyItem(at: file, to: dest) }
                    result.written.append(dest)
                } catch { result.failures.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        return result
    }
}
