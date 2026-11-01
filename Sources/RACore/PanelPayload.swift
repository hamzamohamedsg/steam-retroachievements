import Foundation

/// What `steam/inject.js` draws. Field names are the contract with the script.
public struct PanelPayload: Codable, Equatable, Sendable {
    public var state: String  // "signedOut" | "hidden" | "notMatched" | "matched" | "noSet" | "error"
    public var message: String?
    public var notice: String?
    public var consoleId: Int?
    public var game: Game?
    public var summary: Summary?
    public var achievements: [Row] = []
    public var updatedText: String?
    /// One full panel per subset of the game, for the clickable subset icons; each opens like the game's own achievements view.
    public var subsets: [PanelPayload] = []
    public struct Game: Codable, Equatable, Sendable { public var id: Int; public var title, consoleName, iconURL, raURL: String; public var details: [Detail] }
    public struct Detail: Codable, Equatable, Sendable {
        public var label, value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }
    public struct Summary: Codable, Equatable, Sendable { public var text, pointsText: String; public var hardcoreText: String?; public var percent: Int }
    public struct Row: Codable, Equatable, Sendable {
        public var id: Int
        public var title, description: String
        public var points: Int
        public var badgeURL: String
        public var unlocked, hardcore: Bool
        public var unlockedText, rarityText: String?
        /// Percent of players who have it, for sorting the Global Achievements tab.
        public var rarity: Double?
    }

    init(state: String, message: String? = nil, notice: String? = nil, consoleId: Int? = nil) {
        self.state = state; self.message = message; self.notice = notice; self.consoleId = consoleId
    }
}

public enum PanelBuilder {
    static let media = "https://media.retroachievements.org"

    public static func matched(_ p: RAGameProgress, verification: Verification, emulatorName: String, stale: Bool, savedAt: Date?,
                               timeZone: TimeZone = .current, locale: Locale = .current) -> PanelPayload {
        var out = PanelPayload(state: p.achievements.isEmpty ? "noSet" : "matched",
                               notice: notice(verification, emulatorName: emulatorName), consoleId: p.consoleId)
        if p.achievements.isEmpty { out.message = "No achievements for this game on RetroAchievements yet." }

        let dateOnly = formatter(.medium, .none, timeZone, locale)
        let details: [(String, String?)] = [
            ("Console", p.consoleName), ("Developer", p.developer), ("Publisher", p.publisher), ("Genre", p.genre),
            ("Released", p.released.flatMap { RADate.formatter.date(from: $0) }.map { dateOnly.string(from: $0) }),
        ]
        out.game = .init(id: p.id, title: p.title, consoleName: p.consoleName, iconURL: media + p.imageIcon,
                         raURL: "https://retroachievements.org/game/\(p.id)",
                         details: details.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : .init(label: label, value: $0) } })

        let earned = { (a: RAAchievement) in a.dateEarnedHardcore ?? a.dateEarned }
        let unlocked = p.achievements.filter { earned($0) != nil }.sorted { earned($0)! > earned($1)! }
        let locked = p.achievements.filter { earned($0) == nil }.sorted { $0.displayOrder < $1.displayOrder }
        let full = formatter(.medium, .short, timeZone, locale)
        let rarity = { (a: RAAchievement) in p.numDistinctPlayers > 0 ? Double(a.numAwarded) * 100 / Double(p.numDistinctPlayers) : nil }
        out.achievements = (unlocked + locked).map { a in
            let isUnlocked = earned(a) != nil
            return .init(id: a.id, title: a.title, description: a.description, points: a.points,
                         badgeURL: "\(media)/Badge/\(a.badgeName)\(isUnlocked ? "" : "_lock").png",
                         unlocked: isUnlocked, hardcore: a.dateEarnedHardcore != nil,
                         unlockedText: earned(a).map { "Unlocked " + full.string(from: $0) },
                         rarityText: rarity(a).map { String(format: "%.1f%% of players have this achievement", $0) }, rarity: rarity(a))
        }

        if !p.achievements.isEmpty {
            let total = p.achievements.count, pct = unlocked.count * 100 / total
            let hardcore = p.achievements.filter { $0.dateEarnedHardcore != nil }.count
            out.summary = .init(text: "You've unlocked \(unlocked.count)/\(total) (\(pct)%)",
                                pointsText: "\(unlocked.reduce(0) { $0 + $1.points }) / \(p.achievements.reduce(0) { $0 + $1.points }) points",
                                hardcoreText: hardcore > 0 ? "\(hardcore) in hardcore" : nil, percent: pct)
        }
        if stale, let savedAt { out.updatedText = lastUpdated(savedAt) }
        return out
    }

    public static func signedOut() -> PanelPayload { .init(state: "signedOut", message: "Sign in to RetroAchievements to see your achievements here.") }
    public static func hidden() -> PanelPayload { .init(state: "hidden") }

    public static func notMatched(consoleId: Int?, verification: Verification) -> PanelPayload {
        .init(state: "notMatched", message: "Couldn't find this game on RetroAchievements.", consoleId: consoleId)
    }

    public static func failed(cached: PanelPayload?, savedAt: Date?) -> PanelPayload {
        guard var cached else { return .init(state: "error", message: "Couldn't reach RetroAchievements.") }
        if let savedAt { cached.updatedText = lastUpdated(savedAt) }
        return cached
    }

    static func notice(_ v: Verification, emulatorName: String) -> String? {
        switch v {
        case .verified: nil
        case .unrecognizedHash: "RetroAchievements doesn't recognize this ROM version, so \(emulatorName) won't unlock these achievements."
        case .unchecked: "Couldn't check this ROM version."
        case .blocked: "macOS won't let Steam RetroAchievements read this ROM. Move it to the ROMs folder in your home folder."
        case .missing: "Can't find this game's ROM file."
        }
    }

    static func lastUpdated(_ d: Date) -> String {
        "Last updated " + formatter(.none, .short, .current, .current).string(from: d)
    }

    static func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style, _ tz: TimeZone, _ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = date; f.timeStyle = time; f.timeZone = tz; f.locale = locale
        return f
    }
}
