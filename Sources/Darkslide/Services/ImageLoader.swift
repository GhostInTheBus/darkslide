import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// All image decoding goes through ImageIO and asks for the *embedded* preview,
/// never a RAW decode. This is the whole speed trick.
enum ImageLoader {
    /// Embedded preview no larger than `maxPixel` on its long side. Returns nil if the
    /// file has no embedded preview (then the caller may fall back to `decoded`).
    static func embeddedPreview(for url: URL, maxPixel: Int) -> CGImage? {
        if PhotoItem.videoExtensions.contains(url.pathExtension.lowercased()) { return videoFrame(for: url, maxPixel: maxPixel) }
        // Fast path: TIFF-based RAW (CR2, NEF, ARW, DNG, PEF, ORF…) keeps a JPEG in IFD0.
        // Pulling those bytes out ourselves and decoding them scaled is about twice as
        // fast as asking ImageIO to find the preview for us.
        if let strip = TIFFPreview.embeddedJPEG(url),
           let src = CGImageSourceCreateWithData(strip.data as CFData, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return oriented(cg, strip.orientation)
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Embedded preview decoded at exactly half its native size. JPEG decoders scale by
    /// 1/2 in the DCT for free; any other target size costs a resample on top. On a
    /// 5616 px Canon file this is ~40 ms versus ~220 ms for the full size.
    static func halfSizePreview(for url: URL) -> CGImage? {
        let src: CGImageSource?
        let strip = TIFFPreview.embeddedJPEG(url)
        if let strip {
            src = CGImageSourceCreateWithData(strip.data as CFData, nil)
        } else {
            src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let src else { return nil }
        var longSide = 4096
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            // Half size is free in the JPEG decoder, and a 5616 px Canon strip takes 220 ms
            // at full size against 40 ms at half. Strips up to ~4500 px (Fuji 4416, Nikon
            // 4128, Sony 1616) decode at native size in about the same 40 ms, and on a 5K
            // display the extra pixels show.
            longSide = max(w, h) > 4500 ? max(w, h) / 2 : max(w, h)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: strip != nil,
            kCGImageSourceCreateThumbnailWithTransform: strip == nil,   // strips are rotated by `oriented`
            kCGImageSourceThumbnailMaxPixelSize: max(longSide, 1024),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return strip.map { oriented(cg, $0.orientation) } ?? cg
    }

    /// Apply an EXIF orientation (1…8) to a decoded image. The embedded JPEG strip has no
    /// orientation of its own; the RAW container does.
    static func oriented(_ cg: CGImage, _ orientation: Int) -> CGImage {
        guard orientation > 1 && orientation <= 8 else { return cg }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let swap = orientation >= 5
        let outW = swap ? h : w, outH = swap ? w : h
        guard let ctx = CGContext(data: nil, width: Int(outW), height: Int(outH), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return cg }
        ctx.interpolationQuality = .none
        // CoreGraphics contexts are y-up, so the rotations read "backwards" compared to
        // the EXIF table. Verified pixel-for-pixel against ImageIO's own transform.
        if orientation == 2 || orientation == 4 || orientation == 5 || orientation == 7 {
            ctx.translateBy(x: outW, y: 0); ctx.scaleBy(x: -1, y: 1)       // mirror the output
        }
        switch orientation {
        case 3, 4: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)             // 180°
        case 6, 5: ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)        // stored needs 90° CW
        case 8, 7: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)         // stored needs 90° CCW
        default: break                                                         // 1, 2: no rotation
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// Full decode (slow for RAW). Only used when there is no embedded preview, or for
    /// 100% zoom on files whose preview is smaller than the sensor.
    static func decoded(for url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// First frame of a video, through AVFoundation, at most `maxPixel` on the long side.
    static func videoFrame(for url: URL, maxPixel: Int, at seconds: Double = 0.5) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    static func captureInfo(for url: URL) -> CaptureInfo {
        var info = CaptureInfo()
        if PhotoItem.videoExtensions.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            info.duration = CMTimeGetSeconds(asset.duration)
            if let t = asset.tracks(withMediaType: .video).first {
                let s = t.naturalSize.applying(t.preferredTransform)
                info.pixelWidth = Int(abs(s.width)); info.pixelHeight = Int(abs(s.height))
            }
            if let d = asset.creationDate?.dateValue { info.captureDate = d }
            return info
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return info }
        info.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        info.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            info.shutter = t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded()))"
        }
        var fnum = exif[kCGImagePropertyExifFNumber] as? Double ?? 0
        if !fnum.isFinite { fnum = 0 }
        if fnum <= 0, let apex = exif[kCGImagePropertyExifApertureValue] as? Double, apex > 0, apex.isFinite {
            fnum = pow(2, apex / 2)   // APEX aperture value, what older Canon bodies report
        }
        if fnum > 0, fnum.isFinite { info.aperture = String(format: "f/%.1f", fnum).replacingOccurrences(of: ".0", with: "") }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let i = isos.first { info.iso = "\(i)" }
        info.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String)
        info.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        info.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        info.serial = (exif[kCGImagePropertyExifBodySerialNumber] as? String) ?? (aux[kCGImagePropertyExifAuxSerialNumber] as? String)
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { info.focalLength = String(format: "%gmm", fl) }
        if let o = props[kCGImagePropertyOrientation] as? Int { info.orientation = o }
        else if let o = tiff[kCGImagePropertyTIFFOrientation] as? Int { info.orientation = o }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            info.latitude = latRef == "S" ? -lat : lat
            info.longitude = lonRef == "W" ? -lon : lon
        }
        info.firmware = aux[kCGImagePropertyExifAuxFirmware] as? String
        if let ec = exif[kCGImagePropertyExifExposureBiasValue] as? Double { info.exposureComp = String(format: "%+.1f", ec) }
        if let p = exif[kCGImagePropertyExifExposureProgram] as? Int {
            info.program = ["", "Manual", "Program", "Aperture priority", "Shutter priority", "Creative", "Action", "Portrait", "Landscape"][safe: p]
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int { info.whiteBalance = wb == 0 ? "Auto" : "Manual" }
        if let f = exif[kCGImagePropertyExifFlash] as? Int { info.flash = (f & 1) == 1 ? "Fired" : "Did not fire" }
        if let n = aux[kCGImagePropertyExifAuxImageNumber] as? Int { info.frameNumber = "\(n)" }
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.captureDate = ImageLoader.exifDate.date(from: s)
        }
        return info
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
