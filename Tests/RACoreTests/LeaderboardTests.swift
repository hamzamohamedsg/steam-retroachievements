import Foundation
import Testing
@testable import RACore

private let me = RACredentials(username: "hamza", apiKey: "k")

// Shapes as RA sent them on 2026-11-20 (Sonic the Hedgehog, game 1).
private let boards = Data(#"""
{"Count":3,"Total":3,"Results":[
 {"ID":103038,"RankAsc":true,"Title":"Green Hill Zone Act 1 Speedrun","Description":"Fastest","Format":"TIME","TopEntry":{"User":"DA1andonly","Score":1495,"FormattedScore":"0:24.91"},"State":"active"},
 {"ID":2042,"RankAsc":false,"Title":"Hi-Score","Description":"Highest","Format":"SCORE","TopEntry":{"User":"Kinho51","Score":"218670","FormattedScore":"218670"},"State":"active"},
 {"ID":7,"RankAsc":false,"Title":"Old","Description":"","Format":"VALUE","TopEntry":null,"State":"disabled"}]}
"""#.utf8)
private let mine = Data(#"""
{"Count":1,"Total":1,"Results":[{"ID":103038,"RankAsc":true,"Title":"Green Hill Zone Act 1 Speedrun","Description":"Fastest","Format":"TIME",
 "UserEntry":{"User":"Hamza","Score":5140,"FormattedScore":"1:25.66","Rank":15614,"DateUpdated":"2026-11-11T17:50:52+00:00"}}]}
"""#.utf8)
private let entries = Data(#"""
{"Count":1,"Total":17891,"Results":[{"User":"exdb49","DateSubmitted":"2026-10-10T18:37:58+00:00","Score":5138,"FormattedScore":"1:25.63","Rank":15611}]}
"""#.utf8)

private func transport(noEntries: Bool = false) -> FakeTransport {
    FakeTransport { url in
        switch url.lastPathComponent {
        case "API_GetGameLeaderboards.php": (boards, 200)
        case "API_GetUserGameLeaderboards.php": noEntries ? (Data(#"["User has no leaderboards on this game"]"#.utf8), 422) : (mine, 200)
        case "API_GetLeaderboardEntries.php": (entries, 200)
        default: (Data(), 500)
        }
    }
}

@Test func leaderboardsWithMyRankAndShare() async throws {
    let s = Services(credentials: me, dataDirectory: tempDir(), transport: transport())
    let set = try await s.leaderboards(gameId: 1)
    #expect(set.boards.map(\.id) == [103038, 2042])  // the disabled board is left out
    let act1 = set.boards[0]
    #expect(act1.kind == "time" && act1.lowerIsBetter)
    #expect(act1.top?.user == "DA1andonly" && act1.top?.rank == 1)
    #expect(act1.mine?.rank == 15614 && act1.mine?.isMe == true && act1.mine?.score == "1:25.66")
    #expect(act1.total == 17891 && act1.topPercent == 88)
    #expect(set.boards[1].kind == "score" && set.boards[1].mine == nil && set.boards[1].top?.score == "218670")
}

@Test func noEntriesIsNotAnError() async throws {
    let s = Services(credentials: me, dataDirectory: tempDir(), transport: transport(noEntries: true))
    let set = try await s.leaderboards(gameId: 1)
    #expect(set.boards.count == 2 && set.boards.allSatisfy { $0.mine == nil && $0.total == nil })
}

@Test func leaderboardsFallBackToSaved() async throws {
    let dir = tempDir()
    _ = try await Services(credentials: me, dataDirectory: dir, transport: transport()).leaderboards(gameId: 1)
    let offline = Services(credentials: me, dataDirectory: dir, transport: FakeTransport { _ in (Data(), 500) })
    #expect(try await offline.leaderboards(gameId: 1).boards.count == 2)
}

@Test func topPercentBounds() {
    #expect(LeaderboardBuilder.topPercent(rank: 1, total: 17891) == 1)
    #expect(LeaderboardBuilder.topPercent(rank: 50, total: 100) == 50)
    #expect(LeaderboardBuilder.topPercent(rank: 100, total: 100) == 100)
    #expect(LeaderboardBuilder.topPercent(rank: 3, total: nil) == nil)
}

@Test func newBestsSinceTheSessionStarted() async throws {
    let s = Services(credentials: me, dataDirectory: tempDir(), transport: transport())
    let start = LeaderboardBuilder.parseDate("2026-11-11T17:00:00+00:00")!
    let bests = try await s.leaderboardBests(gameIds: [1], since: start)
    #expect(bests == [LeaderboardBest(boardId: 103038, gameId: 1, title: "Green Hill Zone Act 1 Speedrun", score: "1:25.66", rank: 15614, date: 1_794_419_452)])
    #expect(try await s.leaderboardBests(gameIds: [1], since: start.addingTimeInterval(86_400)).isEmpty)
}

@Test func entriesPageMarksMe() async throws {
    let s = Services(credentials: RACredentials(username: "EXDB49", apiKey: "k"), dataDirectory: tempDir(), transport: transport())
    let page = try await s.leaderboardEntries(id: 103038, offset: 15610, count: 500)
    #expect(page.total == 17891 && page.entries.first?.isMe == true && page.entries.first?.rank == 15611)
    #expect(page.entries.first?.avatarURL == "https://media.retroachievements.org/UserPic/exdb49.png")
}

@Test func leaderboardsAreReusedBrieflyUnlessFresh() async throws {
    let t = transport(), s = Services(credentials: me, dataDirectory: tempDir(), transport: t)
    let start = Date()
    _ = try await s.leaderboards(gameId: 1, now: start)
    let after = t.urls.count
    _ = try await s.leaderboards(gameId: 1, now: start.addingTimeInterval(60))
    #expect(t.urls.count == after)  // within two minutes: no requests
    _ = try await s.leaderboards(gameId: 1, fresh: true, now: start.addingTimeInterval(60))
    #expect(t.urls.count > after)
    let fresh = t.urls.count
    _ = try await s.leaderboards(gameId: 1, now: start.addingTimeInterval(300))
    #expect(t.urls.count > fresh)
}
