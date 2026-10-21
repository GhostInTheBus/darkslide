import SwiftUI

/// Thumbnail strip shown under the preview: click to jump, auto-scrolls to the current frame.
struct FilmstripView: View {
    @EnvironmentObject var library: Library
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(library.visible.enumerated()), id: \.element.id) { i, item in
                        FilmstripCell(item: item, selected: i == library.currentIndex)
                            .id(item.id)
                            .onTapGesture { library.currentIndex = i; library.selection = [item.id]; library.prefetchAround(i) }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(height: 96)
            .background(.black.opacity(0.85))
            .onChange(of: library.currentIndex) { _, i in if let i, library.visible.indices.contains(i) { withAnimation { proxy.scrollTo(library.visible[i].id, anchor: .center) } } }
            .onAppear { if let i = library.currentIndex, library.visible.indices.contains(i) { proxy.scrollTo(library.visible[i].id, anchor: .center) } }
        }
    }
}

struct FilmstripCell: View {
    @EnvironmentObject var library: Library
    let item: PhotoItem
    let selected: Bool
    @State private var image: NSImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { Color.gray.opacity(0.3) }
            let m = library.meta[item.url] ?? PhotoMeta()
            if m.rating > 0 { Text(String(repeating: "★", count: m.rating)).font(.system(size: 8)).foregroundStyle(.yellow).padding(2) }
        }
        .frame(width: 112, height: 80)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .onAppear {
            if let c = ThumbnailCache.shared.cached(item.url) { image = c } else { ThumbnailCache.shared.request(item.url) { img in image = img } }
        }
    }
}
