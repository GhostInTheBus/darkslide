import Foundation

/// Minimal TIFF IFD0 reader: returns the JPEG strip that TIFF-based RAW formats keep as
/// their embedded preview. Reads only the header, the IFD and the strip itself.
enum TIFFPreview {
    struct Strip { let data: Data; let orientation: Int }   // EXIF orientation 1…8

    static func ifd0JPEG(_ url: URL) -> Strip? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return nil }
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
        let ifd = u32(head, 4)
        guard ifd >= 8 else { return nil }
        try? fh.seek(toOffset: UInt64(ifd))
        guard let cntD = try? fh.read(upToCount: 2), cntD.count == 2 else { return nil }
        let n = u16(cntD, 0)
        guard n > 0, n < 512, let ent = try? fh.read(upToCount: 12 * n), ent.count == 12 * n else { return nil }
        var off = 0, len = 0, compression = 0, count = 0, orientation = 1
        for i in 0..<n {
            let tag = u16(ent, i*12), cnt = u32(ent, i*12+4), val = u32(ent, i*12+8)
            switch tag {
            case 0x103: compression = u16(ent, i*12+8)
            case 0x112: orientation = u16(ent, i*12+8)
            case 0x111: off = val; count = cnt          // StripOffsets
            case 0x117: len = val                        // StripByteCounts
            case 0x201: off = val; count = 1             // JPEGInterchangeFormat (some DNG/NEF)
            case 0x202: len = val                        // JPEGInterchangeFormatLength
            default: break
            }
        }
        // One strip, JPEG compressed (6 = old-style, 7 = new-style). Otherwise bail.
        guard count == 1, off > 0, len >= 4, len < 64 << 20, compression == 6 || compression == 7 else { return nil }
        try? fh.seek(toOffset: UInt64(off))
        guard let data = try? fh.read(upToCount: len), data.count == len,
              data.first == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        return Strip(data: data, orientation: orientation)
    }
}
