import SwiftUI

/// legacy-style filter strip: stars, color classes, tagged. Click to toggle, empty = show all.
struct FilterBar: View {
    @EnvironmentObject var library: Library
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(0...5, id: \.self) { r in
                    Button {
                        if library.filterRatings.contains(r) { library.filterRatings.remove(r) } else { library.filterRatings.insert(r) }
                    } label: {
                        Text(r == 0 ? "0" : String(repeating: "★", count: r))
                            .font(.caption)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(library.filterRatings.contains(r) ? Color.accentColor.opacity(0.5) : Color.clear)
                            .cornerRadius(3)
                    }.buttonStyle(.plain)
                }
            }
            Divider().frame(height: 14)
            HStack(spacing: 4) {
                ForEach(0...8, id: \.self) { c in
                    Button {
                        if library.filterClasses.contains(c) { library.filterClasses.remove(c) } else { library.filterClasses.insert(c) }
                    } label: {
                        Circle()
                            .fill(c == 0 ? Color.gray.opacity(0.3) : Color(nsColor: NSColor(hex: library.colorClasses.hex(c))))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.white, lineWidth: library.filterClasses.contains(c) ? 2 : 0))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .help(c == 0 ? "No class" : "\(library.colorClasses.name(c)) (⌘\(c))")
                }
            }
            Divider().frame(height: 14)
            Toggle("Tagged", isOn: $library.filterTaggedOnly).toggleStyle(.checkbox).font(.caption)
            if library.filtersActive {
                Button("Clear") { library.filterRatings = []; library.filterClasses = []; library.filterTaggedOnly = false }
                    .font(.caption).buttonStyle(.link)
            }
            if library.filterDateFrom != nil || library.filterDateTo != nil {
                Button("Date range ✕") { library.filterDateFrom = nil; library.filterDateTo = nil }.font(.caption).buttonStyle(.link)
            }
            Spacer()
            TextField("Quick search", text: $library.quickSearch).textFieldStyle(.roundedBorder).frame(width: 180).font(.caption)
                .focused($searchFocused)
                .onSubmit { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
                .onExitCommand { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
            Toggle("Advance after rating", isOn: $library.advanceAfterRating).toggleStyle(.checkbox).font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }
}
