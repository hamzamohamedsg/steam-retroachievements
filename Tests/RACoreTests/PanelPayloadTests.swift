import Foundation
import Testing
@testable import RACore

let utc = TimeZone(identifier: "UTC")!
let enUS = Locale(identifier: "en_US")

func ach(_ id: Int, order: Int, earned: Date? = nil, hardcore: Date? = nil, awarded: Int = 5) -> RAAchievement {
    RAAchievement(id: id, title: "A\(id)", description: "D\(id)", points: 10, badgeName: "b\(id)", displayOrder: order,
                  numAwarded: awarded, numAwardedHardcore: 0, dateEarned: earned, dateEarnedHardcore: hardcore)
}

func progress(_ achievements: [RAAchievement], players: Int = 10) -> RAGameProgress {
    RAGameProgress(id: 1446, title: "Super Mario Bros.", consoleId: 7, consoleName: "NES/Famicom", imageIcon: "/Images/1.png",
                   publisher: "Nintendo", developer: "", genre: nil, released: "1985-09-13 00:00:00",
                   numDistinctPlayers: players, achievements: achievements)
}

func build(_ p: RAGameProgress, _ v: Verification = .verified) -> PanelPayload {
    PanelBuilder.matched(p, verification: v, emulatorName: "RetroArch", stale: false, savedAt: nil, timeZone: utc, locale: enUS)
}

@Test func summaryAndOrder() {
    let d1 = Date(timeIntervalSince1970: 1_000_000), d2 = Date(timeIntervalSince1970: 2_000_000), d3 = Date(timeIntervalSince1970: 3_000_000)
    var list = (1...37).map { ach($0, order: $0 + 3) }
    list += [ach(100, order: 1, earned: d1), ach(101, order: 2, earned: d3, hardcore: d3), ach(102, order: 3, earned: d2)]
    let p = build(progress(list))
    #expect(p.state == "matched")
    #expect(p.summary?.text == "You've unlocked 3/40 (7%)")
    #expect(p.summary?.pointsText == "30 / 400 points")
    #expect(p.summary?.hardcoreText == "1 in hardcore")
    #expect(p.achievements.prefix(3).map(\.id) == [101, 102, 100])
    #expect(p.achievements[3].id == 1)
    #expect(p.achievements[0].hardcore)
    #expect(p.game?.details == [.init(label: "Console", value: "NES/Famicom"), .init(label: "Publisher", value: "Nintendo"),
                                .init(label: "Released", value: "Sep 13, 1985")])
    #expect(p.game?.iconURL == "https://media.retroachievements.org/Images/1.png")
    #expect(p.game?.raURL == "https://retroachievements.org/game/1446")
}

@Test func rarityAndBadges() {
    let p = build(progress([ach(1, order: 1, awarded: 5), ach(2, order: 2, earned: Date(timeIntervalSince1970: 0))]))
    let locked = p.achievements.first { !$0.unlocked }!, unlocked = p.achievements.first { $0.unlocked }!
    #expect(locked.rarityText == "50.0% of players have this achievement")
    #expect(locked.badgeURL == "https://media.retroachievements.org/Badge/b1_lock.png")
    #expect(unlocked.badgeURL == "https://media.retroachievements.org/Badge/b2.png")
    #expect(unlocked.unlockedText == "Unlocked Jan 1, 1970 at 12:00\u{202F}AM")
    #expect(build(progress([ach(1, order: 1)], players: 0)).achievements[0].rarityText == nil)
}

@Test func noticesPerVerification() {
    let p = progress([ach(1, order: 1)])
    #expect(build(p, .verified).notice == nil)
    #expect(PanelBuilder.matched(p, verification: .unrecognizedHash, emulatorName: "DuckStation", stale: false, savedAt: nil).notice
            == "RetroAchievements doesn't recognize this ROM version, so DuckStation won't unlock these achievements.")
    #expect(build(p, .unchecked).notice == "Couldn't check this ROM version.")
    #expect(build(p, .blocked).notice == "macOS won't let Steam RetroAchievements read this ROM. Move it to the ROMs folder in your home folder.")
    #expect(build(p, .missing).notice == "Can't find this game's ROM file.")
}

@Test func emptySetIsNoSet() {
    let p = build(progress([]))
    #expect(p.state == "noSet")
    #expect(p.message == "No achievements for this game on RetroAchievements yet.")
    #expect(p.game?.title == "Super Mario Bros.")
}

@Test func failedUsesCache() {
    let cached = build(progress([ach(1, order: 1)]))
    #expect(PanelBuilder.failed(cached: cached, savedAt: Date()).updatedText?.hasPrefix("Last updated") == true)
    let none = PanelBuilder.failed(cached: nil, savedAt: nil)
    #expect(none.state == "error")
    #expect(none.message == "Couldn't reach RetroAchievements.")
    #expect(PanelBuilder.signedOut().message == "Sign in to RetroAchievements to see your achievements here.")
    #expect(PanelBuilder.notMatched(consoleId: 7, verification: .unchecked).message == "Couldn't find this game on RetroAchievements.")
    #expect(PanelBuilder.hidden().state == "hidden")
}
