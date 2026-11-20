import Foundation

/// A game's leaderboard, from `API_GetGameLeaderboards`.
public struct RALeaderboard: Codable, Equatable, Sendable {
    public var id: Int
    /// Lower scores rank higher (times).
    public var rankAsc: Bool
    public var title, description, format: String
    public var state: String?
    public var topEntry: RALeaderboardEntry?

    enum CodingKeys: String, CodingKey {
        case id = "ID", rankAsc = "RankAsc", title = "Title", description = "Description", format = "Format", state = "State", topEntry = "TopEntry"
    }
}

/// One line of a leaderboard. RA's dates here are ISO 8601, unlike its other endpoints, so they stay text until shown.
public struct RALeaderboardEntry: Codable, Equatable, Sendable {
    public var rank: Int?
    public var user: String
    public var score: Int
    public var formattedScore: String
    public var date: String?

    enum CodingKeys: String, CodingKey {
        case rank = "Rank", user = "User", score = "Score", formattedScore = "FormattedScore", dateSubmitted = "DateSubmitted", dateUpdated = "DateUpdated"
    }

    public init(rank: Int?, user: String, score: Int, formattedScore: String, date: String?) {
        self.rank = rank; self.user = user; self.score = score; self.formattedScore = formattedScore; self.date = date
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank)
        user = try c.decode(String.self, forKey: .user)
        // The game list's TopEntry has sent Score as text.
        score = (try? c.decode(Int.self, forKey: .score)) ?? Int((try? c.decode(String.self, forKey: .score)) ?? "") ?? 0
        formattedScore = try c.decodeIfPresent(String.self, forKey: .formattedScore) ?? "\(score)"
        date = try c.decodeIfPresent(String.self, forKey: .dateSubmitted) ?? c.decodeIfPresent(String.self, forKey: .dateUpdated)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(rank, forKey: .rank)
        try c.encode(user, forKey: .user)
        try c.encode(score, forKey: .score)
        try c.encode(formattedScore, forKey: .formattedScore)
        try c.encodeIfPresent(date, forKey: .dateSubmitted)
    }
}

/// A leaderboard the user is on, from `API_GetUserGameLeaderboards`.
public struct RAUserLeaderboard: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var userEntry: RALeaderboardEntry

    enum CodingKeys: String, CodingKey { case id = "ID", title = "Title", userEntry = "UserEntry" }
}

/// A page of entries and how many there are in all.
public struct RALeaderboardPage: Codable, Equatable, Sendable {
    public var total: Int
    public var results: [RALeaderboardEntry]

    enum CodingKeys: String, CodingKey { case total = "Total", results = "Results" }
}

private struct RAPage<T: Codable>: Codable {
    var total: Int
    var results: [T]
    enum CodingKeys: String, CodingKey { case total = "Total", results = "Results" }
}

extension RAClient {
    static let leaderboardPage = 500  // RA's maximum

    public func gameLeaderboards(gameId: Int) async throws -> [RALeaderboard] {
        var all: [RALeaderboard] = []
        while true {
            let page = try decodeISO(RAPage<RALeaderboard>.self, try await request("API_GetGameLeaderboards.php",
                ["i": "\(gameId)", "c": "\(Self.leaderboardPage)", "o": "\(all.count)"]))
            all += page.results
            if page.results.isEmpty || all.count >= page.total { return all }
        }
    }

    /// Only the leaderboards the user has a score on.
    public func userGameLeaderboards(gameId: Int) async throws -> [RAUserLeaderboard] {
        do {
            return try decodeISO(RAPage<RAUserLeaderboard>.self, try await request("API_GetUserGameLeaderboards.php",
                ["i": "\(gameId)", "u": credentials.username, "c": "\(Self.leaderboardPage)"])).results
        } catch RAError.http(422) {
            return []  // RA's answer for "User has no leaderboards on this game"
        }
    }

    public func leaderboardEntries(leaderboardId: Int, offset: Int, count: Int) async throws -> RALeaderboardPage {
        try decodeISO(RALeaderboardPage.self, try await request("API_GetLeaderboardEntries.php",
            ["i": "\(leaderboardId)", "o": "\(max(0, offset))", "c": "\(min(max(count, 1), Self.leaderboardPage))"]))
    }

    private func decodeISO<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw RAError.decoding }
    }
}

/// What `steam/inject.js` draws for leaderboards. Field names are the contract with the script.
public struct LeaderboardSet: Codable, Equatable, Sendable {
    public var gameId: Int
    public var boards: [Board]

    public struct Board: Codable, Equatable, Sendable {
        public var id: Int
        public var title, description: String
        /// "time" or "score": which icon and words the page uses.
        public var kind: String
        public var lowerIsBetter: Bool
        public var top: Entry?
        public var mine: Entry?
        /// How many entries the board has; only looked up for boards the user is on.
        public var total: Int?
        /// The user's place as a share of the board, 1-100, when `total` is known.
        public var topPercent: Int?
        public var url: String
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var rank: Int?
        public var user, score, avatarURL: String
        public var dateText: String?
        public var isMe: Bool
    }
}

public struct LeaderboardEntriesPage: Codable, Equatable, Sendable {
    public var total: Int
    public var entries: [LeaderboardSet.Entry]
}

