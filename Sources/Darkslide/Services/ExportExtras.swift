import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Crop as Adobe crs fractions, which Camera Raw and Lightroom honour.
struct CropRect: Equatable, Codable {
    var left = 0.0, top = 0.0, right = 1.0, bottom = 1.0     // fractions of the oriented image
    var hasCrop: Bool { left > 0 || top > 0 || right < 1 || bottom < 1 }
    func pixelRect(width: Int, height: Int) -> CGRect {
        CGRect(x: Double(width) * left, y: Double(height) * top, width: Double(width) * (right - left), height: Double(height) * (bottom - top)).integral
    }
}

extension ExportEngine {
    /// Draw a text watermark on a corner (or centre) of the image.
    static func stamp(_ cg: CGImage, text: String, corner: Int, opacity: Double, scale: Double) -> CGImage {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return cg }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let size = max(12, Double(max(w, h)) * scale)
        let font = NSFont.boldSystemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: opacity),
                                                    .strokeColor: NSColor(white: 0, alpha: opacity * 0.8), .strokeWidth: -2.5]
        let str = NSAttributedString(string: text, attributes: attrs)
        let m = size * 0.8
        let bounds = str.size()
        let x: CGFloat, y: CGFloat
        switch corner {
        case 0: x = m; y = CGFloat(h) - bounds.height - m
        case 1: x = CGFloat(w) - bounds.width - m; y = CGFloat(h) - bounds.height - m
        case 2: x = m; y = m
        case 4: x = (CGFloat(w) - bounds.width) / 2; y = (CGFloat(h) - bounds.height) / 2
        default: x = CGFloat(w) - bounds.width - m; y = m
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? cg
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// the legacy app's HTML export: a self-contained gallery folder with thumbnails, large images
    /// and captions, built from the selection.
    static func htmlGallery(items: [PhotoItem], meta: [URL: PhotoMeta], title: String, to folder: URL, largeEdge: Int, thumbEdge: Int,
                            progress: @escaping (Int, Int) -> Void, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = Result()
            let fm = FileManager.default
            let large = folder.appendingPathComponent("images"), thumbs = folder.appendingPathComponent("thumbs")
            try? fm.createDirectory(at: large, withIntermediateDirectories: true); try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
            var cards: [String] = []
            for (i, item) in items.enumerated() {
                let base = item.url.deletingPathExtension().lastPathComponent
                do {
                    try writeJPEG(from: item.url, to: large.appendingPathComponent(base + ".jpg"), longEdge: largeEdge, quality: 88, srgb: true, crop: meta[item.url]?.crop)
                    try writeJPEG(from: item.url, to: thumbs.appendingPathComponent(base + ".jpg"), longEdge: thumbEdge, quality: 80, srgb: true, crop: meta[item.url]?.crop)
                    let m = meta[item.url] ?? PhotoMeta()
                    var cap = "<b>" + esc(item.displayName) + "</b>"
                    if !m.caption.isEmpty { cap += "<br>" + esc(m.caption) }
                    if !m.byline.isEmpty { cap += "<br><small>" + esc(m.byline) + "</small>" }
                    cards.append("<figure><a href=\"images/" + esc(base) + ".jpg\"><img src=\"thumbs/" + esc(base) + ".jpg\" alt=\"" + esc(m.caption) + "\" loading=\"lazy\"></a><figcaption>" + cap + "</figcaption></figure>")
                } catch { result.failures.append("\(item.displayName): \(error.localizedDescription)") }
                DispatchQueue.main.async { progress(i + 1, items.count) }
            }
            let css = "body{margin:0;background:#111;color:#ddd;font:14px -apple-system,Helvetica,Arial,sans-serif}h1{font-weight:500;padding:20px 24px;margin:0}"
                + ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(\(thumbEdge)px,1fr));gap:14px;padding:0 24px 24px}figure{margin:0}"
                + "img{width:100%;height:auto;display:block;border-radius:4px}figcaption{padding:6px 2px;color:#aaa;font-size:12px}a{color:inherit}"
            let html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" + esc(title) + "</title><style>" + css + "</style></head><body><h1>" + esc(title) + "</h1><div class=\"grid\">" + cards.joined(separator: "\n") + "</div></body></html>"
            let index = folder.appendingPathComponent("index.html")
            do { try html.write(to: index, atomically: true, encoding: .utf8); result.written.append(index) } catch { result.failures.append("index.html: \(error.localizedDescription)") }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Convert RAW to DNG through Adobe's free converter, if installed.
    static func convertToDNG(items: [PhotoItem], to folder: URL?) -> String {
        let app = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"
        guard FileManager.default.isExecutableFile(atPath: app) else { return "Adobe DNG Converter is not installed (free from adobe.com)." }
        let raws = items.filter(\.isRaw).map(\.url.path)
        guard !raws.isEmpty else { return "No RAW files selected." }
        let p = Process(); p.executableURL = URL(fileURLWithPath: app)
        var args = ["-c", "-p1"]
        if let f = folder { args += ["-d", f.path] }
        p.arguments = args + raws
        do { try p.run(); p.waitUntilExit() } catch { return "Could not run DNG Converter: \(error.localizedDescription)" }
        return p.terminationStatus == 0 ? "Converted \(raws.count) file\(raws.count == 1 ? "" : "s") to DNG." : "DNG Converter exited with status \(p.terminationStatus)."
    }
}
