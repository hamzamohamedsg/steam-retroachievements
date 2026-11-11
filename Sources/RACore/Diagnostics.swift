import Foundation

/// Helpers for Copy Diagnostics. Its text ends up in public bug reports, and the page is Steam's, so it's scrubbed before it crosses the bridge.
enum Diagnostics {
    static let logLines = 100

    /// Removes URL query strings (the RetroAchievements key travels in one), the home folder (it names the OS account) and `secrets`.
    static func scrub(_ text: String, home: String, secrets: [String]) -> String {
        var out = text
            .replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]*)\?\S*"#, with: "$1?[removed]", options: .regularExpression)
            .replacingOccurrences(of: #"[?&][^\s=&?]+=\S*"#, with: "?[removed]", options: .regularExpression)  // a URL without its scheme
        for form in homeForms(home) { out = out.replacingOccurrences(of: form, with: "~", options: .caseInsensitive) }
        for secret in secrets where !secret.isEmpty { out = out.replacingOccurrences(of: secret, with: "[removed]", options: .caseInsensitive) }
        return out
    }

    /// Every way a log line can spell the home folder, longest first so that `/var/home/me` goes before `/home/me`.
    private static func homeForms(_ home: String) -> [String] {
        var path = home.replacingOccurrences(of: "\\", with: "/")
        if path.hasSuffix("/") { path.removeLast() }
        if path.range(of: #"^/[A-Za-z]:"#, options: .regularExpression) != nil { path.removeFirst() }  // Foundation's "/C:/Users/me"
        guard !path.isEmpty else { return [] }
        var roots = [path]
        // Bazzite and other atomic Fedoras: /home is a link to /var/home, and logs can show either.
        if path.hasPrefix("/var/home/") { roots.append(String(path.dropFirst(4))) } else if path.hasPrefix("/home/") { roots.append("/var" + path) }
        return roots.flatMap { root in
            [root, root.replacingOccurrences(of: "/", with: "\\"), root.replacingOccurrences(of: "/", with: "\\\\"),
             root.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? root]
        }.sorted { $0.count > $1.count }
    }

    /// The last lines of the log, or nil when there's no log file.
    // shortcut: reads the whole file to keep its end; read only the tail if logs ever reach tens of MB
    static func lastLines(of file: URL?) -> String? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(logLines).joined(separator: "\n")
    }

    static var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(macOS)
        return "macOS \(version)"
        #elseif os(Windows)
        return "Windows \(version)"
        #else
        // PRETTY_NAME tells SteamOS from Bazzite, which the kernel version doesn't.
        let name = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8))?
            .split(separator: "\n").first { $0.hasPrefix("PRETTY_NAME=") }?
            .dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return "\(name ?? "Linux") (\(version))"
        #endif
    }
}
