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

/// What the Settings dialog in Steam asks the app to do.
public struct BridgeActions: Sendable {
    public var openURL: @Sendable (URL) async -> Void
    public var log: @Sendable (String, String) -> Void
    /// The signed-in username, and whether the app opens at login.
    public var account: @Sendable () async -> (username: String?, openAtLogin: Bool)
    /// nil on success, otherwise the error to show.
    public var signIn: @Sendable (_ username: String, _ apiKey: String) async -> String?
    public var signOut: @Sendable () async -> Void
    /// Returns the setting now in effect.
    public var setOpenAtLogin: @Sendable (Bool) async -> Bool
    public var uninstall: @Sendable () async -> Void

    public init(openURL: @escaping @Sendable (URL) async -> Void = { _ in }, log: @escaping @Sendable (String, String) -> Void = { _, _ in },
                account: @escaping @Sendable () async -> (username: String?, openAtLogin: Bool) = { (nil, false) },
                signIn: @escaping @Sendable (String, String) async -> String? = { _, _ in nil }, signOut: @escaping @Sendable () async -> Void = {},
                setOpenAtLogin: @escaping @Sendable (Bool) async -> Bool = { $0 }, uninstall: @escaping @Sendable () async -> Void = {}) {
        self.openURL = openURL; self.log = log; self.account = account; self.signIn = signIn; self.signOut = signOut
        self.setOpenAtLogin = setOpenAtLogin; self.uninstall = uninstall
    }
}

extension CachedRA: @unchecked Sendable {}

/// The app side of the bridge protocol `steam/inject.js` speaks (plan Task 10).
public final class BridgeHandler: BridgeHandling {
    let services: @Sendable () async -> Services?
    let actions: BridgeActions
    let push: @Sendable (String) async -> Void
    let installed: @Sendable () -> Installed
    let hasher: any Fingerprinting

    public init(services: @escaping @Sendable () async -> Services?, actions: BridgeActions, push: @escaping @Sendable (String) async -> Void,
                installed: @escaping @Sendable () -> Installed = { .detect() }, hasher: any Fingerprinting = RomHasher()) {
        self.services = services; self.actions = actions; self.push = push; self.installed = installed; self.hasher = hasher
    }

    struct ShortcutParams: Decodable { var shortcut: ShortcutInfo }
    struct SearchParams: Decodable { var consoleId: Int; var query: String }
    struct SetParams: Decodable { var shortcut: ShortcutInfo; var gameId: Int }
    struct ChooseParams: Decodable { var shortcut: ShortcutInfo; var gameId: Int; var consoleId: Int }
    struct LogParams: Decodable { var level: String; var message: String }
    struct URLParams: Decodable { var url: String }
    struct SearchResult: Encodable { var gameId: Int; var title, consoleName, iconURL: String; var numAchievements: Int }
    struct ConsoleResult: Encodable { var id: Int; var name: String }
    struct SignInParams: Decodable { var username, apiKey: String }
    struct SignInResult: Encodable { var error: String? }
    struct ToggleParams: Decodable { var on: Bool }
    struct EmulatorStatus: Encodable { var name: String; var installed: Bool }
    struct SettingsResult: Encodable { var username: String?; var openAtLogin: Bool; var emulators: [EmulatorStatus] }
    struct ShortcutLine: Decodable { var exe, launchOptions: String }
    /// Override keys are a folder path and a console id (as text: JSON object keys).
    struct ScanParams: Decodable { var folder: String?; var shortcuts: [ShortcutLine]; var consoleOverrides: [String: Int]; var emulatorOverrides: [String: Emulator] }
    struct Choice: Encodable { var id, name: String }
    struct ScanRow: Encodable {
        var id, title, folder, status, statusText: String
        var consoleId: Int?, consoleName: String?, emulator: String?
        var emulatorChoices: [Choice]
        var shortcut: ShortcutSpec?
    }
    struct ScanResult: Encodable { var folder: String; var items: [ScanRow] }

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
        case "getSet":
            let p = try d.decode(SetParams.self, from: params)
            return try encode(await panel(p.shortcut, fresh: true, showing: p.gameId))
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
        case "settings":
            let (username, openAtLogin) = await actions.account()
            let found = installed().emulators
            return try encode(SettingsResult(username: username, openAtLogin: openAtLogin,
                                             emulators: Emulator.allCases.map { EmulatorStatus(name: $0.displayName, installed: found[$0] != nil) }))
        case "signIn":
            let p = try d.decode(SignInParams.self, from: params)
            return try encode(SignInResult(error: await actions.signIn(p.username, p.apiKey)))
        case "signOut":
            await actions.signOut()
            return Data("null".utf8)
        case "setOpenAtLogin":
            return try encode(await actions.setOpenAtLogin(try d.decode(ToggleParams.self, from: params).on))
        case "uninstall":
            await actions.uninstall()
            return Data("null".utf8)
        case "scanGames":
            return try encode(scan(try d.decode(ScanParams.self, from: params)))
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

