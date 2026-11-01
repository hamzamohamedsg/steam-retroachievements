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
