import SwiftUI

/// the legacy app's Find and Find & Replace, over the loaded metadata.
struct FindView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var replacement = ""
    @State private var keys: Set<String> = Set(IPTCTemplate.fieldKeys)
    @State private var caseSensitive = false
    @State private var filenames = true
    @State private var scopeAll = true
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find").font(.title3.bold())
            TextField("Text to find", text: $text).textFieldStyle(.roundedBorder)
            TextField("Replace with (for Replace)", text: $replacement).textFieldStyle(.roundedBorder)
            FlowLayout(spacing: 6) {
                Toggle("Filenames", isOn: $filenames).toggleStyle(.checkbox)
                ForEach(IPTCTemplate.fieldKeys, id: \.self) { k in
                    Toggle(IPTCTemplate.fieldLabels[k] ?? k, isOn: Binding(get: { keys.contains(k) }, set: { on in if on { keys.insert(k) } else { keys.remove(k) } })).toggleStyle(.checkbox)
                }
            }.font(.caption)
            HStack {
                Toggle("Case sensitive", isOn: $caseSensitive)
                Picker("Replace in", selection: $scopeAll) { Text("all visible").tag(true); Text("selection").tag(false) }.frame(width: 220)
            }.font(.callout)
            if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace") {
                    let n = library.replace(text, with: replacement, in: keys, caseSensitive: caseSensitive, scopeAll: scopeAll)
                    result = "Replaced in \(n) photo\(n == 1 ? "" : "s")"
                }.disabled(text.isEmpty)
                Button("Find") {
                    let n = library.find(text, in: keys, caseSensitive: caseSensitive, filenames: filenames)
                    result = "\(n) match\(n == 1 ? "" : "es") selected"
                }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }.padding(16).frame(width: 560)
    }
}

struct ClearFieldsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var keys: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clear IPTC fields on \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            FlowLayout(spacing: 6) {
                ForEach(IPTCTemplate.fieldKeys, id: \.self) { k in
                    Toggle(IPTCTemplate.fieldLabels[k] ?? k, isOn: Binding(get: { keys.contains(k) }, set: { on in if on { keys.insert(k) } else { keys.remove(k) } })).toggleStyle(.checkbox)
                }
            }.font(.caption)
            HStack { Button("All") { keys = Set(IPTCTemplate.fieldKeys) }; Button("None") { keys = [] } }.font(.caption)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clear") { library.clearFields(keys); dismiss() }.keyboardShortcut(.defaultAction).disabled(keys.isEmpty)
            }
        }.padding(16).frame(width: 520)
    }
}

import CoreLocation

struct GPSView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var place = ""
    @State private var busy = false

    private var parsed: (Double, Double)? {
        let parts = text.replacingOccurrences(of: ";", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), abs(a) <= 90, abs(b) <= 180 else { return nil }
        return (a, b)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GPS for \(library.targets.count) photo\(library.targets.count == 1 ? "" : "s")").font(.title3.bold())
            TextField("Latitude, longitude (paste from Maps: 34.6868, -118.1542)", text: $text).textFieldStyle(.roundedBorder)
            HStack {
                Button(busy ? "Looking up…" : "Reverse Geocode") { reverse() }.disabled(parsed == nil || busy)
                Text(place).font(.caption).foregroundStyle(.secondary)
            }
            Text("Reverse geocode fills City, State, Country and Location in the IPTC of these photos (Apple geocoder, needs network).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Remove GPS") { library.setGPS(latitude: nil, longitude: nil); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") { if let (a, b) = parsed { library.setGPS(latitude: a, longitude: b) }; dismiss() }.keyboardShortcut(.defaultAction).disabled(parsed == nil)
            }
        }.padding(16).frame(width: 520)
        .onAppear {
            if let c = library.current, let lat = library.info(for: c).latitude, let lon = library.info(for: c).longitude { text = String(format: "%.6f, %.6f", lat, lon) }
        }
    }

    private func reverse() {
        guard let (a, b) = parsed else { return }
        busy = true
        GPSView.reverseGeocode(lat: a, lon: b, library: library, items: library.targets) { p in busy = false; place = p }
    }

    /// Reverse geocode and write City / State / Country / Location into the given items.
    static func reverseGeocode(lat: Double, lon: Double, library: Library, items: [PhotoItem], done: ((String) -> Void)? = nil) {
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { marks, err in
            guard let pm = marks?.first else { done?(err?.localizedDescription ?? "no result"); return }
            let place = [pm.locality, pm.administrativeArea, pm.country].compactMap { $0 }.joined(separator: ", ")
            var t = IPTCTemplate()
            t.fields = ["city": pm.locality ?? "", "state": pm.administrativeArea ?? "", "country": pm.country ?? "", "location": pm.subLocality ?? pm.name ?? ""]
            t.apply = Set(t.fields.filter { !$0.value.isEmpty }.keys)
            library.applyTemplate(t, to: items)
            done?(place)
        }
    }
}
