import AppKit
import SwiftUI

/// AppKit NSCollectionView wrapped for SwiftUI. SwiftUI's LazyVGrid stutters past a
/// couple thousand cells; this does not.
struct ThumbnailGridView: NSViewRepresentable {
    @EnvironmentObject var library: Library

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let cv = GridCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [NSColor(white: 0.12, alpha: 1)]
        cv.register(ThumbnailCell.self, forItemWithIdentifier: ThumbnailCell.identifier)
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.onKey = { _ in false }   // the app-level monitor handles cull keys before they get here
        cv.onDoubleClick = { [weak library] in if library?.isPreviewing == false { library?.togglePreview() } }
        cv.contextMenuProvider = { [weak library] in
            guard let library else { return nil }
            let menu = NSMenu()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let i = MenuItem(title: title, action: #selector(MenuItem.fire), keyEquivalent: ""); i.handler = action; i.target = i; menu.addItem(i)
            }
            add("Preview") { library.togglePreview() }
            if library.selection.count >= 2 { add("Compare Selected (X)") { library.startCompare() } }
            add("Open in Editor") { library.openInEditor() }
            add("IPTC Info…") { library.showCaption = true }
            add("Rename…") { library.showRename = true }
            menu.addItem(.separator())
            let rating = NSMenu(); let cls = NSMenu()
            for r in 0...5 { let i = MenuItem(title: r == 0 ? "None" : String(repeating: "★", count: r), action: #selector(MenuItem.fire), keyEquivalent: ""); i.handler = { library.setRating(r) }; i.target = i; rating.addItem(i) }
            for c in 0...8 { let i = MenuItem(title: c == 0 ? "None" : library.colorClasses.name(c), action: #selector(MenuItem.fire), keyEquivalent: ""); i.handler = { library.setColorClass(c) }; i.target = i; cls.addItem(i) }
            let ri = NSMenuItem(title: "Rating", action: nil, keyEquivalent: ""); ri.submenu = rating; menu.addItem(ri)
            let ci = NSMenuItem(title: "Color Class", action: nil, keyEquivalent: ""); ci.submenu = cls; menu.addItem(ci)
            add("Toggle Tag") { library.toggleTag() }
            menu.addItem(.separator())
            add("Rotate Clockwise") { library.rotate(clockwise: true) }
            add("Rotate Counterclockwise") { library.rotate(clockwise: false) }
            menu.addItem(.separator())
            if let cur = library.current, let m = library.meta[cur.url] {
                add("Select Similar Rating (\(m.rating))") { library.selectSimilar(rating: m.rating) }
                add("Select Similar Color Class") { library.selectSimilar(colorClass: m.colorClass) }
            }
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(library.targets.map(\.url)) }
            menu.addItem(.separator())
            add("Move to Trash") { library.moveToTrash() }
            return menu
        }
        context.coordinator.collectionView = cv

        DispatchQueue.main.async { cv.window?.makeFirstResponder(cv) }
        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        guard let cv = co.collectionView, let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let size = library.thumbSize
        if layout.itemSize.width != size {
            layout.itemSize = NSSize(width: size, height: size + 18)
            layout.invalidateLayout()
        }
        let visible = library.visible
        co.colorClasses = library.colorClasses
        let sameFiles = co.items.count == visible.count && zip(co.items, visible).allSatisfy { $0.id == $1.id }
        if sameFiles && co.items != visible {
            // Same files, some rewritten on disk (mtime changed): refresh just those cells.
            let rewritten = Set(zip(co.items, visible).enumerated().compactMap { $1.0 != $1.1 ? IndexPath(item: $0, section: 0) : nil })
            co.items = visible
            cv.reloadItems(at: rewritten)
        }
        if !sameFiles {
            co.items = visible
            co.meta = library.meta
            cv.reloadData()
            DispatchQueue.main.async { if !(cv.window?.firstResponder is NSTextView) || library.quickSearch.isEmpty { cv.window?.makeFirstResponder(cv) } }
            if let i = library.currentIndex, visible.indices.contains(i) {
                let ip = IndexPath(item: i, section: 0)
                cv.selectionIndexPaths = [ip]
                cv.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
            }
        } else if co.reloadToken != library.reloadToken {
            co.reloadToken = library.reloadToken
            co.meta = library.meta
            cv.reloadData()
        } else {
            if co.meta != library.meta {
                // Refresh only the cells whose metadata changed.
                var changed = Set<IndexPath>()
                for (i, item) in visible.enumerated() where co.meta[item.url] != library.meta[item.url] {
                    changed.insert(IndexPath(item: i, section: 0))
                }
                co.meta = library.meta
                for ip in changed { (cv.item(at: ip) as? ThumbnailCell)?.apply(meta: library.meta[visible[ip.item].url], classes: co.colorClasses) }
            }
            if let i = library.currentIndex, visible.indices.contains(i), !library.isPreviewing {
                // Keep the grid cursor in step with preview navigation.
                let ip = IndexPath(item: i, section: 0)
                if cv.selectionIndexPaths != [ip] && library.selection == [visible[i].id] {
                    cv.selectionIndexPaths = [ip]
                    cv.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let library: Library
        var items: [PhotoItem] = []
        var meta: [URL: PhotoMeta] = [:]
        var colorClasses = ColorClassSet()
        var reloadToken = 0
        weak var collectionView: NSCollectionView?
        init(library: Library) { self.library = library }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: ThumbnailCell.identifier, for: indexPath) as! ThumbnailCell
            let item = items[indexPath.item]
            cell.configure(with: item)
            cell.apply(meta: meta[item.url], classes: colorClasses)
            return cell
        }

        func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
        }
        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection(cv) }

        private func syncSelection(_ cv: NSCollectionView) {
            let paths = cv.selectionIndexPaths
            library.selection = Set(paths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            if let last = paths.sorted().last { library.currentIndex = last.item }
        }
    }
}

/// Collection view subclass that gives cull/navigation shortcuts first refusal.
final class MenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

final class GridCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)        // selection first, so the preview opens on this item
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onDoubleClick?()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click selects the item under the mouse first, like Finder.
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p), !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
            delegate?.collectionView?(self, didSelectItemsAt: [ip])
        }
        return contextMenuProvider?()
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor final class ThumbnailCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")
    private let imageBox = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let stars = NSTextField(labelWithString: "")
    private let classBar = NSView()
    private let tagMark = NSTextField(labelWithString: "✓")
    private var itemURL: URL?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        imageBox.imageScaling = .scaleProportionallyUpOrDown
        imageBox.imageAlignment = .alignCenter
        imageBox.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10)
        label.textColor = .lightGray
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .boldSystemFont(ofSize: 9)
        badge.textColor = .white
        badge.backgroundColor = NSColor(white: 0, alpha: 0.6)
        badge.drawsBackground = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        stars.font = .systemFont(ofSize: 10)
        stars.textColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0.2, alpha: 1)
        stars.translatesAutoresizingMaskIntoConstraints = false
        classBar.wantsLayer = true
        classBar.layer?.cornerRadius = 2
        classBar.translatesAutoresizingMaskIntoConstraints = false
        tagMark.font = .boldSystemFont(ofSize: 12)
        tagMark.textColor = .white
        tagMark.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85)
        tagMark.drawsBackground = true
        tagMark.alignment = .center
        tagMark.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(imageBox); v.addSubview(label); v.addSubview(badge); v.addSubview(stars); v.addSubview(classBar); v.addSubview(tagMark)
        NSLayoutConstraint.activate([
            imageBox.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            imageBox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            imageBox.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: imageBox.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
            label.heightAnchor.constraint(equalToConstant: 14),
            badge.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            tagMark.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            tagMark.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            tagMark.widthAnchor.constraint(equalToConstant: 18),
            stars.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -1),
            stars.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            classBar.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -3),
            classBar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            classBar.widthAnchor.constraint(equalToConstant: 28),
            classBar.heightAnchor.constraint(equalToConstant: 6),
        ])
        view = v
    }

    func configure(with item: PhotoItem) {
        itemURL = item.url
        label.stringValue = item.displayName
        badge.stringValue = item.affinityOnly ? " AFFINITY ONLY " : item.isVideo ? " ▶ VIDEO " : item.editOf != nil ? " EDIT " : item.sidecarJPEG != nil ? " R+J " : (item.isRaw ? " RAW " : "")
        badge.backgroundColor = item.affinityOnly ? NSColor.systemOrange.withAlphaComponent(0.85) : NSColor(white: 0, alpha: 0.6)
        badge.toolTip = item.affinityOnly ? "Only an Affinity document exists for this photo. Save a TIFF." : nil
        badge.isHidden = badge.stringValue.isEmpty
        if let img = ThumbnailCache.shared.cached(item.url) {
            imageBox.image = img
        } else {
            imageBox.image = nil
            ThumbnailCache.shared.request(item.url) { [weak self] img in
                guard let self, self.itemURL == item.url else { return }
                self.imageBox.image = img
            }
        }
    }

    func apply(meta: PhotoMeta?, classes: ColorClassSet) {
        let m = meta ?? PhotoMeta()
        stars.stringValue = m.rating > 0 ? String(repeating: "★", count: m.rating) : ""
        tagMark.isHidden = !m.tagged
        if (1...8).contains(m.colorClass) {
            classBar.isHidden = false
            classBar.layer?.backgroundColor = NSColor(hex: classes.hex(m.colorClass)).cgColor
            classBar.toolTip = classes.name(m.colorClass)
        } else {
            classBar.isHidden = true
        }
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateHighlight() }
    }
    private func updateHighlight() {
        view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        itemURL = nil
        imageBox.image = nil
    }
}

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0x888888
        self.init(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
