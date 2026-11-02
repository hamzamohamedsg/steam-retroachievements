import Foundation

/// Each game's RA playtime total as the app saw it over time, keyed by game id, in one JSON file:
/// RA only reports the total, and Steam also shows the last two weeks.
public final class PlaytimeHistory: @unchecked Sendable {
    struct Sample: Codable, Equatable { var at: Date; var seconds: Int }
    static let window: TimeInterval = 14 * 86_400
    let file: URL
    private let lock = NSLock()
    private var samples: [String: [Sample]]  // oldest first

    public init(file: URL) {
        self.file = file
        samples = (try? JSONDecoder().decode([String: [Sample]].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// Records `total` (seconds) as the game's playtime at `now` and returns the seconds played in the 14 days before it.
    public func lastTwoWeeks(gameId: Int, total: Int, lastPlayed: Date, now: Date = Date()) -> Int {
        let start = now - Self.window
        let first: Sample? = lock.withLock {
            let old = samples["\(gameId)"] ?? []
            var list = old
            if list.last?.seconds != total { list.append(Sample(at: now, seconds: total)) }
            // The newest sample from before the window is the total as it stood when the window opened; older ones aren't needed.
            if let i = list.lastIndex(where: { $0.at <= start }) { list.removeFirst(i) }
            if list != old {
                samples["\(gameId)"] = list
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(samples).write(to: file, options: .atomic)
            }
            return list.first
        }
        if lastPlayed < start { return 0 }
        // shortcut: until the app has a total from before the window, the whole total is the guess; exact 14 days after its first sync
        guard let first, first.at <= start else { return total }
        return max(0, total - first.seconds)
    }
}
