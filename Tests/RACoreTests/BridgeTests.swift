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
    let handler = BridgeHandler(services: { services }, actions: BridgeActions(openSettings: {}, openAddGames: {}, openURL: { _ in }, log: { _, _ in }),
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
