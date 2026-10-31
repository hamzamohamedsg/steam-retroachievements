import Foundation

public struct MatchRecord: Codable, Equatable, Sendable {
    public var gameId: Int
    public var consoleId: Int
    public var manual: Bool
    /// The ROM's fingerprint when it was matched; nil if it couldn't be computed.
    public var hash: String?
    public var size: Int64
    public var modified: Double

    public init(gameId: Int, consoleId: Int, manual: Bool, hash: String?, size: Int64, modified: Double) {
        self.gameId = gameId; self.consoleId = consoleId; self.manual = manual
        self.hash = hash; self.size = size; self.modified = modified
    }
}

/// Remembered matches, keyed by ROM path, in one JSON file.
public final class MatchStore: @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    private var records: [String: MatchRecord]

    public init(file: URL) {
        self.file = file
        records = (try? JSONDecoder().decode([String: MatchRecord].self, from: Data(contentsOf: file))) ?? [:]
    }

    public func record(romPath: String) -> MatchRecord? {
        lock.withLock { records[romPath] }
    }

    public func save(romPath: String, _ record: MatchRecord) {
        lock.withLock {
            records[romPath] = record
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(records).write(to: file, options: .atomic)
        }
    }
}
