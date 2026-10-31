import Foundation

/// Everything that needs a signed-in user.
public struct Services: Sendable {
    public let ra: CachedRA
    public let matcher: Matcher

    public init(credentials: RACredentials, dataDirectory: URL, transport: HTTPTransport = URLSessionTransport()) {
        ra = CachedRA(client: RAClient(credentials: credentials, transport: transport),
                      cache: DiskCache(directory: dataDirectory.appendingPathComponent("cache")))
        matcher = Matcher(ra: ra, hasher: RomHasher(), store: MatchStore(file: dataDirectory.appendingPathComponent("matches.json")))
    }
}

public struct BridgeActions: Sendable {
    public var openSettings, openAddGames: @Sendable () async -> Void
    public var openURL: @Sendable (URL) async -> Void
    public var log: @Sendable (String, String) -> Void

    public init(openSettings: @escaping @Sendable () async -> Void, openAddGames: @escaping @Sendable () async -> Void,
                openURL: @escaping @Sendable (URL) async -> Void, log: @escaping @Sendable (String, String) -> Void) {
        self.openSettings = openSettings; self.openAddGames = openAddGames; self.openURL = openURL; self.log = log
    }
}

extension CachedRA: @unchecked Sendable {}

/// The app side of the bridge protocol `steam/inject.js` speaks (plan Task 10).
public final class BridgeHandler: BridgeHandling {
    let services: @Sendable () async -> Services?
    let actions: BridgeActions
    let push: @Sendable (String) async -> Void

    public init(services: @escaping @Sendable () async -> Services?, actions: BridgeActions, push: @escaping @Sendable (String) async -> Void) {
        self.services = services; self.actions = actions; self.push = push
    }

    struct ShortcutParams: Decodable { var shortcut: ShortcutInfo }
    struct SearchParams: Decodable { var consoleId: Int; var query: String }
    struct ChooseParams: Decodable { var shortcut: ShortcutInfo; var gameId: Int; var consoleId: Int }
    struct LogParams: Decodable { var level: String; var message: String }
    struct URLParams: Decodable { var url: String }
    struct SearchResult: Encodable { var gameId: Int; var title, consoleName, iconURL: String; var numAchievements: Int }
    struct ConsoleResult: Encodable { var id: Int; var name: String }

    public func handle(method: String, params: Data) async throws -> Data {
        let d = JSONDecoder()
        switch method {
        case "log":
            let p = try d.decode(LogParams.self, from: params)
            actions.log(p.level, p.message)
            return Data("null".utf8)
        case "getPanel":
            return try encode(await panel(try d.decode(ShortcutParams.self, from: params).shortcut, fresh: false))
        case "refreshPanel":
            return try encode(await panel(try d.decode(ShortcutParams.self, from: params).shortcut, fresh: true))
        case "chooseGame":
            let p = try d.decode(ChooseParams.self, from: params)
            guard let s = await services() else { return try encode(PanelBuilder.signedOut()) }
            let resolution = try await s.matcher.choose(p.shortcut, gameId: p.gameId, consoleId: p.consoleId)
            return try encode(await payload(for: resolution, p.shortcut, s, fresh: true))
        case "searchGames":
            let p = try d.decode(SearchParams.self, from: params)
            guard let s = await services() else { return try encode([SearchResult]()) }
            return try encode(try await s.matcher.search(query: p.query, consoleId: p.consoleId).map {
                SearchResult(gameId: $0.id, title: $0.title, consoleName: $0.consoleName,
                             iconURL: PanelBuilder.media + $0.imageIcon, numAchievements: $0.numAchievements)
            })
        case "consoles":
            return try encode(Consoles.all.map { ConsoleResult(id: $0.id, name: $0.name) })
        case "openSettings":
            await actions.openSettings()
            return Data("null".utf8)
        case "openAddGames":
            await actions.openAddGames()
            return Data("null".utf8)
        case "openURL":
            let p = try d.decode(URLParams.self, from: params)
            guard BridgeRouter.isAllowedExternalURL(p.url), let url = URL(string: p.url) else { throw BridgeError.urlNotAllowed }
            await actions.openURL(url)
            return Data("null".utf8)
        default:
            throw BridgeError.unknownMethod(method)
        }
    }

    enum BridgeError: Error { case unknownMethod(String), urlNotAllowed }

    private func panel(_ shortcut: ShortcutInfo, fresh: Bool) async -> PanelPayload {
        guard let s = await services() else { return PanelBuilder.signedOut() }
        do {
            return await payload(for: try await s.matcher.resolve(shortcut), shortcut, s, fresh: fresh)
        } catch {
            actions.log("error", "resolve: \(error)")
            return PanelBuilder.failed(cached: nil, savedAt: nil)
        }
    }

    /// Cached progress answers at once and a fresh copy is pushed later, unless `fresh` asks to wait for the network.
    private func payload(for r: Resolution, _ shortcut: ShortcutInfo, _ s: Services, fresh: Bool) async -> PanelPayload {
        guard case let .matched(gameId, _, verification) = r else {
            if case let .notMatched(consoleId, verification) = r { return PanelBuilder.notMatched(consoleId: consoleId, verification: verification) }
            return PanelBuilder.hidden()
        }
        let emulator = EmulatorLaunch.parse(exe: shortcut.exe, launchOptions: shortcut.launchOptions)?.emulator.displayName ?? "the emulator"
        let cached = s.ra.cachedProgress(gameId: gameId)
        let cachedPayload = cached.map { PanelBuilder.matched($0.value, verification: verification, emulatorName: emulator, stale: true, savedAt: $0.savedAt) }

        if let cachedPayload, !fresh {
            let push = push, actions = actions, appid = shortcut.appid
            Task {
                guard let p = try? await s.ra.gameProgress(gameId: gameId) else { return }
                let payload = PanelBuilder.matched(p, verification: verification, emulatorName: emulator, stale: false, savedAt: nil)
                guard let json = try? Self.encoder.encode(payload) else { return }
                actions.log("info", "pushing fresh progress for \(gameId)")
                await push("window.__sra.update({\"appid\":\(appid),\"payload\":\(String(decoding: json, as: UTF8.self))})")
            }
            return cachedPayload
        }
        do {
            let p = try await s.ra.gameProgress(gameId: gameId)
            return PanelBuilder.matched(p, verification: verification, emulatorName: emulator, stale: false, savedAt: nil)
        } catch {
            actions.log("error", "progress \(gameId): \(error)")
            return PanelBuilder.failed(cached: cachedPayload, savedAt: cached?.savedAt)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    private func encode<T: Encodable>(_ v: T) throws -> Data { try Self.encoder.encode(v) }
}
