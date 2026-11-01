import Foundation

public struct RACredentials: Codable, Equatable, Sendable {
    public var username: String
    public var apiKey: String
    public init(username: String, apiKey: String) { self.username = username; self.apiKey = apiKey }
}

public struct RAGameListEntry: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var consoleId: Int
    public var consoleName: String
    public var imageIcon: String
    public var numAchievements: Int
    public var hashes: [String]

    public init(id: Int, title: String, consoleId: Int, consoleName: String, imageIcon: String, numAchievements: Int, hashes: [String]) {
        self.id = id; self.title = title; self.consoleId = consoleId; self.consoleName = consoleName
        self.imageIcon = imageIcon; self.numAchievements = numAchievements; self.hashes = hashes
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", title = "Title", consoleId = "ConsoleID", consoleName = "ConsoleName"
        case imageIcon = "ImageIcon", numAchievements = "NumAchievements", hashes = "Hashes"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        consoleId = try c.decode(Int.self, forKey: .consoleId)
        consoleName = try c.decodeIfPresent(String.self, forKey: .consoleName) ?? ""
        imageIcon = try c.decodeIfPresent(String.self, forKey: .imageIcon) ?? ""
        numAchievements = try c.decodeIfPresent(Int.self, forKey: .numAchievements) ?? 0
        hashes = try c.decodeIfPresent([String].self, forKey: .hashes) ?? []
    }
}

public struct RAAchievement: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var description: String
    public var points: Int
    public var badgeName: String
    public var displayOrder: Int
    public var numAwarded: Int
    public var numAwardedHardcore: Int
    public var dateEarned: Date?
    public var dateEarnedHardcore: Date?

    public init(id: Int, title: String, description: String, points: Int, badgeName: String, displayOrder: Int,
                numAwarded: Int, numAwardedHardcore: Int, dateEarned: Date?, dateEarnedHardcore: Date?) {
        self.id = id; self.title = title; self.description = description; self.points = points
        self.badgeName = badgeName; self.displayOrder = displayOrder; self.numAwarded = numAwarded
        self.numAwardedHardcore = numAwardedHardcore; self.dateEarned = dateEarned; self.dateEarnedHardcore = dateEarnedHardcore
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", title = "Title", description = "Description", points = "Points", badgeName = "BadgeName"
        case displayOrder = "DisplayOrder", numAwarded = "NumAwarded", numAwardedHardcore = "NumAwardedHardcore"
        case dateEarned = "DateEarned", dateEarnedHardcore = "DateEarnedHardcore"
    }
}

public struct RAGameProgress: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var consoleId: Int
    public var consoleName: String
    public var imageIcon: String
    public var publisher: String?
    public var developer: String?
    public var genre: String?
    public var released: String?
    public var numDistinctPlayers: Int
    public var achievements: [RAAchievement]

    public init(id: Int, title: String, consoleId: Int, consoleName: String, imageIcon: String, publisher: String?, developer: String?,
                genre: String?, released: String?, numDistinctPlayers: Int, achievements: [RAAchievement]) {
        self.id = id; self.title = title; self.consoleId = consoleId; self.consoleName = consoleName; self.imageIcon = imageIcon
        self.publisher = publisher; self.developer = developer; self.genre = genre; self.released = released
        self.numDistinctPlayers = numDistinctPlayers; self.achievements = achievements
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", title = "Title", consoleId = "ConsoleID", consoleName = "ConsoleName", imageIcon = "ImageIcon"
        case publisher = "Publisher", developer = "Developer", genre = "Genre", released = "Released"
        case numDistinctPlayers = "NumDistinctPlayers", achievements = "Achievements"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        consoleId = try c.decode(Int.self, forKey: .consoleId)
        consoleName = try c.decodeIfPresent(String.self, forKey: .consoleName) ?? ""
        imageIcon = try c.decodeIfPresent(String.self, forKey: .imageIcon) ?? ""
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        developer = try c.decodeIfPresent(String.self, forKey: .developer)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        released = try c.decodeIfPresent(String.self, forKey: .released)
        numDistinctPlayers = try c.decodeIfPresent(Int.self, forKey: .numDistinctPlayers) ?? 0
        // RA sends achievements as an object keyed by ID, or as [] when the game has none;
        // our own cache stores them as an array.
        if let byID = try? c.decode([String: RAAchievement].self, forKey: .achievements) {
            achievements = byID.values.sorted { $0.displayOrder < $1.displayOrder }
        } else {
            achievements = try c.decodeIfPresent([RAAchievement].self, forKey: .achievements) ?? []
        }
    }
}

extension RAGameProgress {
    /// This game with its subsets' achievements added after its own, each description starting with the subset's name.
    /// Rarity is awarded / distinct players, so a subset's award counts are rescaled to this game's player count.
    public func merging(subsets: [(name: String, progress: RAGameProgress)]) -> RAGameProgress {
        var out = self
        for (i, sub) in subsets.enumerated() {
            let scale = sub.progress.numDistinctPlayers > 0 ? Double(numDistinctPlayers) / Double(sub.progress.numDistinctPlayers) : 0
            out.achievements += sub.progress.achievements.map { a in
                var a = a
                a.description = "[\(sub.name)] " + a.description
                a.displayOrder += 100_000 * (i + 1)  // after the base game's, subsets in order
                a.numAwarded = Int((Double(a.numAwarded) * scale).rounded())
                a.numAwardedHardcore = Int((Double(a.numAwardedHardcore) * scale).rounded())
                return a
            }
        }
        return out
    }
}

enum RADate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad RA date \(s)"))
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        return e
    }()
}
