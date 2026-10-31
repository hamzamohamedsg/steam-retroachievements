import Foundation
import Testing
@testable import RACore

func fixture(_ name: String) -> Data {
    try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!)
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var urls: [URL] = []
    let respond: @Sendable (URL) -> (Data, Int)
    init(_ respond: @escaping @Sendable (URL) -> (Data, Int)) { self.respond = respond }
    func get(_ url: URL) async throws -> (Data, Int) { urls.append(url); return respond(url) }
}

let creds = RACredentials(username: "Max Milyin", apiKey: "k&1")

@Test func decodesGameList() async throws {
    let list = try await RAClient(credentials: creds, transport: FakeTransport { _ in (fixture("game-list"), 200) }).gameList(consoleId: 1)
    #expect(list.count == 2)
    #expect(list[0].id == 3684)
    #expect(list[0].title == "Advanced Busterhawk: Gley Lancer")
    #expect(list[0].hashes == ["8bd4a97783cda077c342173df0a9b51e", "a13ab653a20fb383337fab1e52ddb0df"])
}

@Test func decodesProgress() async throws {
    let p = try await RAClient(credentials: creds, transport: FakeTransport { _ in (fixture("game-progress"), 200) }).gameProgress(gameId: 1)
    #expect(p.achievements.map(\.id) == [9, 10])
    #expect(p.achievements[0].dateEarned == Date(timeIntervalSince1970: 1_457_804_849))  // 2016-03-12 17:47:29 UTC
    #expect(p.achievements[1].dateEarned == nil)
    #expect(p.publisher == "Sega")
    #expect(p.genre == nil)
    #expect(p.numDistinctPlayers == 27080)
}

@Test func buildsRequestURL() async throws {
    let t = FakeTransport { _ in (fixture("game-progress"), 200) }
    _ = try await RAClient(credentials: creds, transport: t).gameProgress(gameId: 14402)
    let c = URLComponents(url: t.urls[0], resolvingAgainstBaseURL: false)!
    let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
    #expect(c.host == "retroachievements.org")
    #expect(c.path == "/API/API_GetGameInfoAndUserProgress.php")
    #expect(q == ["g": "14402", "u": "Max Milyin", "y": "k&1"])
}

@Test func unauthorizedIsBadCredentials() async {
    await #expect(throws: RAError.badCredentials) {
        try await RAClient(credentials: creds, transport: FakeTransport { _ in (Data(), 401) }).checkCredentials()
    }
}

final class CountingRA: RAProviding, @unchecked Sendable {
    var listCalls = 0
    func gameList(consoleId: Int) async throws -> [RAGameListEntry] {
        listCalls += 1
        return [RAGameListEntry(id: 1, title: "A", consoleId: consoleId, consoleName: "C", imageIcon: "/i.png", numAchievements: 1, hashes: [])]
    }
    func gameProgress(gameId: Int) async throws -> RAGameProgress { fatalError("unused") }
}

final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_700_000_000) }

@Test func gameListCachedSevenDays() async throws {
    let inner = CountingRA(), clock = Clock(), cache = DiskCache(directory: tempDir())
    let ra = CachedRA(client: inner, cache: cache, now: { clock.now })
    cache.put("gamelist-7", try await inner.gameList(consoleId: 7), savedAt: clock.now)
    inner.listCalls = 0
    clock.now += 6 * 86_400
    _ = try await ra.gameList(consoleId: 7)
    #expect(inner.listCalls == 0)
    clock.now += 2 * 86_400
    _ = try await ra.gameList(consoleId: 7)
    #expect(inner.listCalls == 1)
}

struct ThrowingTransport: HTTPTransport {
    func get(_ url: URL) async throws -> (Data, Int) {
        throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
    }
}

@Test func networkErrorsNeverCarryTheKey() async {
    let secret = RACredentials(username: "u", apiKey: "SECRETKEY123")
    do {
        _ = try await RAClient(credentials: secret, transport: ThrowingTransport()).gameList(consoleId: 7)
        Issue.record("expected a throw")
    } catch {
        #expect(error as? RAError == .network)
        #expect(!String(describing: error).contains("SECRETKEY123"))
    }
}

struct FailingRA: RAProviding {
    func gameList(consoleId: Int) async throws -> [RAGameListEntry] { throw RAError.http(503) }
    func gameProgress(gameId: Int) async throws -> RAGameProgress { throw RAError.http(503) }
}

@Test func staleGameListServesWhenRAIsDown() async throws {
    let clock = Clock(), cache = DiskCache(directory: tempDir())
    cache.put("gamelist-7", [smbEntry], savedAt: clock.now)
    clock.now += 30 * 86_400
    let list = try await CachedRA(client: FailingRA(), cache: cache, now: { clock.now }).gameList(consoleId: 7)
    #expect(list == [smbEntry])
}
