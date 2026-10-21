import SwiftUI

/// Structured Keywords panel + the current photo's keyword list.
struct KeywordsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var roots: [KeywordNode] = Keywords.load()
    @State private var query = ""
    @State private var addParents = true
    @State private var addSynonyms = false
    @State private var picked: Set<String> = []

    private var current: PhotoMeta? { library.current.flatMap { library.meta[$0.url] } }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Find keyword", text: $query).textFieldStyle(.roundedBorder)
                    Button("Edit List") { NSWorkspace.shared.open(Keywords.file) }
                    Button("Reload") { roots = Keywords.load() }
                }
                List {
                    if query.isEmpty {
                        OutlineGroup(roots, children: \.optionalChildren) { n in row(n) }
                    } else {
                        ForEach(roots.flatMap { $0.flattened() }.filter { $0.matches(query) }) { n in
                            HStack { row(n); Text(n.path.dropLast().joined(separator: " › ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                HStack {
                    Toggle("Add parents", isOn: $addParents)
                    Toggle("Add synonyms", isOn: $addSynonyms)
                }.font(.caption)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("To add (\(picked.count))").font(.caption.bold())
                List(picked.sorted(), id: \.self) { k in
                    HStack { Text(k); Spacer(); Button { picked.remove(k) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                }.frame(height: 160)
                Text(library.targets.count == 1 ? "Current keywords" : "Keywords on first of \(library.targets.count)").font(.caption.bold())
                List((current?.keywords ?? []), id: \.self) { k in
                    HStack { Text(k); Spacer(); Button { remove(k) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Remove from the current photo") }
                }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply to \(library.targets.count)") { apply(); dismiss() }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
                }
            }.frame(width: 280)
        }
        .padding(16).frame(width: 760, height: 480)
    }

    private func row(_ n: KeywordNode) -> some View {
        HStack {
            Text(n.term)
            if !n.synonyms.isEmpty { Text("= " + n.synonyms.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { pick(n) } label: { Image(systemName: picked.contains(n.term) ? "checkmark.circle.fill" : "plus.circle") }.buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(n) }
    }

    private func pick(_ n: KeywordNode) {
        if picked.contains(n.term) { picked.remove(n.term); return }
        picked.insert(n.term)
        if addParents { for p in n.path.dropLast() { picked.insert(p) } }
        if addSynonyms { for s in n.synonyms { picked.insert(s) } }
    }

    private func apply() {
        var t = IPTCTemplate()
        t.fields["keywords"] = picked.sorted().joined(separator: ", ")
        t.apply = ["keywords"]; t.keywordsAppend = true
        library.applyTemplate(t, to: library.targets)
    }

    private func remove(_ k: String) {
        guard let item = library.current, let m = library.meta[item.url] else { return }
        var t = IPTCTemplate()
        t.fields["keywords"] = m.keywords.filter { $0 != k }.joined(separator: ", ")
        t.apply = ["keywords"]; t.keywordsAppend = false
        library.applyTemplate(t, to: [item])
    }
}

extension KeywordNode {
    var optionalChildren: [KeywordNode]? { children.isEmpty ? nil : children }
}
