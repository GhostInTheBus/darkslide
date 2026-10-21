import Foundation

/// Once a day, ask GitHub for the latest release and remember it if it is newer than
/// this build. The UI shows a one-line notice with a link; nothing downloads itself.
enum UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/GhostInTheBus/darkslide/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/GhostInTheBus/darkslide/releases/latest")!

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Calls back on the main queue with the newer version string, or nil.
    static func check(force: Bool = false, completion: @escaping (String?) -> Void) {
        let d = UserDefaults.standard
        if !force, let last = d.object(forKey: "updateCheckedAt") as? Date, Date().timeIntervalSince(last) < 86400 {
            let known = d.string(forKey: "updateAvailable") ?? ""
            completion(isNewer(known, than: currentVersion) ? known : nil); return
        }
        var req = URLRequest(url: releasesAPI); req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var newer: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String {
                d.set(Date(), forKey: "updateCheckedAt")
                d.set(tag, forKey: "updateAvailable")
                if isNewer(tag, than: currentVersion) { newer = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")) }
            }
            DispatchQueue.main.async { completion(newer) }
        }.resume()
    }
}
