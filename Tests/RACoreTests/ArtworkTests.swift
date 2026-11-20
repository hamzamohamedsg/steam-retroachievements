import Foundation
import Testing
@testable import RACore

private let secret = "SECRETKEY123"
private let cdn = "https://cdn2.steamgriddb.com"

private func reply(_ items: String) -> (Data, Int) { (Data(#"{"success":true,"data":[\#(items)]}"#.utf8), 200) }

/// SteamGridDB as it answers for a game that has every kind of art. `override` replaces the reply to URLs containing its key.
private func gridDB(override: [String: (Data, Int)] = [:]) -> FakeTransport {
    FakeTransport { url in
        let s = url.absoluteString
        if let hit = override.first(where: { s.contains($0.key) }) { return hit.value }
        if s.contains("/search/autocomplete/") { return reply(#"{"id":77,"name":"Chrono Trigger","types":[],"verified":true}"#) }
        if s.contains("/grids/game/77"), s.contains("600x900") { return reply(#"{"id":1,"url":"\#(cdn)/p.png","mime":"image/png","nsfw":false}"#) }
        if s.contains("/grids/game/77") { return reply(#"{"id":2,"url":"\#(cdn)/banner.jpg","mime":"image/jpeg","nsfw":false}"#) }
        if s.contains("/heroes/game/77") { return reply(#"{"id":3,"url":"\#(cdn)/hero.png","mime":"image/png","nsfw":false}"#) }
        if s.contains("/logos/game/77") { return reply(#"{"id":4,"url":"\#(cdn)/logo.png","mime":"image/png","nsfw":false}"#) }
        if s.contains("/icons/game/77") { return reply(#"{"id":5,"url":"\#(cdn)/icon.png","mime":"image/png","nsfw":false}"#) }
        if s.hasPrefix(cdn) { return (Data(url.lastPathComponent.utf8), 200) }
        return (Data(), 404)
    }
}

@Test func artworkLandsInSteamsAssetSlots() async throws {
    let art = try await SteamGridDB(key: secret, transport: gridDB()).art(title: "Chrono Trigger")
    // Steam's slots: 0 portrait, 3 banner, 1 hero, 2 logo. Base64 of each file's name, which is what the fake serves.
    #expect(art.images == [
        ArtworkImage(assetType: 0, ext: "png", data: "cC5wbmc="),
        ArtworkImage(assetType: 3, ext: "jpg", data: "YmFubmVyLmpwZw=="),
        ArtworkImage(assetType: 1, ext: "png", data: "aGVyby5wbmc="),
        ArtworkImage(assetType: 2, ext: "png", data: "bG9nby5wbmc="),
    ])
    #expect(art.icon == Data("icon.png".utf8))
}

@Test func keyGoesOnlyToTheAPIAndNeverInAURL() async throws {
    let fake = gridDB()
    _ = try await SteamGridDB(key: secret, transport: fake).art(title: "Chrono Trigger")
    #expect(fake.urls.count == 11)
    for url in fake.urls {
        #expect(!url.absoluteString.contains(secret))
        let auth = fake.headers[url]?["Authorization"]
        #expect(auth == (url.host == "www.steamgriddb.com" ? "Bearer \(secret)" : nil), "\(url)")
    }
}

@Test func titleIsEscapedInTheSearchPath() async throws {
    let fake = gridDB()
    _ = try await SteamGridDB(key: secret, transport: fake).art(title: "Fate/Stay + Night? #1")
    #expect(fake.urls[0].absoluteString.hasSuffix("/search/autocomplete/Fate%2FStay%20%2B%20Night%3F%20%231"))
}

@Test func noKeyMeansNoRequests() async throws {
    let fake = gridDB()
    let art = try await SteamGridDB(key: "", transport: fake).art(title: "Chrono Trigger")
    #expect(art.images.isEmpty && art.icon == nil)
    #expect(fake.urls.isEmpty)
}

@Test func imagesOffSteamGridDBAreNotDownloaded() async throws {
    let lookalike = reply(#"{"id":1,"url":"https://steamgriddb.com.evil.example/p.png","mime":"image/png"}"#)
    let plain = reply(#"{"id":1,"url":"http://cdn2.steamgriddb.com/p.png","mime":"image/png"}"#)
    for bad in [lookalike, plain] {
        let fake = gridDB(override: ["600x900": bad])
        let art = try await SteamGridDB(key: secret, transport: fake).art(title: "Chrono Trigger")
        #expect(!art.images.contains { $0.assetType == 0 })
        #expect(!fake.urls.contains { $0.lastPathComponent == "p.png" })
    }
}

@Test func takedownPlaceholdersAreSkippedForTheNextImage() async throws {
    // SteamGridDB marks images removed by a DMCA notice with a URL ending in "?".
    let list = reply(#"{"id":1,"url":"\#(cdn)/gone.png?","mime":"image/png"},{"id":2,"url":"\#(cdn)/p.png","mime":"image/png"}"#)
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["600x900": list])).art(title: "Chrono Trigger")
    #expect(art.images.first == ArtworkImage(assetType: 0, ext: "png", data: "cC5wbmc="))
}

@Test func gameNotFoundMeansNoArt() async throws {
    for answer in [(Data(), 404), reply("")] {
        let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": answer])).art(title: "Chrono Trigger")
        #expect(art.images.isEmpty && art.icon == nil)
    }
}

@Test func missingKindIsLeftOutButTheRestStillCome() async throws {
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["/heroes/": (Data(), 404), "\(cdn)/logo.png": (Data(), 500)])).art(title: "Chrono Trigger")
    #expect(art.images.map(\.assetType) == [0, 3])
    #expect(art.icon != nil)
}

@Test func oversizedImageIsDropped() async throws {
    let huge = (Data(count: SteamGridDB.maxImageBytes + 1), 200)
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["\(cdn)/p.png": huge])).art(title: "Chrono Trigger")
    #expect(!art.images.contains { $0.assetType == 0 })
}

@Test func rateLimitStopsTheFetch() async {
    await #expect(throws: RAError.http(429)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": (Data(), 429)]), sleep: { _ in }).art(title: "Chrono Trigger")
    }
    await #expect(throws: RAError.http(429)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/heroes/": (Data(), 429)]), sleep: { _ in }).art(title: "Chrono Trigger")
    }
}

@Test func networkFailureNeverCarriesTheKey() async {
    await #expect(throws: RAError.network) { try await SteamGridDB(key: secret, transport: ThrowingTransport()).art(title: "Chrono Trigger") }
}

@Test func bridgeSavesTheIconAndNeverSendsTheKeyToSteam() async throws {
    let dir = tempDir()
    let handler = BridgeHandler(services: { nil }, actions: BridgeActions(), push: { _ in },
                                folderFile: dir.appendingPathComponent("folder.txt"), artwork: SteamGridDB(key: secret, transport: gridDB()))
    let out = try await handler.handle(method: "artwork", params: Data(#"{"title":"Chrono Trigger","appid":123}"#.utf8))
    #expect(!String(decoding: out, as: UTF8.self).contains(secret))
    let json = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect((json["images"] as? [Any])?.count == 4)
    let path = try #require(json["iconPath"] as? String)
    #expect(URL(fileURLWithPath: path).lastPathComponent == "123.png")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("icon.png".utf8))
}

@Test func unmaskRestoresTheBuildTimeKey() {
    // "ab" with each byte XORed with 0x5A, as scripts/embed-sgdb-key.sh writes it.
    #expect(SteamGridDBKey.unmask([59, 56]) == "ab")
    #expect(SteamGridDBKey.unmask([]) == "")
}

@Test func titlesAreCleanedForSearch() {
    let cases = [
        ("Legend of Zelda, The - A Link to the Past (USA) (Rev 1)", "The Legend of Zelda - A Link to the Past"),
        ("Super Mario World (USA).zip", "Super Mario World"),
        ("Pokemon - Red Version", "Pokemon - Red Version"),
        ("~Hack~ Something", "Something"),
        ("Final Fantasy VII (Disc 1)", "Final Fantasy VII"),
        ("Final Fantasy VII (USA) (Disc 2) [!]", "Final Fantasy VII"),
        ("Pilotwings 64 Rev A", "Pilotwings 64"),
        ("Last of Us, The: Part II", "The Last of Us: Part II"),
        ("Disk Warrior", "Disk Warrior"),
        ("Dr. Mario", "Dr. Mario"),
    ]
    for (raw, want) in cases { #expect(SteamGridDB.clean(raw) == want, "\(raw)") }
    #expect(SteamGridDB.searchTerms("Pokemon - Red Version") == ["Pokemon - Red Version", "Pokemon: Red Version", "Pokemon"])
    #expect(SteamGridDB.searchTerms("Chrono Trigger") == ["Chrono Trigger"])
}

@Test func scoringPrefersTheRightGame() {
    #expect(SteamGridDB.score("The Legend of Zelda: A Link to the Past", "Legend of Zelda, A Link to the Past") == 1)
    #expect(SteamGridDB.score("Pokemon Red", "Pokémon Red & Blue") > SteamGridDB.minScore)
    #expect(SteamGridDB.score("Final Fantasy VII", "Final Fantasy 7") == 1)
    #expect(SteamGridDB.score("Final Fantasy VII", "Final Fantasy VIII") < SteamGridDB.minScore)
    #expect(SteamGridDB.score("Sonic", "Mega Man X") == 0)
    #expect(SteamGridDB.score("Sonic Advance", "Sonic Advance 2", verified: true) > SteamGridDB.score("Sonic Advance", "Sonic Advance 2"))
    let games = [SteamGridDB.Game(id: 1, name: "Zelda II: The Adventure of Link", verified: true),
                 SteamGridDB.Game(id: 2, name: "The Legend of Zelda: A Link to the Past", verified: false)]
    #expect(SteamGridDB.ranked("Legend of Zelda - A Link to the Past", games).map(\.game.id) == [2, 1])
}

@Test func firstHitIsNotTrustedWhenTheSecondMatches() async throws {
    let search = reply(#"{"id":5,"name":"Chrono Cross","verified":true},{"id":77,"name":"Chrono Trigger","verified":false}"#)
    let fake = gridDB(override: ["/search/": search])
    let art = try await SteamGridDB(key: secret, transport: fake).art(title: "Chrono Trigger (USA)")
    #expect(art.images.count == 4)
    #expect(fake.urls.contains { $0.path.hasSuffix("/grids/game/77") })
}

@Test func noConvincingMatchMeansNoArt() async throws {
    let fake = gridDB(override: ["/search/": reply(#"{"id":5,"name":"Mega Man X","verified":true}"#)])
    let art = try await SteamGridDB(key: secret, transport: fake).art(title: "Chrono Trigger")
    #expect(art.images.isEmpty && art.icon == nil)
    #expect(!fake.urls.contains { $0.path.contains("/grids/") })
}

@Test func subtitleIsDroppedForASecondSearch() async throws {
    // Only the bare title finds the game.
    let fake = FakeTransport { url in
        url.absoluteString.hasSuffix("/search/autocomplete/Pokemon") ? reply(#"{"id":9,"name":"Pokemon","verified":true}"#) : reply("")
    }
    _ = try await SteamGridDB(key: secret, transport: fake).art(title: "Pokemon - Red Version")
    #expect(fake.urls.filter { $0.path.contains("/search/") }.count == 3)
    #expect(fake.urls.contains { $0.path.hasSuffix("/grids/game/9") })
}

private final class Naps: @unchecked Sendable {
    var seconds: [Double] = []
    private let lock = NSLock()
    func add(_ s: Double) { lock.withLock { seconds.append(s) } }
}

@Test func rateLimitIsRetriedWithBackoffThenSucceeds() async throws {
    let calls = Naps(), naps = Naps()
    let transport = FakeTransport { url in
        if url.path.contains("/search/") { calls.add(0); return calls.seconds.count < 3 ? (Data(), 429) : reply(#"{"id":77,"name":"Chrono Trigger"}"#) }
        return gridDB().respond(url)
    }
    let art = try await SteamGridDB(key: secret, transport: transport, sleep: { naps.add($0) }).art(title: "Chrono Trigger")
    #expect(naps.seconds == [1, 3])
    #expect(art.images.count == 4)
}

@Test func retriesStopAfterTwoAndServerErrorsCount() async {
    let naps = Naps()
    await #expect(throws: RAError.http(503)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": (Data(), 503)]), sleep: { naps.add($0) }).art(title: "Chrono Trigger")
    }
    #expect(naps.seconds.count == 2)
    let bad = Naps()
    await #expect(throws: RAError.http(403)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": (Data(), 403)]), sleep: { bad.add($0) }).art(title: "Chrono Trigger")
    }
    #expect(bad.seconds.isEmpty)
}

@Test func nextImageIsTriedWhenADownloadFails() async throws {
    let list = reply(#"{"id":1,"url":"\#(cdn)/a.png"},{"id":2,"url":"\#(cdn)/b.png"},{"id":3,"url":"\#(cdn)/c.png"},{"id":4,"url":"\#(cdn)/d.png"}"#)
    let fake = gridDB(override: ["600x900": list, "\(cdn)/a.png": (Data(), 404), "\(cdn)/b.png": (Data(), 500)])
    let art = try await SteamGridDB(key: secret, transport: fake).art(title: "Chrono Trigger")
    #expect(art.images.first == ArtworkImage(assetType: 0, ext: "png", data: Data("c.png".utf8).base64EncodedString()))
    // Three tries at most: d.png is never asked for.
    let none = gridDB(override: ["600x900": list, "\(cdn)/a.png": (Data(), 404), "\(cdn)/b.png": (Data(), 404), "\(cdn)/c.png": (Data(), 404)])
    #expect(!(try await SteamGridDB(key: secret, transport: none).art(title: "Chrono Trigger")).images.contains { $0.assetType == 0 })
    #expect(!none.urls.contains { $0.lastPathComponent == "d.png" })
}

@Test func applyArtworkOnlyFetchesSteamGridDBImages() async throws {
    let fake = gridDB()
    let db = SteamGridDB(key: secret, transport: fake)
    for bad in ["https://evil.example/p.png", "http://cdn2.steamgriddb.com/p.png", "\(cdn)/p.gif"] {
        await #expect(throws: RAError.decoding) { try await db.fetch(kind: "grid", url: bad) }
    }
    #expect(fake.urls.isEmpty)
    let ok = try await db.fetch(kind: "hero", url: "\(cdn)/hero.png")
    #expect(ok.image == ArtworkImage(assetType: 1, ext: "png", data: Data("hero.png".utf8).base64EncodedString()) && ok.icon == nil)
    let icon = try await db.fetch(kind: "icon", url: "\(cdn)/icon.png")
    #expect(icon.image == nil && icon.icon == Data("icon.png".utf8))
}

@Test func artworkSearchAndOptionsThroughTheBridge() async throws {
    let search = reply(#"{"id":5,"name":"Chrono Cross","verified":true,"release_date":946684800},{"id":77,"name":"Chrono Trigger","verified":true,"release_date":792979200}"#)
    let list = reply(#"{"id":1,"url":"\#(cdn)/a.png","thumb":"\#(cdn)/t/a.jpg","width":600,"height":900,"style":"alternate","author":{"name":"bob"}},{"id":2,"url":"https://evil.example/b.png"}"#)
    let handler = BridgeHandler(services: { nil }, actions: BridgeActions(), push: { _ in }, folderFile: tempDir().appendingPathComponent("folder.txt"),
                                artwork: SteamGridDB(key: secret, transport: gridDB(override: ["/search/": search, "600x900": list])))
    func call(_ m: String, _ p: String) async throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: try await handler.handle(method: m, params: Data(p.utf8))) as? [[String: Any]])
    }
    let hits = try await call("artworkSearch", #"{"query":"Chrono Trigger (USA)"}"#)
    #expect(hits.map { $0["id"] as? Int } == [77, 5])
    #expect(hits[0]["year"] as? Int == 1995)
    let options = try await call("artworkOptions", #"{"gameId":77,"kind":"grid"}"#)
    #expect(options.count == 1 && options[0]["thumb"] as? String == "\(cdn)/t/a.jpg" && options[0]["author"] as? String == "bob")
}
