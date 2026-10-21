import AppKit
import AVKit
import SwiftUI

/// Full-window preview. Fit to window by default; Z or click toggles 100%.
struct PreviewView: View {
    @EnvironmentObject var library: Library
    @State private var image: NSImage?
    @State private var fullImage: NSImage?
    @State private var loadStarted = Date()
    @State private var loadMs: Double = 0
    @State private var zoomAnchor = CGPoint(x: 0.5, y: 0.5)   // fraction of the image to centre on at 100%
    @State private var dragStart: CGPoint? = nil
    @State private var dragRect: CGRect? = nil                  // in fitted-image fractions

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                VStack { controls; Spacer() }.zIndex(2)
                if let item = library.current, item.isVideo {
                    VideoPlayerView(url: item.url)
                } else if let image {
                    if library.zoomToggle {
                        let shown = fullImage ?? image
                        let scale: CGFloat = fullImage == nil ? 2 : 1   // half-size stand-in until the full one lands
                        ZoomScrollView(image: shown, scale: scale, anchor: zoomAnchor)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture(count: 2) { library.stopSlideshow(); library.cropMode = false; library.isPreviewing = false }
                            .onTapGesture(count: 1) { p in
                                guard !library.cropMode else { return }
                                // Zoom to the point under the mouse, like the legacy app.
                                let fitted = fittedRect(image: image.size, in: geo.size)
                                zoomAnchor = CGPoint(x: min(max((p.x - fitted.minX) / fitted.width, 0), 1), y: min(max((p.y - fitted.minY) / fitted.height, 0), 1))
                                library.zoomToggle = true
                            }
                            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                                guard library.cropMode else { return }
                                let f = fittedRect(image: image.size, in: geo.size)
                                func frac(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1), y: min(max((p.y - f.minY) / f.height, 0), 1)) }
                                let a = frac(g.startLocation), b = frac(g.location)
                                dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            })
                        if library.cropMode {
                            let f = fittedRect(image: image.size, in: geo.size)
                            let r = dragRect ?? (library.current.flatMap { library.meta[$0.url]?.crop }).map { CGRect(x: $0.left, y: $0.top, width: $0.right - $0.left, height: $0.bottom - $0.top) }
                            CropOverlay(fitted: f, crop: r)
                        } else if let c = library.current.flatMap({ library.meta[$0.url]?.crop }), c.hasCrop {
                            let f = fittedRect(image: image.size, in: geo.size)
                            CropOverlay(fitted: f, crop: CGRect(x: c.left, y: c.top, width: c.right - c.left, height: c.bottom - c.top), dim: 0.35)
                        }
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
                overlay
            }
            .contentShape(Rectangle())
        }
        .background(KeyCatcher(onKey: handleKey))   // crop keys and up/down only; cull keys are handled app-wide
        .onAppear(perform: load)
        .onChange(of: library.currentIndex) { _, _ in load() }
        .onChange(of: library.zoomToggle) { _, on in if on { loadFull() } }
        .onChange(of: library.reloadToken) { _, _ in load() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { library.stopSlideshow(); library.cropMode = false; library.isPreviewing = false } label: { Label("Contact Sheet", systemImage: "square.grid.3x3") }
                .help("Back to the contact sheet (Esc or Space)")
            Divider().frame(height: 16)
            Button { library.step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous (←)")
            Button { library.step(1) } label: { Image(systemName: "chevron.right") }.help("Next (→)")
            Divider().frame(height: 16)
            Button { library.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.help("Rotate counterclockwise (⌘[)")
            Button { library.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.help("Rotate clockwise (⌘])")
            Button { library.zoomToggle.toggle() } label: { Image(systemName: library.zoomToggle ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass") }.help("100% zoom (Z or click)")
            Button { library.cropMode.toggle() } label: { Image(systemName: "crop") }.help("Crop (C)")
            Divider().frame(height: 16)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { r in
                    let cur = library.current.flatMap { library.meta[$0.url]?.rating } ?? 0
                    Button { library.setRating(cur == r ? 0 : r) } label: { Image(systemName: r <= cur ? "star.fill" : "star").foregroundStyle(.yellow) }.help("\(r) star\(r == 1 ? "" : "s") (\(r))")
                }
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
    }

    private var overlay: some View {
        HStack {
            if let item = library.current {
                let info = library.info(for: item)
                let m = library.meta[item.url] ?? PhotoMeta()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.displayName).font(.headline)
                        if m.rating > 0 { Text(String(repeating: "★", count: m.rating)).foregroundStyle(.yellow) }
                        if m.colorClass > 0 {
                            Text(library.colorClasses.name(m.colorClass)).font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(nsColor: NSColor(hex: library.colorClasses.hex(m.colorClass)))).cornerRadius(3)
                        }
                        if m.tagged { Text("TAGGED").font(.caption.bold()).foregroundStyle(.green) }
                    }
                    Text(infoText(item, info, m)).font(.caption).foregroundStyle(.secondary)
                    if !m.caption.isEmpty { Text(m.caption).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let i = library.currentIndex { Text("\(i + 1) / \(library.items.count)") }
                HStack(spacing: 8) {
                    if let shown = (library.zoomToggle ? fullImage : image) { Text("\(Int(shown.size.width))×\(Int(shown.size.height)) preview") }
                    Text(library.cropMode ? "CROP: drag, Return saves, Esc cancels" : library.zoomToggle ? (fullImage == nil ? "100% (loading)" : "100%") : "fit")
                    if loadMs > 0 { Text(String(format: "%.0f ms", loadMs)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
    }

    private func fittedRect(image: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / image.width, box.height / image.height)
        let w = image.width * s, h = image.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// The preview overlay uses the same variable template the legacy app calls the Info string.
    private func infoText(_ item: PhotoItem, _ info: CaptureInfo, _ m: PhotoMeta) -> String {
        var ctx = library.variableContext()
        ctx.item = item; ctx.info = info; ctx.meta = m
        let t = library.settings.infoTemplate.replacingOccurrences(of: "\\n", with: "\n")
        return Variables.expand(t, ctx).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "   ")
    }

    private func loadFull() {
        guard let item = library.current else { return }
        let url = item.url
        if let c = PreviewCache.shared.cached(url, .full) { fullImage = c; return }
        fullImage = nil
        PreviewCache.shared.request(url, .full) { img in
            if library.current?.url == url { fullImage = img }
        }
    }

    private func load() {
        guard let item = library.current else { return }
        loadStarted = Date()
        fullImage = nil
        if library.zoomToggle { loadFull() }
        if let cached = PreviewCache.shared.cached(item.url) {
            image = cached; loadMs = 0
        } else {
            image = nil
            let url = item.url
            PreviewCache.shared.request(url) { img in
                guard library.current?.url == url else { return }
                image = img
                loadMs = Date().timeIntervalSince(loadStarted) * 1000
            }
        }
        library.prefetchAround(library.currentIndex ?? 0)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if Shortcuts.current.action(for: event) != nil && !library.cropMode { return false }   // app-level monitor owns these
        if library.cropMode {
            switch event.keyCode {
            case 36, 76:   // return: save crop
                if let r = dragRect { library.setCrop(CropRect(left: r.minX, top: r.minY, right: r.maxX, bottom: r.maxY)) } else { library.cropMode = false }
                dragRect = nil; return true
            case 53: library.cropMode = false; dragRect = nil; return true   // esc
            case 8: library.cropMode = false; dragRect = nil; return true    // c again
            default: break
            }
        }
        switch event.keyCode {
        case 125: library.step(1); return true      // down
        case 126: library.step(-1); return true     // up
        default: return false
        }
    }
}

/// Routes key presses to the preview while it is on screen.
struct KeyCatcher: NSViewRepresentable {
    var onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Leave typing alone: a text field, or any sheet / other window on top of the preview.
            if let w = e.window, w != v.window { return e }
            if v.window?.attachedSheet != nil { return e }
            if v.window?.firstResponder is NSTextView { return e }
            return context.coordinator.onKey(e) ? nil : e
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onKey = onKey }
    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    final class Coordinator {
        var onKey: (NSEvent) -> Bool
        var monitor: Any?
        init(onKey: @escaping (NSEvent) -> Bool) { self.onKey = onKey }
    }
}

/// 100% view: an NSScrollView whose document is the image at native pixels, centred on
/// `anchor` when it appears, draggable with the mouse.
struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    let scale: CGFloat
    let anchor: CGPoint

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        let iv = DraggableImageView()
        iv.imageScaling = .scaleAxesIndependently
        scroll.documentView = iv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let iv = scroll.documentView as? DraggableImageView else { return }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let changed = iv.image !== image || iv.frame.size != size
        iv.image = image
        iv.frame = NSRect(origin: .zero, size: size)
        if changed || context.coordinator.lastAnchor != anchor {
            context.coordinator.lastAnchor = anchor
            DispatchQueue.main.async {
                let vis = scroll.contentView.bounds.size
                // SwiftUI tap coordinates are top-left origin; AppKit document is bottom-left.
                let x = size.width * anchor.x - vis.width / 2
                let y = size.height * (1 - anchor.y) - vis.height / 2
                scroll.contentView.scroll(to: NSPoint(x: max(0, min(x, size.width - vis.width)), y: max(0, min(y, size.height - vis.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastAnchor = CGPoint(x: -1, y: -1) }
}

final class DraggableImageView: NSImageView {
    private var last: NSPoint = .zero
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow; NSCursor.closedHand.push() }
    override func mouseUp(with event: NSEvent) { NSCursor.pop() }
    override func mouseDragged(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let p = event.locationInWindow
        var o = clip.bounds.origin
        o.x -= (p.x - last.x); o.y -= (p.y - last.y)
        clip.scroll(to: o); enclosingScrollView?.reflectScrolledClipView(clip)
        last = p
    }
}

/// AVKit player for video items in the preview. The player's own controls handle
/// play and pause; our keys still navigate and rate.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.player = AVPlayer(url: url)
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            v.player?.pause()
            v.player = AVPlayer(url: url)
        }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause(); v.player = nil }
}

/// Dims everything outside the crop rectangle, draws its outline.
struct CropOverlay: View {
    let fitted: CGRect
    let crop: CGRect?       // fractions
    var dim: Double = 0.55
    var body: some View {
        Canvas { ctx, size in
            guard let c = crop else { return }
            let r = CGRect(x: fitted.minX + c.minX * fitted.width, y: fitted.minY + c.minY * fitted.height, width: c.width * fitted.width, height: c.height * fitted.height)
            var outside = Path(fitted); outside.addRect(r)
            ctx.fill(outside, with: .color(.black.opacity(dim)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(r), with: .color(.white), lineWidth: 1)
        }.allowsHitTesting(false)
    }
}
