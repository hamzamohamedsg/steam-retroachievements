import Foundation

/// Everything that needs a signed-in user.
public struct Services: Sendable {
    public let ra: CachedRA
    public let matcher: Matcher
    public let playtimeHistory: PlaytimeHistory

    public init(credentials: RACredentials, dataDirectory: URL, transport: HTTPTransport = URLSessionTransport()) {
        ra = CachedRA(client: RAClient(credentials: credentials, transport: transport),
                      cache: DiskCache(directory: dataDirectory.appendingPathComponent("cache")))
        matcher = Matcher(ra: ra, hasher: RomHasher(), store: MatchStore(file: dataDirectory.appendingPathComponent("matches.json")))
        playtimeHistory = PlaytimeHistory(file: dataDirectory.appendingPathComponent("playtime.json"))
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
    let chosenEmulators: ChosenEmulators?

    /// `installed` defaults to detecting emulators, the ones picked in Settings (`chosenEmulators`) first.
    public init(services: @escaping @Sendable () async -> Services?, actions: BridgeActions, push: @escaping @Sendable (String) async -> Void,
                chosenEmulators: ChosenEmulators? = nil, installed: (@Sendable () -> Installed)? = nil, hasher: any Fingerprinting = RomHasher()) {
        self.services = services; self.actions = actions; self.push = push; self.hasher = hasher; self.chosenEmulators = chosenEmulators
        self.installed = installed ?? { .detect(chosen: chosenEmulators?.load() ?? [:]) }
    }

    struct ShortcutParams: Decodable { var shortcut: ShortcutInfo }
    struct SearchParams: Decodable { var consoleId: Int; var query: String }
    struct ChooseParams: Decodable { var shortcut: ShortcutInfo; var gameId: Int; var consoleId: Int }
    struct LogParams: Decodable { var level: String; var message: String }
    struct URLParams: Decodable { var url: String }
    struct SearchResult: Encodable { var gameId: Int; var title, consoleName, iconURL: String; var numAchievements: Int }
    struct ConsoleResult: Encodable { var id: Int; var name: String }
    struct SignInParams: Decodable { var username, apiKey: String }
    struct ErrorResult: Encodable { var error: String? }
    struct ToggleParams: Decodable { var on: Bool }
    struct ChooseEmulatorParams: Decodable { var emulator: Emulator; var path: String }
    /// `path` is the program the app starts it with; nil when none was found.
    struct EmulatorStatus: Encodable { var id, name: String; var path: String? }
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
    /// `missingEmulators`: ones some of the games need that weren't found, so the dialog can offer to find them.
    struct ScanResult: Encodable { var folder: String; var missingEmulators: [Choice]; var items: [ScanRow] }
    struct PlaytimeParams: Decodable { var shortcuts: [ShortcutInfo] }
    /// Steam's own units: whole minutes, and a Unix time.
    struct Playtime: Encodable { var appid: UInt32; var minutes, lastPlayed, twoWeeks: Int }

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
        case "settings":
            let (username, openAtLogin) = await actions.account()
            let found = installed().emulators
            return try encode(SettingsResult(username: username, openAtLogin: openAtLogin, emulators: Emulator.allCases.map {
                EmulatorStatus(id: $0.rawValue, name: $0.displayName, path: found[$0].map { $0.args.isEmpty ? $0.exe : "\($0.exe) \($0.args)" })
            }))
        case "chooseEmulator":
            let p = try d.decode(ChooseEmulatorParams.self, from: params)
            guard let chosenEmulators else { return try encode(ErrorResult(error: "Choosing emulators isn't available.")) }
            return try encode(ErrorResult(error: chosenEmulators.choose(p.emulator, path: p.path)))
        case "signIn":
            let p = try d.decode(SignInParams.self, from: params)
            return try encode(ErrorResult(error: await actions.signIn(p.username, p.apiKey)))
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
        case "playtimes":
            let p = try d.decode(PlaytimeParams.self, from: params)
            guard let s = await services() else { return try encode([Playtime]()) }
            return try encode(await playtimes(p.shortcuts, s))
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
        // A game with no emulator waits on its console's first choice; RetroArch present but missing a core needs a download, not this.
        var missing: [Emulator] = []
        for item in items {
            guard case .noEmulator = item.status, let e = item.consoleId.flatMap({ EmulatorPreference.order(for: $0).first }),
                  installed.emulators[e] == nil, !missing.contains(e) else { continue }
            missing.append(e)
        }
        return ScanResult(folder: folder.path, missingEmulators: missing.map { Choice(id: $0.rawValue, name: $0.displayName) }, items: items.map { item in
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

    static let recentPages = 10

    /// RA's playtime and last-played time for the shortcuts whose games the user has played, for Steam's Play Time and Last Played.
    /// Progress is fetched only for games played since it was last saved.
    private func playtimes(_ shortcuts: [ShortcutInfo], _ s: Services) async -> [Playtime] {
        var lastPlayed: [Int: Date] = [:]
        // shortcut: reads the 500 most recently played games; older ones keep Steam's own (empty) playtime
        for page in 0..<Self.recentPages {
            let games: [RARecentGame]
            do { games = try await s.ra.recentlyPlayed(offset: page * 50) } catch {
                actions.log("error", "recently played: \(error)")
                break
            }
            // No last-played time: its playtime still counts, and any saved progress is as new as it gets.
            for g in games where lastPlayed[g.gameId] == nil { lastPlayed[g.gameId] = g.lastPlayed ?? .distantPast }
            if games.count < 50 { break }
        }
        var out: [Playtime] = []
        for shortcut in shortcuts {
            guard case let .matched(gameId, _, _)? = try? await s.matcher.resolve(shortcut), let played = lastPlayed[gameId] else { continue }
            let cached = s.ra.cachedProgress(gameId: gameId)
            var progress = cached.flatMap { $0.savedAt > played && $0.value.userTotalPlaytime != nil ? $0.value : nil }
            if progress == nil { progress = (try? await s.ra.gameProgress(gameId: gameId)) ?? cached?.value }
            guard let seconds = progress?.userTotalPlaytime else { continue }
            let twoWeeks = s.playtimeHistory.lastTwoWeeks(gameId: gameId, total: seconds, lastPlayed: played)
            out.append(Playtime(appid: shortcut.appid, minutes: (seconds + 59) / 60, lastPlayed: max(0, Int(played.timeIntervalSince1970)),
                                twoWeeks: (twoWeeks + 59) / 60))
        }
        actions.log("info", "playtime for \(out.count) of \(shortcuts.count) shortcuts (\(lastPlayed.count) games played)")
        return out
    }

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
    /// Subsets (separate RA games) ride along as nested panels; one that can't be fetched falls back to its cached copy, or is left out.
    private func payload(for r: Resolution, _ shortcut: ShortcutInfo, _ s: Services, fresh: Bool) async -> PanelPayload {
        guard case let .matched(gameId, consoleId, verification) = r else {
            if case let .notMatched(consoleId, verification) = r { return PanelBuilder.notMatched(consoleId: consoleId, verification: verification) }
            return PanelBuilder.hidden()
        }
        let emulator = EmulatorLaunch.parse(exe: shortcut.exe, launchOptions: shortcut.launchOptions)?.emulator.displayName ?? "the emulator"
        let subsetIds = ((try? await s.matcher.subsets(gameId: gameId, consoleId: consoleId)) ?? []).map(\.id)
        @Sendable func build(_ base: RAGameProgress, _ subsets: [RAGameProgress], stale: Bool, savedAt: Date?) -> PanelPayload {
            var out = PanelBuilder.matched(base, verification: verification, emulatorName: emulator, stale: stale, savedAt: savedAt)
            out.subsets = subsets.map { PanelBuilder.matched($0, verification: .verified, emulatorName: emulator, stale: false, savedAt: nil) }
            return out
        }
        @Sendable func fetch() async throws -> PanelPayload {
            let base = try await s.ra.gameProgress(gameId: gameId)
            var subsets: [RAGameProgress] = []
            for id in subsetIds {
                if let p = (try? await s.ra.gameProgress(gameId: id)) ?? s.ra.cachedProgress(gameId: id)?.value { subsets.append(p) }
            }
            return build(base, subsets, stale: false, savedAt: nil)
        }
        let cached = s.ra.cachedProgress(gameId: gameId)
        let cachedPayload = cached.map { build($0.value, subsetIds.compactMap { s.ra.cachedProgress(gameId: $0)?.value }, stale: true, savedAt: $0.savedAt) }

        if let cachedPayload, !fresh {
            let push = push, actions = actions, appid = shortcut.appid
            Task {
                guard let payload = try? await fetch(), let json = try? Self.encoder.encode(payload) else { return }
                actions.log("info", "pushing fresh progress for \(gameId)")
                await push("window.__sra.update({\"appid\":\(appid),\"payload\":\(String(decoding: json, as: UTF8.self))})")
            }
            return cachedPayload
        }
        do {
            return try await fetch()
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
