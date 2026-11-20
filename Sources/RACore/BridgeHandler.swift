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
    /// Whether Steam's debug switch stays on after the app quits.
    public var keepDebugPort: @Sendable () async -> Bool
    /// Returns the setting now in effect.
    public var setKeepDebugPort: @Sendable (Bool) async -> Bool
    public var uninstall: @Sendable () async -> Void
    /// The newer version on GitHub, if there is one.
    public var updateVersion: @Sendable () async -> String?
    /// Takes no input, so the page can't choose what gets installed. nil when the new copy is starting, otherwise the error to show.
    public var installUpdate: @Sendable () async -> String?
    /// Takes no input, so the page can't choose what gets opened.
    public var openLog: @Sendable () async -> Void
    /// Copy Diagnostics only: whether signed in, and what to scrub.
    public var credentials: @Sendable () async -> RACredentials?
    public var steamState: @Sendable () async -> String
    /// A folder the user picked in the system's dialog, nil if they cancelled or there is none.
    public var chooseFolder: @Sendable () async -> String?

    public init(openURL: @escaping @Sendable (URL) async -> Void = { _ in }, log: @escaping @Sendable (String, String) -> Void = { _, _ in },
                account: @escaping @Sendable () async -> (username: String?, openAtLogin: Bool) = { (nil, false) },
                signIn: @escaping @Sendable (String, String) async -> String? = { _, _ in nil }, signOut: @escaping @Sendable () async -> Void = {},
                setOpenAtLogin: @escaping @Sendable (Bool) async -> Bool = { $0 },
                keepDebugPort: @escaping @Sendable () async -> Bool = { true }, setKeepDebugPort: @escaping @Sendable (Bool) async -> Bool = { $0 },
                uninstall: @escaping @Sendable () async -> Void = {},
                updateVersion: @escaping @Sendable () async -> String? = { nil }, installUpdate: @escaping @Sendable () async -> String? = { nil },
                openLog: @escaping @Sendable () async -> Void = {}, credentials: @escaping @Sendable () async -> RACredentials? = { nil },
                steamState: @escaping @Sendable () async -> String = { "" }, chooseFolder: @escaping @Sendable () async -> String? = { nil }) {
        self.openURL = openURL; self.log = log; self.account = account; self.signIn = signIn; self.signOut = signOut
        self.setOpenAtLogin = setOpenAtLogin; self.keepDebugPort = keepDebugPort; self.setKeepDebugPort = setKeepDebugPort; self.uninstall = uninstall; self.updateVersion = updateVersion; self.installUpdate = installUpdate
        self.openLog = openLog; self.credentials = credentials; self.steamState = steamState
        self.chooseFolder = chooseFolder
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
    /// The ROM folders the user added, as a JSON array of paths (older versions saved one plain path).
    let folderFile: URL?
    let artwork: SteamGridDB
    let logFile: URL?
    let home: String

    public init(services: @escaping @Sendable () async -> Services?, actions: BridgeActions, push: @escaping @Sendable (String) async -> Void,
                installed: @escaping @Sendable () -> Installed = { .detect() }, hasher: any Fingerprinting = RomHasher(), folderFile: URL? = nil,
                artwork: SteamGridDB = SteamGridDB(), logFile: URL? = nil, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.services = services; self.actions = actions; self.push = push; self.installed = installed; self.hasher = hasher
        self.folderFile = folderFile; self.artwork = artwork; self.logFile = logFile; self.home = home
    }

    struct ShortcutParams: Decodable { var shortcut: ShortcutInfo }
    struct SearchParams: Decodable { var consoleId: Int; var query: String }
    struct ChooseParams: Decodable { var shortcut: ShortcutInfo; var gameId: Int; var consoleId: Int }
    struct LogParams: Decodable { var level: String; var message: String }
    struct URLParams: Decodable { var url: String }
    struct SearchResult: Encodable { var gameId: Int; var title, consoleName, iconURL: String; var numAchievements: Int }
    struct ConsoleResult: Encodable { var id: Int; var name: String }
    struct SignInParams: Decodable { var username, apiKey: String }
    struct SignInResult: Encodable { var error: String? }
    struct ToggleParams: Decodable { var on: Bool }
    struct EmulatorStatus: Encodable { var name: String; var installed: Bool }
    struct SettingsResult: Encodable { var username: String?; var openAtLogin, keepDebugPort: Bool; var emulators: [EmulatorStatus]; var updateVersion: String? }
    struct ShortcutLine: Decodable { var exe, launchOptions: String }
    /// Override keys are a folder path and a console id (as text: JSON object keys).
    struct ScanParams: Decodable { var folders: [String]?; var folder: String?; var shortcuts: [ShortcutLine]; var consoleOverrides: [String: Int]; var emulatorOverrides: [String: Emulator] }
    struct Choice: Encodable { var id, name: String }
    struct ScanRow: Encodable {
        var id, title, folder, status, statusText: String
        var consoleId: Int?, consoleName: String?, emulator: String?
        var emulatorChoices: [Choice]
        var shortcut: ShortcutSpec?
    }
    struct FolderRow: Encodable { var path: String; var missing: Bool }
    struct ScanResult: Encodable { var folders: [FolderRow]; var items: [ScanRow] }
    struct PathParams: Decodable { var path: String }
    struct PathResult: Encodable { var path: String? }
    struct PlaytimeParams: Decodable { var shortcuts: [ShortcutInfo] }
    /// Steam's own units: whole minutes, and a Unix time. `unlocked`/`total`: the main set, for Steam's library tiles.
    /// `failed`: RA couldn't answer for it this time, so Steam keeps what it shows; absent otherwise.
    struct Playtime: Encodable { var appid: UInt32; var minutes = 0, lastPlayed = 0, twoWeeks = 0, unlocked = 0, total = 0; var failed: Bool? }
    /// `since`: when the game started, a Unix time.
    struct UnlocksParams: Decodable { var since: Double }
    struct Unlock: Encodable { var id: Int; var title, description, image: String; var date: Int }
    struct ArtworkParams: Decodable { var title: String; var appid: UInt32 }
    struct ArtworkResult: Encodable { var images: [ArtworkImage]; var iconPath: String? }
    struct DiagnosticsParams: Decodable { var steamBuild: Int? }

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
            return try encode(SettingsResult(username: username, openAtLogin: openAtLogin, keepDebugPort: await actions.keepDebugPort(),
                                             emulators: Emulator.allCases.map { EmulatorStatus(name: $0.displayName, installed: found[$0] != nil) },
                                             updateVersion: await actions.updateVersion()))
        case "signIn":
            let p = try d.decode(SignInParams.self, from: params)
            return try encode(SignInResult(error: await actions.signIn(p.username, p.apiKey)))
        case "signOut":
            await actions.signOut()
            return Data("null".utf8)
        case "setOpenAtLogin":
            return try encode(await actions.setOpenAtLogin(try d.decode(ToggleParams.self, from: params).on))
        case "setKeepDebugPort":
            return try encode(await actions.setKeepDebugPort(try d.decode(ToggleParams.self, from: params).on))
        case "uninstall":
            await actions.uninstall()
            return Data("null".utf8)
        case "installUpdate":
            return try encode(SignInResult(error: await actions.installUpdate()))
        case "scanGames":
            return try encode(scan(try d.decode(ScanParams.self, from: params)))
        case "chooseFolder":
            return try encode(PathResult(path: await actions.chooseFolder()))
        case "addRomFolder":
            return try encode(SignInResult(error: addRomFolder(try d.decode(PathParams.self, from: params).path)))
        case "removeRomFolder":
            let path = Self.folderPath(try d.decode(PathParams.self, from: params).path)
            saveFolders(savedFolders().filter { $0 != path })
            return Data("null".utf8)
        case "playtimes":
            let p = try d.decode(PlaytimeParams.self, from: params)
            guard let s = await services() else { return try encode([Playtime]()) }
            return try encode(try await playtimes(p.shortcuts, s))
        case "unlocks":
            let p = try d.decode(UnlocksParams.self, from: params)
            guard let s = await services() else { return try encode([Unlock]()) }
            // Ten minutes back covers an unlock that reaches RA late; a minute before `since` allows for clock drift.
            let since = Date(timeIntervalSince1970: p.since - 60)
            return try encode(try await s.ra.recentUnlocks(minutes: 10).filter { $0.date >= since }.map {
                Unlock(id: $0.achievementId, title: $0.title, description: $0.description,
                       image: "\(PanelBuilder.media)/Badge/\($0.badgeName).png", date: Int($0.date.timeIntervalSince1970))
            })
        case "artwork":
            let p = try d.decode(ArtworkParams.self, from: params)
            let art = try await artwork.art(title: p.title)
            return try encode(ArtworkResult(images: art.images, iconPath: art.icon.flatMap { saveIcon($0, appid: p.appid) }))
        case "openLog":
            await actions.openLog()
            return Data("null".utf8)
        case "diagnostics":
            return try encode(await diagnostics(steamBuild: try d.decode(DiagnosticsParams.self, from: params).steamBuild))
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

    /// The whole text is scrubbed here, so the page never holds the raw log.
    private func diagnostics(steamBuild: Int?) async -> String {
        let credentials = await actions.credentials(), found = installed().emulators
        let emulators = Emulator.allCases.filter { found[$0] != nil }.map(\.displayName)
        let report = """
        Steam RetroAchievements \(UpdateChecker.currentVersion)
        OS: \(Diagnostics.operatingSystem)
        Steam build: \(steamBuild.map(String.init) ?? "unknown")
        Signed in: \(credentials == nil ? "no" : "yes")
        Emulators detected: \(emulators.isEmpty ? "none" : emulators.joined(separator: ", "))
        Steam connection: \(await actions.steamState())

        Last \(Diagnostics.logLines) log lines:
        \(Diagnostics.lastLines(of: logFile) ?? "No log file")
        """
        return Diagnostics.scrub(report, home: home, secrets: [credentials?.username, credentials?.apiKey, artwork.key].compactMap { $0 })
    }

    /// Steam reads a shortcut's icon from a file, so it has to stay on disk.
    private func saveIcon(_ data: Data, appid: UInt32) -> String? {
        guard let folder = folderFile?.deletingLastPathComponent().appendingPathComponent("icons") else { return nil }
        let file = folder.appendingPathComponent("\(appid).png")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : file.path
    }

    private static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private static func folderPath(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path }

    /// Folders that are gone (an SD card taken out) stay in the list so they work again when it's back.
    private func savedFolders() -> [String] {
        guard let data = folderFile.flatMap({ try? Data(contentsOf: $0) }) else { return [] }
        if let list = try? JSONDecoder().decode([String].self, from: data) { return list }
        let old = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return old.isEmpty ? [] : [old]
    }

    private func saveFolders(_ folders: [String]) {
        guard let folderFile else { return }
        try? FileManager.default.createDirectory(at: folderFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders).write(to: folderFile, options: .atomic)
    }

    /// nil on success, otherwise the error to show.
    private func addRomFolder(_ typed: String) -> String? {
        let path = Self.folderPath(typed)
        guard Self.isFolder(path) else { return "That isn't a folder that exists." }
        // The first folder joins the default one rather than replacing it.
        let saved = savedFolders().isEmpty ? [Scanner.defaultFolder().path] : savedFolders()
        if !saved.contains(path) { saveFolders(saved + [path]) }
        return nil
    }

    private func scan(_ p: ScanParams) -> ScanResult {
        let installed = installed()
        // Typed folders are a one-off; with nothing saved, the default folder is scanned.
        let saved = savedFolders()
        let paths = (p.folders ?? p.folder.map { [$0] } ?? (saved.isEmpty ? [Scanner.defaultFolder().path] : saved)).map(Self.folderPath)
        let folders = paths.map { FolderRow(path: $0, missing: !Self.isFolder($0)) }
        let existing = Set(p.shortcuts.compactMap { EmulatorLaunch.parse(exe: $0.exe, launchOptions: $0.launchOptions)?.romPath })
        let emulatorOverrides = Dictionary(p.emulatorOverrides.compactMap { k, v in Int(k).map { ($0, v) } }) { a, _ in a }
        let scanner = Scanner(installed: installed, hasher: hasher)
        var seen = Set<String>()
        let items = folders.filter { !$0.missing }.flatMap {
            scanner.scan(folder: URL(fileURLWithPath: $0.path), existingRomPaths: existing, consoleOverrides: p.consoleOverrides, emulatorOverrides: emulatorOverrides)
        }.filter { seen.insert($0.romPath).inserted }
        return ScanResult(folders: folders, items: items.map { item in
            let (status, text): (String, String) = switch item.status {
            case .ready: ("ready", "Ready")
            case .alreadyInSteam: ("alreadyInSteam", "Already in Steam")
            case .noEmulator(let hint): ("noEmulator", hint)
            case .chooseConsole: ("chooseConsole", "Choose a console")
            }
            let choices = item.consoleId.map(EmulatorPreference.order(for:)) ?? []
            return ScanRow(id: item.romPath, title: item.title, folder: (item.romPath as NSString).deletingLastPathComponent, status: status, statusText: text,
                           consoleId: item.consoleId, consoleName: item.consoleId.flatMap(Consoles.byID)?.name, emulator: item.emulator?.rawValue,
                           emulatorChoices: choices.filter { installed.emulators[$0] != nil }.map { Choice(id: $0.rawValue, name: $0.displayName) },
                           shortcut: item.status == .ready ? Scanner.shortcut(for: item, installed: installed) : nil)
        })
    }

    static let recentPages = 10

    /// RA's playtime and last-played time for the shortcuts whose games the user has played, for Steam's Play Time and Last Played,
    /// and every matched shortcut's achievement counts, for its library tiles.
    /// Progress is fetched only for games played since it was last saved, or never saved.
    private func playtimes(_ shortcuts: [ShortcutInfo], _ s: Services) async throws -> [Playtime] {
        var lastPlayed: [Int: Date] = [:]
        // shortcut: reads the 500 most recently played games; older ones keep Steam's own (empty) playtime
        for page in 0..<Self.recentPages {
            // A failed page fails the sync: without it, games would lose their playtime. Steam keeps what it shows until a retry.
            let games = try await s.ra.recentlyPlayed(offset: page * 50)
            // No last-played time: its playtime still counts, and any saved progress is as new as it gets.
            for g in games where lastPlayed[g.gameId] == nil { lastPlayed[g.gameId] = g.lastPlayed ?? .distantPast }
            if games.count < 50 { break }
        }
        var out: [Playtime] = []
        for shortcut in shortcuts {
            let failed = Playtime(appid: shortcut.appid, failed: true)
            let resolution: Resolution
            do { resolution = try await s.matcher.resolve(shortcut) } catch { out.append(failed); continue }
            guard case let .matched(gameId, _, _) = resolution else { continue }
            let played = lastPlayed[gameId], cached = s.ra.cachedProgress(gameId: gameId)
            // Not played lately: nothing has been unlocked since it was saved.
            var fetched = cached.flatMap { c in played.map { c.savedAt > $0 && c.value.userTotalPlaytime != nil } ?? true ? c.value : nil }
            if fetched == nil { fetched = (try? await s.ra.gameProgress(gameId: gameId)) ?? cached?.value }
            guard let progress = fetched else { out.append(failed); continue }
            let unlocked = progress.achievements.filter { $0.dateEarned != nil || $0.dateEarnedHardcore != nil }.count
            var row = Playtime(appid: shortcut.appid, unlocked: unlocked, total: progress.achievements.count)
            if let played, let seconds = progress.userTotalPlaytime {
                let twoWeeks = s.playtimeHistory.lastTwoWeeks(gameId: gameId, total: seconds, lastPlayed: played)
                row.minutes = (seconds + 59) / 60
                row.lastPlayed = max(0, Int(played.timeIntervalSince1970))
                row.twoWeeks = (twoWeeks + 59) / 60
            }
            out.append(row)
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
