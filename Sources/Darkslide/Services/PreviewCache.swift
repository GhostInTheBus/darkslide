import AppKit

/// Full-screen previews in two tiers. `fit` is the embedded JPEG decoded at half size
/// (fast, prefetched around the cursor). `full` is the whole embedded JPEG, loaded on
/// demand for 100% zoom.
final class PreviewCache {
    static let shared = PreviewCache()
    static let fullMaxPixel = 8192

    enum Tier { case fit, full }

    private let fitCache = NSCache<NSURL, NSImage>()
    private let fullCache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "preview", qos: .userInteractive, attributes: .concurrent)
    private var inflight: [String: [(NSImage?) -> Void]] = [:]
    private let lock = NSLock()

    init() { fitCache.countLimit = 12; fullCache.countLimit = 2 }

    func remove(_ url: URL) { fitCache.removeObject(forKey: url as NSURL); fullCache.removeObject(forKey: url as NSURL) }
    /// After a rotate: forget the cached decode and let any in-flight decode finish on its own.
    func invalidate(_ url: URL) { remove(url) }

    func cached(_ url: URL, _ tier: Tier = .fit) -> NSImage? {
        (tier == .fit ? fitCache : fullCache).object(forKey: url as NSURL)
    }

    func request(_ url: URL, _ tier: Tier = .fit, completion: ((NSImage?) -> Void)? = nil) {
        if let img = cached(url, tier) { completion?(img); return }
        let key = "\(tier)|\(url.path)"
        lock.lock()
        if inflight[key] != nil {
            // Someone (usually the prefetcher) is already decoding this one: join the wait.
            if let completion { inflight[key]!.append(completion) }
            lock.unlock(); return
        }
        inflight[key] = completion.map { [$0] } ?? []
        lock.unlock()
        queue.async { [self] in
            var cg: CGImage?
            switch tier {
            case .fit:
                cg = ImageLoader.halfSizePreview(for: url)
                if cg == nil { cg = ImageLoader.decoded(for: url, maxPixel: 3000) }
            case .full:
                cg = ImageLoader.embeddedPreview(for: url, maxPixel: PreviewCache.fullMaxPixel)
                if cg == nil { cg = ImageLoader.decoded(for: url, maxPixel: PreviewCache.fullMaxPixel) }
            }
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let img { (tier == .fit ? fitCache : fullCache).setObject(img, forKey: url as NSURL) }
            lock.lock(); let waiters = inflight.removeValue(forKey: key) ?? []; lock.unlock()
            DispatchQueue.main.async { for w in waiters { w(img) } }
        }
    }
}
