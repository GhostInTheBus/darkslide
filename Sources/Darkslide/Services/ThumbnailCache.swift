import AppKit

/// Background thumbnail generation with an in-memory cache. Requests are LIFO so the
/// cells you are looking at now beat the ones you scrolled past.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .userInitiated
        return q
    }()
    private var inflight: [URL: Operation] = [:]
    private var waiters: [URL: [(NSImage?) -> Void]] = [:]
    private let lock = NSLock()

    /// Thumbnails are generated at this fixed pixel size and scaled by the view; the
    /// grid slider never triggers regeneration.
    static let pixelSize = 512

    init() { cache.totalCostLimit = 1200 << 20 }   // ~1.2 GB of thumbnails, then evict

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func request(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let img = cached(url) { completion(img); return }
        lock.lock()
        if inflight[url] != nil { waiters[url, default: []].append(completion); lock.unlock(); return }
        waiters[url] = [completion]
        let op = BlockOperation()
        op.queuePriority = .high
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, let op, !op.isCancelled else { return }
            var cg = ImageLoader.embeddedPreview(for: url, maxPixel: ThumbnailCache.pixelSize)
            if cg == nil { cg = ImageLoader.decoded(for: url, maxPixel: ThumbnailCache.pixelSize) }
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let img, let cg { self.cache.setObject(img, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height) }
            self.lock.lock(); self.inflight[url] = nil; let ws = self.waiters.removeValue(forKey: url) ?? []; self.lock.unlock()
            DispatchQueue.main.async { for w in ws { w(img) } }
        }
        inflight[url] = op
        lock.unlock()
        // Newest request first: demote everything already waiting.
        for waiting in queue.operations where !waiting.isExecuting { waiting.queuePriority = .normal }
        queue.addOperation(op)
    }

    func cancelAll() {
        queue.cancelAllOperations()
        lock.lock(); inflight.removeAll(); waiters.removeAll(); lock.unlock()
    }
    func clear() { cancelAll(); cache.removeAllObjects() }
    func remove(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}
