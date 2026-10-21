import Foundation

/// A GPS track: time-stamped points from a GPX file or from Home Assistant's history of
/// an OwnTracks device. Photos are matched to the track by capture time, interpolating
/// between the two nearest points, the way the legacy app's Import GPS Coordinates does.
struct TrackPoint { let time: Date; let lat: Double; let lon: Double; let ele: Double? }

struct GPSTrack {
    var points: [TrackPoint]      // sorted by time
    var name: String

    var first: Date? { points.first?.time }
    var last: Date? { points.last?.time }

    /// Position at `t`, if the track covers it within `tolerance` seconds of a point.
    func position(at t: Date, tolerance: TimeInterval, interpolate: Bool) -> (lat: Double, lon: Double, ele: Double?, gap: TimeInterval)? {
        guard !points.isEmpty else { return nil }
        // Binary search for the first point at or after t.
        var lo = 0, hi = points.count
        while lo < hi { let mid = (lo + hi) / 2; if points[mid].time < t { lo = mid + 1 } else { hi = mid } }
        let after = lo < points.count ? points[lo] : nil
        let before = lo > 0 ? points[lo - 1] : nil
        switch (before, after) {
        case (nil, nil): return nil
        case (let b?, nil):
            let gap = t.timeIntervalSince(b.time); return gap <= tolerance ? (b.lat, b.lon, b.ele, gap) : nil
        case (nil, let a?):
            let gap = a.time.timeIntervalSince(t); return gap <= tolerance ? (a.lat, a.lon, a.ele, gap) : nil
        case (let b?, let a?):
            let gb = t.timeIntervalSince(b.time), ga = a.time.timeIntervalSince(t)
            if interpolate && gb <= tolerance && ga <= tolerance && a.time > b.time {
                let f = gb / a.time.timeIntervalSince(b.time)
                let ele: Double? = (b.ele != nil && a.ele != nil) ? b.ele! + (a.ele! - b.ele!) * f : nil
                return (b.lat + (a.lat - b.lat) * f, b.lon + (a.lon - b.lon) * f, ele, min(gb, ga))
            }
            let near = gb <= ga ? b : a
            let gap = min(gb, ga)
            return gap <= tolerance ? (near.lat, near.lon, near.ele, gap) : nil
        }
    }

    // MARK: GPX

    static func loadGPX(_ url: URL) throws -> GPSTrack {
        let data = try Data(contentsOf: url)
        let parser = GPXParser()
        let x = XMLParser(data: data); x.delegate = parser; x.parse()
        return GPSTrack(points: parser.points.sorted { $0.time < $1.time }, name: url.lastPathComponent)
    }

    private final class GPXParser: NSObject, XMLParserDelegate {
        var points: [TrackPoint] = []
        private var lat = 0.0, lon = 0.0, ele: Double?, time: Date?
        private var text = ""
        private var inPoint = false
        private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
        private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "trkpt" || name == "wpt" || name == "rtept" {
                inPoint = true; ele = nil; time = nil
                lat = Double(attributes["lat"] ?? "") ?? 0; lon = Double(attributes["lon"] ?? "") ?? 0
            }
            text = ""
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard inPoint else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "ele": ele = Double(t)
            case "time": time = GPXParser.iso.date(from: t) ?? GPXParser.isoFrac.date(from: t)
            case "trkpt", "wpt", "rtept":
                if let time { points.append(TrackPoint(time: time, lat: lat, lon: lon, ele: ele)) }
                inPoint = false
            default: break
            }
        }
    }

    // MARK: Home Assistant (OwnTracks phone history)

    /// Pull a device_tracker's history from Home Assistant's REST API.
    static func fromHomeAssistant(baseURL: String, token: String, entity: String, from: Date, to: Date,
                                  completion: @escaping (Result<GPSTrack, Error>) -> Void) {
        let iso = ISO8601DateFormatter()
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: base + "/api/history/period/" + iso.string(from: from)) else {
            DispatchQueue.main.async { completion(.failure(NSError(domain: "darkslide", code: 6, userInfo: [NSLocalizedDescriptionKey: "Home Assistant URL is not valid"]))) }; return
        }
        comps.queryItems = [URLQueryItem(name: "filter_entity_id", value: entity), URLQueryItem(name: "end_time", value: iso.string(from: to)),
                            URLQueryItem(name: "minimal_response", value: nil), URLQueryItem(name: "no_attributes", value: nil)]
        // minimal_response strips attributes, which we need; drop those two flags.
        comps.queryItems = Array(comps.queryItems!.prefix(2))
        guard let reqURL = comps.url else { DispatchQueue.main.async { completion(.failure(NSError(domain: "darkslide", code: 6, userInfo: [NSLocalizedDescriptionKey: "Home Assistant URL is not valid"]))) }; return }
        var req = URLRequest(url: reqURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { DispatchQueue.main.async { completion(.failure(err)) }; return }
            guard let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[[String: Any]]] else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { completion(.failure(NSError(domain: "darkslide", code: code, userInfo: [NSLocalizedDescriptionKey: "Home Assistant returned HTTP \(code)"]))) }
                return
            }
            var pts: [TrackPoint] = []
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            for state in arr.first ?? [] {
                guard let a = state["attributes"] as? [String: Any], let lat = a["latitude"] as? Double, let lon = a["longitude"] as? Double,
                      let ts = state["last_updated"] as? String, let t = f.date(from: ts) ?? f2.date(from: ts) else { continue }
                pts.append(TrackPoint(time: t, lat: lat, lon: lon, ele: a["altitude"] as? Double))
            }
            DispatchQueue.main.async { completion(.success(GPSTrack(points: pts.sorted { $0.time < $1.time }, name: entity))) }
        }.resume()
    }
}
