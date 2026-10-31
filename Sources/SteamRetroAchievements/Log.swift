import Foundation

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(macOS)
    static let data = home.appendingPathComponent("Library/Application Support/steam-retroachievements")
    static let log = home.appendingPathComponent("Library/Logs/steam-retroachievements.log")
    static let app: URL? = Bundle.main.bundleURL
    #else
    #if os(Windows)
    static let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? home.appendingPathComponent("AppData/Local").path)
        .appendingPathComponent("steam-retroachievements")
    #else
    static let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path)
        .appendingPathComponent("steam-retroachievements")
    #endif
    static let log = data.appendingPathComponent("steam-retroachievements.log")
    static let app: URL? = nil
    #endif

    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// The Steam-side script: in the app bundle on macOS, next to the program elsewhere.
    static func injectScript() -> String {
        let url = Bundle.main.url(forResource: "inject", withExtension: "js")
            ?? URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("inject.js")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

enum Log {
    static func info(_ s: String) { write("INFO", s) }
    static func error(_ s: String) { write("ERROR", s) }

    private static let queue = DispatchQueue(label: "steam-retroachievements.log")

    private static func write(_ level: String, _ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(msg)\n"
        #if !os(macOS)
        print(line, terminator: "")  // no menu bar here: the terminal is where people look
        #endif
        queue.async {
            let url = AppPaths.log
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