/// A score the user submitted since `since`, for the "new personal best" toast.
public struct LeaderboardBest: Codable, Equatable, Sendable {
    public var boardId, gameId: Int
    public var title, score: String
    public var rank: Int?
    public var date: Int
}

public enum LeaderboardBuilder {
    static let timeFormats: Set<String> = ["TIME", "TIMESECS", "MILLISECS", "MINUTES", "SECS", "SECS_AS_MINS"]

    public static func set(gameId: Int, boards: [RALeaderboard], mine: [RAUserLeaderboard], totals: [Int: Int], username: String,
                           timeZone: TimeZone = .current, locale: Locale = .current) -> LeaderboardSet {
        let byId = Dictionary(mine.map { ($0.id, $0.userEntry) }) { a, _ in a }
        return LeaderboardSet(gameId: gameId, boards: boards.filter { ($0.state ?? "active") == "active" }.map { b in
            let total = totals[b.id], my = byId[b.id]
            return .init(id: b.id, title: b.title, description: b.description, kind: timeFormats.contains(b.format.uppercased()) ? "time" : "score",
                         lowerIsBetter: b.rankAsc, top: b.topEntry.map { entry($0, rank: 1, username: username, timeZone: timeZone, locale: locale) },
                         mine: my.map { entry($0, username: username, timeZone: timeZone, locale: locale) }, total: total,
                         topPercent: topPercent(rank: my?.rank, total: total), url: "https://retroachievements.org/leaderboardinfo.php?i=\(b.id)")
        })
    }

    public static func entry(_ e: RALeaderboardEntry, rank: Int? = nil, username: String, timeZone: TimeZone = .current, locale: Locale = .current) -> LeaderboardSet.Entry {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .none; f.timeZone = timeZone; f.locale = locale
        return .init(rank: e.rank ?? rank, user: e.user, score: e.formattedScore, avatarURL: "\(PanelBuilder.media)/UserPic/\(e.user).png",
                     dateText: e.date.flatMap(parseDate).map(f.string(from:)), isMe: e.user.caseInsensitiveCompare(username) == .orderedSame)
    }

    /// "Top 1%" for the leader; never 0, and 100 only for last place.
    static func topPercent(rank: Int?, total: Int?) -> Int? {
        guard let rank, let total, total > 0 else { return nil }
        return min(100, max(1, Int((Double(rank) * 100 / Double(total)).rounded(.up))))
    }

    static func parseDate(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
}

extension Services {
    static let totalsLookedUp = 40
    /// A page revisited within this reuses the last answer: each fetch costs RA a request per ranked board.
    static let leaderboardsReuse: TimeInterval = 120

    /// A game's leaderboards with the user's entries, saved for when RA can't be reached. `fresh` skips the short reuse (a new score).
    func leaderboards(gameId: Int, fresh: Bool = false, now: Date = Date()) async throws -> LeaderboardSet {
        let key = "leaderboards-\(gameId)"
        if !fresh, let saved = ra.cache.get(key, as: LeaderboardSet.self), now.timeIntervalSince(saved.savedAt) < Self.leaderboardsReuse { return saved.value }
        do {
            async let boards = client.gameLeaderboards(gameId: gameId)
            async let mine = client.userGameLeaderboards(gameId: gameId)
            let (all, entries) = try await (boards, mine)
            let set = LeaderboardBuilder.set(gameId: gameId, boards: all, mine: entries, totals: await totals(entries.map(\.id)), username: client.credentials.username)
            ra.cache.put(key, set, savedAt: now)
            return set
        } catch {
            if let saved = ra.cache.get(key, as: LeaderboardSet.self) { return saved.value }
            throw error
        }
    }

    /// Entry counts for "#12 of 1,287", four requests at a time; one that fails is just left out.
    // shortcut: only the first `totalsLookedUp` boards the user is on get a count; page through them if someone's on hundreds
    private func totals(_ ids: [Int]) async -> [Int: Int] {
        await withTaskGroup(of: (Int, Int)?.self) { group in
            var out: [Int: Int] = [:], queue = ids.prefix(Self.totalsLookedUp).makeIterator()
            func next() { if let id = queue.next() { group.addTask { [client] in (try? await client.leaderboardEntries(leaderboardId: id, offset: 0, count: 1)).map { (id, $0.total) } } } }
            for _ in 0..<4 { next() }
            while let hit = await group.next() { if let hit { out[hit.0] = hit.1 }; next() }
            return out
        }
    }

    func leaderboardEntries(id: Int, offset: Int, count: Int) async throws -> LeaderboardEntriesPage {
        let page = try await client.leaderboardEntries(leaderboardId: id, offset: offset, count: min(count, 100))
        return .init(total: page.total, entries: page.results.map { LeaderboardBuilder.entry($0, username: client.credentials.username) })
    }

    /// Scores the user sent to the games' leaderboards since `since`.
    func leaderboardBests(gameIds: [Int], since: Date) async throws -> [LeaderboardBest] {
        var out: [LeaderboardBest] = []
        for gameId in gameIds {
            for b in try await client.userGameLeaderboards(gameId: gameId) {
                guard let date = b.userEntry.date.flatMap(LeaderboardBuilder.parseDate), date >= since else { continue }
                out.append(.init(boardId: b.id, gameId: gameId, title: b.title, score: b.userEntry.formattedScore, rank: b.userEntry.rank, date: Int(date.timeIntervalSince1970)))
            }
        }
        return out
    }
}
