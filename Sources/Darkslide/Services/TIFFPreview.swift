import Foundation
import ImageIO

/// Minimal TIFF reader: returns the largest JPEG that a TIFF-based RAW keeps as its
/// embedded preview. Looks in IFD0, every SubIFD (tag 0x14A) and the IFD chain (IFD1,
/// IFD2…), because each maker puts the full-size JPEG somewhere else: Canon CR2 and
/// Sony in IFD0, Nikon in SubIFD0, Pentax in IFD2, Sony's newer bodies in a SubIFD.
/// Reads only headers, directories and the chosen strip.
enum TIFFPreview {
    struct Strip { let data: Data; let orientation: Int }   // EXIF orientation 1…8

    private struct Candidate { let offset: Int; let length: Int }

    static func embeddedJPEG(_ url: URL) -> Strip? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return nil }
        if head.elementsEqual("FUJIFILM".utf8) { return fujiJPEG(fh) }
        if head[head.startIndex + 4 ..< head.startIndex + 8].elementsEqual("ftyp".utf8) { return canonCR3JPEG(fh) }
        let le: Bool
        switch (head[0], head[1]) {
        case (0x49, 0x49): le = true
        case (0x4D, 0x4D): le = false
        default: return nil            // not TIFF: CR3, RAF, HEIC, JPEG…
        }
        func u16(_ d: Data, _ o: Int) -> Int {
            let b = d.startIndex + o
            return le ? Int(d[b]) | Int(d[b+1]) << 8 : Int(d[b]) << 8 | Int(d[b+1])
        }
        func u32(_ d: Data, _ o: Int) -> Int {
            le ? u16(d, o) | u16(d, o+2) << 16 : u16(d, o) << 16 | u16(d, o+2)
        }
        guard u16(head, 2) == 42 else { return nil }   // classic TIFF only (no BigTIFF)

        var candidates: [Candidate] = []
        var orientation = 1
        var visited = Set<Int>()
        var queue = [u32(head, 4)]
        var budget = 16                                 // directories to read at most

        while let ifd = queue.first, budget > 0 {
            queue.removeFirst(); budget -= 1
            guard ifd >= 8, !visited.contains(ifd) else { continue }
            visited.insert(ifd)
            try? fh.seek(toOffset: UInt64(ifd))
            guard let cntD = try? fh.read(upToCount: 2), cntD.count == 2 else { continue }
            let n = u16(cntD, 0)
            guard n > 0, n < 512, let ent = try? fh.read(upToCount: 12 * n + 4), ent.count >= 12 * n else { continue }
            var off = 0, len = 0, compression = 0, count = 0
            for i in 0..<n {
                let tag = u16(ent, i*12), type = u16(ent, i*12+2), cnt = u32(ent, i*12+4), val = u32(ent, i*12+8)
                switch tag {
                case 0x103: compression = u16(ent, i*12+8)
                case 0x112: if visited.count == 1 { orientation = u16(ent, i*12+8) }   // IFD0 only
                case 0x111: off = val; count = cnt          // StripOffsets
                case 0x117: len = val                        // StripByteCounts
                case 0x201: off = val; count = 1             // JPEGInterchangeFormat
                case 0x202: len = val                        // JPEGInterchangeFormatLength
                case 0x14A:                                  // SubIFDs: one inline offset or a list
                    if cnt == 1 { queue.append(val) }
                    else if cnt < 8, type == 4, let d = try? readAt(fh, val, 4 * cnt) {
                        for k in 0..<cnt { queue.append(u32(d, 4 * k)) }
                    }
                default: break
                }
            }
            // One strip, JPEG compressed (6 = old-style, 7 = new-style).
            if count == 1, off > 0, len >= 4, len < 64 << 20, compression == 6 || compression == 7 {
                candidates.append(Candidate(offset: off, length: len))
            }
            if ent.count == 12 * n + 4 { queue.append(u32(ent, 12 * n)) }   // next IFD in the chain
        }
        // Largest *displayable* JPEG wins. Canon stores the raw sensor data as lossless
        // JPEG (SOF3) with compression 6 too, so the SOF header decides, not the byte count.
        var best: (pixels: Int, c: Candidate)? = nil
        for c in candidates {
            guard let (w, h) = sofSize(fh, c) else { continue }
            if best == nil || w * h > best!.pixels { best = (w * h, c) }
        }
        guard let best, let data = try? readAt(fh, best.c.offset, best.c.length), data.count == best.c.length else { return nil }
        return Strip(data: data, orientation: orientation)
    }

    /// Width and height from the JPEG's SOF marker; nil unless it is 8-bit baseline,
    /// extended or progressive (what ImageIO decodes). Reads the header in 16 KB steps.
    /// Fujifilm RAF is not TIFF: a fixed header holds the embedded JPEG's offset and
    /// length as big-endian 32-bit values at bytes 84 and 88. That JPEG carries its own
    /// EXIF (with orientation), unlike a TIFF strip, so the orientation comes from it.
    private static func fujiJPEG(_ fh: FileHandle) -> Strip? {
        guard let h = try? readAt(fh, 84, 8), h.count == 8 else { return nil }
        func be32(_ o: Int) -> Int { let b = h.startIndex + o; return Int(h[b]) << 24 | Int(h[b+1]) << 16 | Int(h[b+2]) << 8 | Int(h[b+3]) }
        let off = be32(0), len = be32(4)
        guard off >= 92, len >= 4, len < 64 << 20, let data = try? readAt(fh, off, len), data.count == len,
              data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        var orientation = 1
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = props[kCGImagePropertyOrientation] as? Int { orientation = o }
        return Strip(data: data, orientation: orientation)
    }

    /// Canon CR3 is an ISO base media file: `moov` holds four `trak`s and the first one is
    /// the full-size JPEG, a single sample whose size and offset sit in that track's
    /// `stsz` and `co64`/`stco`. Orientation is in the CMT1 (IFD0) box inside moov's uuid.
    private static func canonCR3JPEG(_ fh: FileHandle) -> Strip? {
        func be32(_ d: Data, _ o: Int) -> Int { let b = d.startIndex + o; return Int(d[b]) << 24 | Int(d[b+1]) << 16 | Int(d[b+2]) << 8 | Int(d[b+3]) }
        func be64(_ d: Data, _ o: Int) -> Int { be32(d, o) << 32 | be32(d, o + 4) }
        /// Children of the box body [start, end): (type, bodyStart, bodyEnd).
        func boxes(_ start: Int, _ end: Int) -> [(String, Int, Int)] {
            var out: [(String, Int, Int)] = []; var p = start
            while p + 8 <= end, out.count < 64 {
                guard let h = try? readAt(fh, p, 16), h.count >= 8 else { break }
                var size = be32(h, 0), body = p + 8
                let type = String(decoding: h[h.startIndex + 4 ..< h.startIndex + 8], as: UTF8.self)
                if size == 1, h.count == 16 { size = be64(h, 8); body = p + 16 }
                if size == 0 { size = end - p }
                guard size >= 8, p + size <= end else { break }
                out.append((type, body, p + size)); p += size
            }
            return out
        }
        guard let fileSize = try? fh.seekToEnd(), fileSize > 16,
              let moov = boxes(0, Int(fileSize)).first(where: { $0.0 == "moov" }),
              let trak = boxes(moov.1, moov.2).first(where: { $0.0 == "trak" }),
              let mdia = boxes(trak.1, trak.2).first(where: { $0.0 == "mdia" }),
              let minf = boxes(mdia.1, mdia.2).first(where: { $0.0 == "minf" }),
              let stbl = boxes(minf.1, minf.2).first(where: { $0.0 == "stbl" }) else { return nil }
        var off = 0, len = 0
        for (type, b, e) in boxes(stbl.1, stbl.2) {
            switch type {
            case "stsz":
                guard let d = try? readAt(fh, b, min(16, e - b)), d.count >= 12 else { return nil }
                len = be32(d, 4); if len == 0, d.count == 16, be32(d, 8) >= 1 { len = be32(d, 12) }   // table of one
            case "stco":
                guard let d = try? readAt(fh, b, 12), d.count == 12, be32(d, 4) >= 1 else { return nil }
                off = be32(d, 8)
            case "co64":
                guard let d = try? readAt(fh, b, 16), d.count == 16, be32(d, 4) >= 1 else { return nil }
                off = be64(d, 8)
            default: break
            }
        }
        guard off > 0, len >= 4, len < 64 << 20, let data = try? readAt(fh, off, len), data.count == len,
              data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        // Orientation: CMT1 is a TIFF (IFD0) inside moov's uuid box.
        var orientation = 1
        if let uuid = boxes(moov.1, moov.2).first(where: { $0.0 == "uuid" }),
           let cmt1 = boxes(uuid.1 + 16, uuid.2).first(where: { $0.0 == "CMT1" }),
           let t = try? readAt(fh, cmt1.1, min(cmt1.2 - cmt1.1, 4096)), t.count >= 8 {
            let le = t[t.startIndex] == 0x49
            func u16(_ o: Int) -> Int { let b = t.startIndex + o; return le ? Int(t[b]) | Int(t[b+1]) << 8 : Int(t[b]) << 8 | Int(t[b+1]) }
            func u32(_ o: Int) -> Int { le ? u16(o) | u16(o+2) << 16 : u16(o) << 16 | u16(o+2) }
            let ifd = u32(4)
            if ifd + 2 <= t.count {
                let n = u16(ifd)
                for i in 0..<n where ifd + 2 + i*12 + 12 <= t.count {
                    if u16(ifd + 2 + i*12) == 0x112 { orientation = u16(ifd + 2 + i*12 + 8); break }
                }
            }
        }
        return Strip(data: data, orientation: orientation)
    }

    private static func sofSize(_ fh: FileHandle, _ c: Candidate) -> (Int, Int)? {
        var buf = Data()
        var i = 2
        func ensure(_ n: Int) -> Bool {
            while buf.count < n {
                let want = min(c.length, max(n, buf.count + 16384))
                guard want > buf.count, let d = try? readAt(fh, c.offset + buf.count, want - buf.count) else { return false }
                buf.append(d)
            }
            return true
        }
        guard ensure(4), buf[0] == 0xFF, buf[1] == 0xD8 else { return nil }
        while ensure(i + 4) {
            guard buf[i] == 0xFF else { return nil }
            let marker = buf[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }     // EOI / scan before any SOF
            let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                guard marker == 0xC0 || marker == 0xC1 || marker == 0xC2, ensure(i + 9), buf[i + 4] == 8 else { return nil }
                let h = Int(buf[i + 5]) << 8 | Int(buf[i + 6]), w = Int(buf[i + 7]) << 8 | Int(buf[i + 8])
                return w > 0 && h > 0 ? (w, h) : nil
            }
            i += 2 + len
        }
        return nil
    }

    private static func readAt(_ fh: FileHandle, _ offset: Int, _ length: Int) throws -> Data {
        try fh.seek(toOffset: UInt64(offset))
        guard let d = try fh.read(upToCount: length), d.count == length else { throw CocoaError(.fileReadCorruptFile) }
        return d
    }
}
