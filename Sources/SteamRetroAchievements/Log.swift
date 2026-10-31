import Foundation

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let data = home.appendingPathComponent("Library/Application Support/steam-retroachievements")
    static let log = home.appendingPathComponent("Library/Logs/steam-retroachievements.log")
    static let roms = home.appendingPathComponent("ROMs")
}

enum Log {
    static func info(_ s: String) { write("INFO", s) }
    static func error(_ s: String) { write("ERROR", s) }

    private static let queue = DispatchQueue(label: "steam-retroachievements.log")

    private static func write(_ level: String, _ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(msg)\n"
        queue.async {
            let url = AppPaths.log
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
