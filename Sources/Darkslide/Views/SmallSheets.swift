import SwiftUI

struct DateRangeView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Date()
    @State private var selectOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Date range (capture time)").font(.title3.bold())
            DatePicker("From", selection: $from)
            DatePicker("To", selection: $to)
            Picker("", selection: $selectOnly) { Text("Filter the contact sheet").tag(false); Text("Select matching photos").tag(true) }.pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if selectOnly {
                        library.selection = Set(library.visible.filter { if let d = library.captureDate(of: $0) { return d >= from && d <= to } else { return false } }.map(\.id))
                    } else { library.filterDateFrom = from; library.filterDateTo = to }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 420)
        .onAppear {
            let dates = library.visible.compactMap { library.captureDate(of: $0) }
            if let lo = dates.min(), let hi = dates.max() { from = lo; to = hi }
        }
    }
}

struct SelectRangeView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var from = 1
    @State private var to = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select range by position (1 to \(library.visible.count))").font(.title3.bold())
            HStack { TextField("From", value: $from, format: .number).frame(width: 80); Text("to"); TextField("To", value: $to, format: .number).frame(width: 80) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Select") { library.selectRange(from: from, to: to); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 360)
        .onAppear { from = (library.currentIndex ?? 0) + 1; to = library.visible.count }
    }
}

struct RemapView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var ratings: [Int: Int] = Dictionary(uniqueKeysWithValues: (0...5).map { ($0, $0) })
    @State private var classes: [Int: Int] = Dictionary(uniqueKeysWithValues: (0...8).map { ($0, $0) })
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remap on \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading) {
                    Text("Ratings").font(.caption.bold())
                    ForEach(0...5, id: \.self) { r in
                        HStack { Text(r == 0 ? "none" : String(repeating: "★", count: r)).frame(width: 60, alignment: .trailing); Text("→")
                            Picker("", selection: Binding(get: { ratings[r] ?? r }, set: { ratings[r] = $0 })) { ForEach(0...5, id: \.self) { Text($0 == 0 ? "none" : "\($0)★").tag($0) } }.labelsHidden().frame(width: 80) }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Color classes").font(.caption.bold())
                    ForEach(0...8, id: \.self) { c in
                        HStack { Text(c == 0 ? "none" : library.colorClasses.name(c)).frame(width: 70, alignment: .trailing); Text("→")
                            Picker("", selection: Binding(get: { classes[c] ?? c }, set: { classes[c] = $0 })) { ForEach(0...8, id: \.self) { Text($0 == 0 ? "none" : library.colorClasses.name($0)).tag($0) } }.labelsHidden().frame(width: 100) }
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Remap") { library.remap(ratings: ratings, classes: classes); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 520)
    }
}

struct DeleteMetadataView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var xmp = false
    @State private var iptc = false
    @State private var exif = false
    @State private var gps = true
    @State private var keepOrientation = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete metadata from \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            Toggle("GPS only", isOn: $gps)
            Toggle("All XMP (ratings, labels, captions)", isOn: $xmp)
            Toggle("All IPTC", isOn: $iptc)
            Toggle("All EXIF (camera data)", isOn: $exif)
            Toggle("Keep orientation when deleting EXIF", isOn: $keepOrientation).disabled(!exif)
            Text("This rewrites the files. There is no undo.").font(.caption).foregroundStyle(.red)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete") { library.deleteMetadata(xmp: xmp, iptc: iptc, exif: exif, gps: gps, keepOrientation: keepOrientation); dismiss() }.disabled(!(xmp || iptc || exif || gps)) }
        }.padding(16).frame(width: 420)
    }
}

struct SetDPIView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var dpi = 300
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set resolution on \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            HStack { TextField("", value: $dpi, format: .number).frame(width: 80); Text("pixels per inch") }
            Text("Changes only the resolution tag, not the pixels.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Set") { library.setDPI(dpi); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 360)
    }
}
