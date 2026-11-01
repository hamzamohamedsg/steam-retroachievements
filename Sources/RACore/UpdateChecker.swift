import Foundation

/// Asks GitHub for the latest release. Never throws: no network, rate limits and odd replies all mean "no update".
public enum UpdateChecker {
    /// Keep in step with CFBundleShortVersionString in Resources/Info.plist (UpdateCheckerTests checks).
    public static let currentVersion = "0.1.4"

    /// The release page when a newer version than `current` is out, otherwise nil.
    public static func newerRelease(current: String = currentVersion, transport: HTTPTransport = URLSessionTransport()) async -> (version: String, page: URL)? {
        let api = URL(string: "https://api.github.com/repos/hamzamohamedsg/steam-retroachievements/releases/latest")!
        guard let (data, status) = try? await transport.get(api), status == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let page = URL(string: release.html_url), page.scheme == "https",
              isNewer(release.tag_name, than: current) else { return nil }
        return (release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page)
    }

    struct Release: Decodable { let tag_name: String; let html_url: String }

    /// Compares dotted numbers ("v0.1.10" > "0.1.9"). A tag that isn't numbers counts as not newer.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) }
            return p.contains(nil) || p.isEmpty ? nil : p.map { $0! }
        }
        guard let a = parts(tag), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}
