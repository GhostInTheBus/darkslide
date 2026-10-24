import SwiftUI

/// the legacy app's Import GPS Coordinates: load a track (GPX file, or the phone's OwnTracks history
/// from Home Assistant), preview the matches, write them.
struct GPSTrackView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var track: GPSTrack?
    @State private var status = ""
    @State private var toleranceMinutes = 10.0
    @State private var cameraOffsetMinutes = 0.0       // camera clock minus true time
    @State private var interpolate = true
    @State private var overwrite = false
    @State private var reverseGeocode = false
    @State private var busy = false
    @State private var haEntity = UserDefaults.standard.string(forKey: "haEntity") ?? "device_tracker."
    @State private var haURL = UserDefaults.standard.string(forKey: "haURL") ?? "http://homeassistant.local:8123"
    @State private var haToken = UserDefaults.standard.string(forKey: "haToken") ?? ""
    @State private var cameraZone = UserDefaults.standard.string(forKey: "cameraZone") ?? TimeZone.current.identifier
    private static let zones = ["America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "Pacific/Honolulu", "America/Anchorage", "UTC", "Europe/London", "Europe/Paris", "Asia/Tokyo"]

    /// Camera clock reads are wall-clock in the camera's zone; the track is absolute.
    /// Files with no EXIF (some compacts) fall back to their file date, which is already absolute.
    private func captureTime(_ item: PhotoItem) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: cameraZone) ?? .current
        if let s = library.meta[item.url]?.captureDate, let d = f.date(from: s) { return d }
        if let d = library.info(for: item).captureDate {
            // CaptureInfo parsed in the Mac's zone; re-express in the camera's zone.
            let g = DateFormatter(); g.locale = f.locale; g.dateFormat = f.dateFormat
            return f.date(from: g.string(from: d)) ?? d
        }
        return (try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
    }

    private var targets: [PhotoItem] { library.selection.isEmpty ? library.visible : library.targets }

    struct Match: Identifiable { let id: URL; let name: String; let time: Date?; let lat: Double?; let lon: Double?; let gap: TimeInterval?; let hasGPS: Bool }

    private var matches: [Match] {
        guard let track else { return [] }
        return targets.map { item in
            let info = library.info(for: item)
            let t = captureTime(item)
            let adj = t.map { $0.addingTimeInterval(-cameraOffsetMinutes * 60) }
            let pos = adj.flatMap { track.position(at: $0, tolerance: toleranceMinutes * 60, interpolate: interpolate) }
            return Match(id: item.url, name: item.displayName, time: t, lat: pos?.lat, lon: pos?.lon, gap: pos?.gap, hasGPS: info.latitude != nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import GPS coordinates for \(targets.count) photo\(targets.count == 1 ? "" : "s")").font(.title3.bold())
            GroupBox("Track") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Open GPX…") { openGPX() }
                        Text(track.map { "\($0.name): \($0.points.count) points, \(fmt($0.first)) → \(fmt($0.last))" } ?? "No track loaded").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Home Assistant URL", text: $haURL).frame(width: 200)
                        SecureField("Long-lived token", text: $haToken).frame(width: 160)
                        TextField("device_tracker.phone", text: $haEntity).frame(width: 170)
                        Button(busy ? "Fetching…" : "Fetch phone track") { fetchHA() }.disabled(busy || haToken.isEmpty || haEntity.count < 16)
                    }.font(.caption)
                    Text("The phone track covers the capture-time span of these photos, padded by the tolerance. Needs a long-lived access token from your HA profile page. Camera zone is the zone the camera clock was set to, wherever you were; if you changed the clock mid-trip, run this per leg on a selection.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                Picker("Camera zone", selection: $cameraZone) { ForEach(GPSTrackView.zones, id: \.self) { Text($0.replacingOccurrences(of: "America/", with: "").replacingOccurrences(of: "_", with: " ")).tag($0) } }.frame(width: 190)
                HStack { Text("Tolerance"); TextField("", value: $toleranceMinutes, format: .number).frame(width: 50); Text("min") }
                HStack { Text("Camera clock is"); TextField("", value: $cameraOffsetMinutes, format: .number).frame(width: 50); Text("min fast") }
                Toggle("Interpolate", isOn: $interpolate)
                Toggle("Overwrite existing GPS", isOn: $overwrite)
                Toggle("Reverse geocode", isOn: $reverseGeocode)
            }.font(.callout)
            let m = matches
            Table(m) {
                TableColumn("Photo") { Text($0.name) }
                TableColumn("Captured") { Text($0.time.map { CaptureInfo.dateFormatter.string(from: $0) } ?? "no time").foregroundStyle(.secondary) }
                TableColumn("Position") { r in
                    if let lat = r.lat, let lon = r.lon { Text(String(format: "%.5f, %.5f", lat, lon)).foregroundStyle(r.hasGPS && !overwrite ? .secondary : .primary) }
                    else { Text(track == nil ? "" : "no match").foregroundStyle(.red) }
                }
                TableColumn("Gap") { r in Text(r.gap.map { String(format: "%.0f s", $0) } ?? "") }.width(60)
                TableColumn("") { r in Text(r.hasGPS ? (overwrite ? "will overwrite" : "has GPS, kept") : "") .font(.caption).foregroundStyle(.secondary) }.width(110)
            }.frame(minHeight: 200)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                let n = m.filter { $0.lat != nil && (overwrite || !$0.hasGPS) }.count
                Text("\(n) photo\(n == 1 ? "" : "s") will get coordinates").font(.caption)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Write GPS") { write(m) }.keyboardShortcut(.defaultAction).disabled(n == 0)
            }
        }
        .padding(16).frame(width: 820, height: 560)
        .onDisappear {
            UserDefaults.standard.set(cameraZone, forKey: "cameraZone"); UserDefaults.standard.set(haEntity, forKey: "haEntity"); UserDefaults.standard.set(haURL, forKey: "haURL"); UserDefaults.standard.set(haToken, forKey: "haToken")
        }
    }

    private func fmt(_ d: Date?) -> String { d.map { CaptureInfo.dateFormatter.string(from: $0) } ?? "?" }

    private func openGPX() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.xml, .data]; p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url else { return }
        do { track = try GPSTrack.loadGPX(u); status = track!.points.isEmpty ? "No timed track points in that file" : "" }
        catch { status = "GPX: \(error.localizedDescription)" }
    }

    private func fetchHA() {
        let times = targets.compactMap { captureTime($0) }
        guard let lo = times.min(), let hi = times.max() else { status = "These photos have no capture times"; return }
        busy = true
        let pad = toleranceMinutes * 60 + abs(cameraOffsetMinutes) * 60
        GPSTrack.fromHomeAssistant(baseURL: haURL, token: haToken, entity: haEntity, from: lo.addingTimeInterval(-pad), to: hi.addingTimeInterval(pad)) { r in
            busy = false
            switch r {
            case .success(let t): track = t; status = t.points.isEmpty ? "Home Assistant has no positions for that span (recorder keeps 10 days by default)" : ""
            case .failure(let e): status = "Home Assistant: \(e.localizedDescription)"
            }
        }
    }

    private func write(_ m: [Match]) {
        var done = 0
        for r in m where r.lat != nil && (overwrite || !r.hasGPS) {
            guard let item = library.items.first(where: { $0.url == r.id }) else { continue }
            var files = [item.url]; if let j = item.sidecarJPEG { files.append(j) }
            MetadataStore.shared.writeGPS(latitude: r.lat, longitude: r.lon, files: files) { res in
                DispatchQueue.main.async {
                    if !res.ok { library.lastError = "GPS \(item.displayName): \(res.error)" }
                    library.infoCache[item.url] = nil
                    done += 1
                }
            }
            if reverseGeocode { GPSView.reverseGeocode(lat: r.lat!, lon: r.lon!, library: library, items: [item]) }
        }
        status = "Writing…"
        dismiss()
    }
}
