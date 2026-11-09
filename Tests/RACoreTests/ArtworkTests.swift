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
        let art = try await SteamGridDB(key: secret, transport: fake).art(title: "x")
        #expect(!art.images.contains { $0.assetType == 0 })
        #expect(!fake.urls.contains { $0.lastPathComponent == "p.png" })
    }
}

@Test func takedownPlaceholdersAreSkippedForTheNextImage() async throws {
    // SteamGridDB marks images removed by a DMCA notice with a URL ending in "?".
    let list = reply(#"{"id":1,"url":"\#(cdn)/gone.png?","mime":"image/png"},{"id":2,"url":"\#(cdn)/p.png","mime":"image/png"}"#)
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["600x900": list])).art(title: "x")
    #expect(art.images.first == ArtworkImage(assetType: 0, ext: "png", data: "cC5wbmc="))
}

@Test func gameNotFoundMeansNoArt() async throws {
    for answer in [(Data(), 404), reply("")] {
        let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": answer])).art(title: "x")
        #expect(art.images.isEmpty && art.icon == nil)
    }
}

@Test func missingKindIsLeftOutButTheRestStillCome() async throws {
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["/heroes/": (Data(), 404), "\(cdn)/logo.png": (Data(), 500)])).art(title: "x")
    #expect(art.images.map(\.assetType) == [0, 3])
    #expect(art.icon != nil)
}

@Test func oversizedImageIsDropped() async throws {
    let huge = (Data(count: SteamGridDB.maxImageBytes + 1), 200)
    let art = try await SteamGridDB(key: secret, transport: gridDB(override: ["\(cdn)/p.png": huge])).art(title: "x")
    #expect(!art.images.contains { $0.assetType == 0 })
}

@Test func rateLimitStopsTheFetch() async {
    await #expect(throws: RAError.http(429)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/search/": (Data(), 429)])).art(title: "x")
    }
    await #expect(throws: RAError.http(429)) {
        try await SteamGridDB(key: secret, transport: gridDB(override: ["/heroes/": (Data(), 429)])).art(title: "x")
    }
}

@Test func networkFailureNeverCarriesTheKey() async {
    await #expect(throws: RAError.network) { try await SteamGridDB(key: secret, transport: ThrowingTransport()).art(title: "x") }
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
