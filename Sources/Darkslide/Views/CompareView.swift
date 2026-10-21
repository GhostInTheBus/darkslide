import SwiftUI

/// Side-by-side compare of two to four selected frames. Click a frame to make it the
/// current one, so the rating and class keys apply to it; Esc or the button returns.
struct CompareView: View {
    @EnvironmentObject var library: Library
    private var items: [PhotoItem] { Array(library.visible.filter { library.selection.contains($0.id) }.prefix(4)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { library.compareMode = false } label: { Label("Back", systemImage: "square.grid.3x3") }
                Text("Compare \(items.count): click a frame to make it current, then rate with 1–5").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(8).background(.black.opacity(0.55)).foregroundStyle(.white).buttonStyle(.borderless)
            GeometryReader { geo in
                let cols = items.count <= 2 ? items.count : 2
                let rows = items.count <= 2 ? 1 : 2
                let w = geo.size.width / CGFloat(max(cols, 1)), h = geo.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        CompareCell(item: item, isCurrent: library.current?.id == item.id)
                            .frame(width: w, height: h)
                            .offset(x: CGFloat(i % cols) * w, y: CGFloat(i / cols) * h)
                            .onTapGesture { if let idx = library.visible.firstIndex(of: item) { library.currentIndex = idx } }
                    }
                }
            }
        }
        .background(Color.black)
    }
}

struct CompareCell: View {
    @EnvironmentObject var library: Library
    let item: PhotoItem
    let isCurrent: Bool
    @State private var image: NSImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(4) } else { ProgressView() }
            let m = library.meta[item.url] ?? PhotoMeta()
            HStack(spacing: 8) {
                Text(item.displayName).font(.caption.bold())
                if m.rating > 0 { Text(String(repeating: "★", count: m.rating)).font(.caption).foregroundStyle(.yellow) }
                if m.colorClass > 0 { Text(library.colorClasses.name(m.colorClass)).font(.caption2).padding(.horizontal, 4).background(Color(nsColor: NSColor(hex: library.colorClasses.hex(m.colorClass)))).cornerRadius(2) }
                Text(library.info(for: item).summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(6).background(.black.opacity(0.6)).foregroundStyle(.white)
        }
        .overlay(Rectangle().stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isCurrent ? 3 : 1))
        .onAppear {
            if let c = PreviewCache.shared.cached(item.url) { image = c } else { PreviewCache.shared.request(item.url) { img in image = img } }
        }
    }
}