    private func scan(_ p: ScanParams) -> ScanResult {
        let installed = installed()
        let folder = p.folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Scanner.defaultFolder()
        let existing = Set(p.shortcuts.compactMap { EmulatorLaunch.parse(exe: $0.exe, launchOptions: $0.launchOptions)?.romPath })
        let emulatorOverrides = Dictionary(p.emulatorOverrides.compactMap { k, v in Int(k).map { ($0, v) } }) { a, _ in a }
        let items = Scanner(installed: installed, hasher: hasher)
            .scan(folder: folder, existingRomPaths: existing, consoleOverrides: p.consoleOverrides, emulatorOverrides: emulatorOverrides)
        return ScanResult(folder: folder.path, items: items.map { item in
            let (status, text): (String, String) = switch item.status {
            case .ready: ("ready", "Ready")
            case .alreadyInSteam: ("alreadyInSteam", "Already in Steam")
            case .noEmulator(let hint): ("noEmulator", hint)
            case .chooseConsole: ("chooseConsole", "Choose a console")
            }
            var choices = item.consoleId.map(EmulatorPreference.order(for:)) ?? []
            if item.consoleId != nil, !choices.contains(.retroarch) { choices.append(.retroarch) }
            return ScanRow(id: item.romPath, title: item.title, folder: (item.romPath as NSString).deletingLastPathComponent, status: status, statusText: text,
                           consoleId: item.consoleId, consoleName: item.consoleId.flatMap(Consoles.byID)?.name, emulator: item.emulator?.rawValue,
                           emulatorChoices: choices.filter { installed.emulators[$0] != nil }.map { Choice(id: $0.rawValue, name: $0.displayName) },
                           shortcut: item.status == .ready ? Scanner.shortcut(for: item, installed: installed) : nil)
        })
    }

    private func panel(_ shortcut: ShortcutInfo, fresh: Bool, showing set: Int? = nil) async -> PanelPayload {
        guard let s = await services() else { return PanelBuilder.signedOut() }
        do {
            return await payload(for: try await s.matcher.resolve(shortcut), shortcut, s, fresh: fresh, showing: set)
        } catch {
            actions.log("error", "resolve: \(error)")
            return PanelBuilder.failed(cached: nil, savedAt: nil)
        }
    }

    /// Cached progress answers at once and a fresh copy is pushed later, unless `fresh` asks to wait for the network.
    /// `set` shows one of the matched game's subsets instead of the game itself.
    private func payload(for r: Resolution, _ shortcut: ShortcutInfo, _ s: Services, fresh: Bool, showing set: Int? = nil) async -> PanelPayload {
        guard case let .matched(baseId, consoleId, verification) = r else {
            if case let .notMatched(consoleId, verification) = r { return PanelBuilder.notMatched(consoleId: consoleId, verification: verification) }
            return PanelBuilder.hidden()
        }
        let sets = (try? await s.matcher.sets(gameId: baseId, consoleId: consoleId)) ?? []
        let gameId = set.flatMap { id in sets.contains { $0.id == id } ? id : nil } ?? baseId
        let build = { (p: RAGameProgress, stale: Bool, savedAt: Date?, emulator: String) -> PanelPayload in
            var out = PanelBuilder.matched(p, verification: verification, emulatorName: emulator, stale: stale, savedAt: savedAt)
            out.sets = sets
            return out
        }
        let emulator = EmulatorLaunch.parse(exe: shortcut.exe, launchOptions: shortcut.launchOptions)?.emulator.displayName ?? "the emulator"
        let cached = s.ra.cachedProgress(gameId: gameId)
        let cachedPayload = cached.map { build($0.value, true, $0.savedAt, emulator) }

        if let cachedPayload, !fresh {
            let push = push, actions = actions, appid = shortcut.appid
            Task {
                guard let p = try? await s.ra.gameProgress(gameId: gameId) else { return }
                let payload = build(p, false, nil, emulator)
                guard let json = try? Self.encoder.encode(payload) else { return }
                actions.log("info", "pushing fresh progress for \(gameId)")
                await push("window.__sra.update({\"appid\":\(appid),\"payload\":\(String(decoding: json, as: UTF8.self))})")
            }
            return cachedPayload
        }
        do {
            let p = try await s.ra.gameProgress(gameId: gameId)
            return build(p, false, nil, emulator)
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
