import Foundation
import Testing
@testable import RACore

struct EchoHandler: BridgeHandling {
    var fail = false
    func handle(method: String, params: Data) async throws -> Data {
        if fail { throw RAError.http(500) }
        return params
    }
}

@Test func routesAndWrapsResult() async {
    let js = await BridgeRouter(handler: EchoHandler()).respond(to: #"{"id":7,"method":"x","params":{"a":1}}"#)
    #expect(js == #"window.__sra.receive({"id":7,"result":{"a":1}})"#)
}

@Test func wrapsErrors() async {
    let js = await BridgeRouter(handler: EchoHandler(fail: true)).respond(to: #"{"id":7,"method":"x","params":{}}"#) ?? ""
    #expect(js.contains(#""id":7"#))
    #expect(js.contains(#""error""#))
}

@Test func ignoresMalformed() async {
    #expect(await BridgeRouter(handler: EchoHandler()).respond(to: "nope") == nil)
}

@Test func onlyRetroAchievementsURLs() {
    #expect(BridgeRouter.isAllowedExternalURL("https://retroachievements.org/game/1"))
    #expect(!BridgeRouter.isAllowedExternalURL("https://evil.example/"))
    #expect(!BridgeRouter.isAllowedExternalURL("https://retroachievements.org.evil.example/"))
    #expect(!BridgeRouter.isAllowedExternalURL("javascript:alert(1)"))
}

@Test func fetchFailureFallsBackToCache() async throws {
    let data = tempDir()
    let services = Services(credentials: creds, dataDirectory: data, transport: FakeTransport { _ in (Data(), 500) })
    let cache = DiskCache(directory: data.appendingPathComponent("cache"))
    cache.put("gamelist-7", [smbEntry])
    cache.put("progress-1446", progress([ach(1, order: 1)]))
    let handler = BridgeHandler(services: { services }, actions: BridgeActions(),
                                push: { _ in })
    let params = try JSONEncoder().encode(["shortcut": smb()])
    let result = try await handler.handle(method: "getPanel", params: params)
    let payload = try JSONDecoder().decode(PanelPayload.self, from: result)
    #expect(payload.state == "matched")
    #expect(payload.updatedText?.hasPrefix("Last updated") == true)
}

@Test func playtimesForPlayedShortcuts() async throws {
    let data = tempDir()
    var p = progress([ach(1, order: 1)])
    p.userTotalPlaytime = 3_700
    let progressJSON = try RADate.encoder.encode(p)
    let played = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 86_400).rounded(.down))  // yesterday, in the last two weeks
    let recent = Data(#"[{"GameID":1446,"LastPlayed":"\#(RADate.formatter.string(from: played))"}]"#.utf8)
    let transport = FakeTransport { url in
        url.path.hasSuffix("RecentlyPlayedGames.php") ? (recent, 200) : url.path.hasSuffix("UserProgress.php") ? (progressJSON, 200) : (Data(), 500)
    }
    let services = Services(credentials: creds, dataDirectory: data, transport: transport)
    let zelda = RAGameListEntry(id: 1447, title: "Zelda", consoleId: 7, consoleName: "NES/Famicom", imageIcon: "/i.png", numAchievements: 9, hashes: [])
    DiskCache(directory: data.appendingPathComponent("cache")).put("gamelist-7", [smbEntry, zelda])
    let handler = BridgeHandler(services: { services }, actions: BridgeActions(), push: { _ in })
    // Zelda matches but was never played, so it gets nothing, like a Steam game with no playtime.
    let unplayed = ShortcutInfo(appid: 2, name: "Zelda", exe: raExe, launchOptions: "-L \"/c/fceumm_libretro.dylib\" \"/r/nes/Zelda.nes\"")
    let params = try JSONEncoder().encode(["shortcuts": [smb(), unplayed]])
    let rows = { () async throws -> [[String: Int]]? in
        try JSONSerialization.jsonObject(with: try await handler.handle(method: "playtimes", params: params)) as? [[String: Int]]
    }
    // A first sync has no earlier total to compare with, so the whole total counts as the last two weeks.
    #expect(try await rows() == [["appid": 1, "minutes": 62, "lastPlayed": Int(played.timeIntervalSince1970), "twoWeeks": 62]])
    // The progress saved just now is newer than the last play, so the next sync doesn't fetch it again.
    let progressCalls = { transport.urls.filter { $0.path.hasSuffix("UserProgress.php") }.count }
    let before = progressCalls()
    _ = try await rows()
    #expect(progressCalls() == before)
}

@Test func lastTwoWeeksFromSavedTotals() {
    let file = tempDir().appendingPathComponent("playtime.json"), day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let h = PlaytimeHistory(file: file)
    // No history from before the window yet: a game played in it gets its whole total, one that wasn't gets nothing.
    #expect(h.lastTwoWeeks(gameId: 1, total: 6_000, lastPlayed: t0 - day, now: t0) == 6_000)
    #expect(h.lastTwoWeeks(gameId: 2, total: 9_000, lastPlayed: t0 - 20 * day, now: t0) == 0)
    // 15 days on, the first total is from before the window: only what was played since counts. The history survives a restart.
    #expect(PlaytimeHistory(file: file).lastTwoWeeks(gameId: 1, total: 7_200, lastPlayed: t0 + 15 * day, now: t0 + 15 * day) == 1_200)
    #expect(PlaytimeHistory(file: file).lastTwoWeeks(gameId: 1, total: 7_200, lastPlayed: t0 + 15 * day, now: t0 + 40 * day) == 0)
}

@Test func routerErrorsAreGeneric() async {
    struct Leaky: BridgeHandling {
        func handle(method: String, params: Data) async throws -> Data { throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://x/?y=SECRET"]) }
    }
    let js = await BridgeRouter(handler: Leaky()).respond(to: #"{"id":1,"method":"x","params":{}}"#) ?? ""
    #expect(!js.contains("SECRET"))
    #expect(js.contains(#""error""#))
}

@Test func scanGamesReturnsShortcuts() async throws {
    let root = tempDir()
    touch(root, "snes/a.sfc")
    touch(root, "snes/b.sfc")
    let inst = installed(cores: ["snes9x"])
    let handler = BridgeHandler(services: { nil }, actions: BridgeActions(), push: { _ in }, installed: { inst }, hasher: PathHasher(byFile: [:]))
    let existing = root.appendingPathComponent("snes/b.sfc").resolvingSymlinksInPath().path
    let params = #"{"folder":"\#(root.path)","consoleOverrides":{},"emulatorOverrides":{},"shortcuts":[{"exe":"/A/RetroArch","launchOptions":"\"\#(existing)\""}]}"#
    let result = try JSONSerialization.jsonObject(with: try await handler.handle(method: "scanGames", params: Data(params.utf8))) as? [String: Any]
    let items = result?["items"] as? [[String: Any]] ?? []
    #expect(items.map { $0["status"] as? String } == ["ready", "alreadyInSteam"])
    #expect((items.first?["shortcut"] as? [String: Any])?["name"] as? String == "a")
    #expect(items.last?["shortcut"] == nil)
    #expect((items.first?["emulatorChoices"] as? [[String: Any]])?.map { $0["id"] as? String } == ["retroarch"])
}

@Test func scanGamesRemembersTheFolder() async throws {
    let root = tempDir()
    touch(root, "snes/a.sfc")
    let inst = installed(cores: ["snes9x"])
    let handler = BridgeHandler(services: { nil }, actions: BridgeActions(), push: { _ in }, installed: { inst }, hasher: PathHasher(byFile: [:]),
                                folderFile: tempDir().appendingPathComponent("rom-folder.txt"))
    func scannedFolder(_ folder: String) async throws -> String? {
        let params = #"{"folder":\#(folder),"consoleOverrides":{},"emulatorOverrides":{},"shortcuts":[]}"#
        return (try JSONSerialization.jsonObject(with: try await handler.handle(method: "scanGames", params: Data(params.utf8))) as? [String: Any])?["folder"] as? String
    }
    _ = try await scannedFolder("\"\(root.path)\"")
    #expect(try await scannedFolder("null") == root.path)
}

@Test func subsetsComeAlongAsOwnPanels() async throws {
    let data = tempDir()
    let services = Services(credentials: creds, dataDirectory: data, transport: FakeTransport { _ in (Data(), 500) })
    let cache = DiskCache(directory: data.appendingPathComponent("cache"))
    cache.put("gamelist-7", [smbEntry, bonusEntry])
    cache.put("progress-1446", progress([ach(1, order: 1)]))
    var bonus = progress([ach(2, order: 1, earned: Date(timeIntervalSince1970: 1_457_804_849)), ach(3, order: 2)])
    bonus.id = 900; bonus.title = bonusEntry.title
    cache.put("progress-900", bonus)
    let handler = BridgeHandler(services: { services }, actions: BridgeActions(), push: { _ in })
    let params = try JSONEncoder().encode(["shortcut": smb()])
    let payload = try JSONDecoder().decode(PanelPayload.self, from: try await handler.handle(method: "getPanel", params: params))
    #expect(payload.game?.id == 1446)
    #expect(payload.achievements.map(\.id) == [1])  // the subset's achievements stay out of the game's own list
    #expect(payload.summary?.text == "You've unlocked 0/1 (0%)")
    #expect(payload.subsets.count == 1)
    #expect(payload.subsets[0].game?.title == "Super Mario Bros. [Subset - Bonus]")
    #expect(payload.subsets[0].achievements.map(\.id) == [2, 3])
    #expect(payload.subsets[0].summary?.text == "You've unlocked 1/2 (50%)")
}

@Test func unlocksSinceSessionStart() async throws {
    // One unlock from this session, one from long before it (the previous session) that the 10-minute window still returns.
    let recent = Data(#"""
    [{"Date":"2026-11-04 12:00:30","HardcoreMode":1,"AchievementID":9,"Title":"Coins","Description":"Get 100","BadgeName":"250336","Points":5},
     {"Date":"2026-11-04 11:55:00","HardcoreMode":0,"AchievementID":8,"Title":"Old","Description":"Earlier","BadgeName":"1","Points":1}]
    """#.utf8)
    let transport = FakeTransport { url in url.path.hasSuffix("RecentAchievements.php") ? (recent, 200) : (Data(), 500) }
    let services = Services(credentials: creds, dataDirectory: tempDir(), transport: transport)
    let handler = BridgeHandler(services: { services }, actions: BridgeActions(), push: { _ in })
    let since = RADate.formatter.date(from: "2026-11-04 12:00:00")!.timeIntervalSince1970
    let result = try await handler.handle(method: "unlocks", params: Data(#"{"since":\#(since)}"#.utf8))
    #expect(String(decoding: result, as: UTF8.self)
        == #"[{"date":\#(Int(since) + 30),"description":"Get 100","id":9,"image":"https:\/\/media.retroachievements.org\/Badge\/250336.png","title":"Coins"}]"#)
    #expect(transport.urls[0].query?.contains("m=10&u=Max%20Milyin") == true)
}
