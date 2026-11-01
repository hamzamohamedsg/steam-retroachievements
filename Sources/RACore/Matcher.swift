import Foundation

public struct ShortcutInfo: Codable, Equatable, Sendable {
    public var appid: UInt32
    public var name: String
    public var exe: String
    public var launchOptions: String

    public init(appid: UInt32, name: String, exe: String, launchOptions: String) {
        self.appid = appid; self.name = name; self.exe = exe; self.launchOptions = launchOptions
    }
}

public enum Verification: String, Codable, Sendable { case verified, unrecognizedHash, unchecked, blocked, missing }

public enum Resolution: Equatable, Sendable {
    case notEmulator, noRom
    case matched(gameId: Int, consoleId: Int, verification: Verification)
    case notMatched(consoleId: Int?, verification: Verification)
}

/// Finds a shortcut's RetroAchievements game: remembered link, then fingerprint, then name (spec "Matching").
public actor Matcher {
    let ra: RAProviding
    let hasher: Fingerprinting
    let store: MatchStore

    public init(ra: RAProviding, hasher: Fingerprinting, store: MatchStore) {
        self.ra = ra; self.hasher = hasher; self.store = store
    }

    struct RomState { var hash: String?; var base: Verification; var consoles: [Int]; var size: Int64; var modified: Double }

    public func resolve(_ s: ShortcutInfo) async throws -> Resolution {
        guard let launch = EmulatorLaunch.parse(exe: s.exe, launchOptions: s.launchOptions) else { return .notEmulator }
        guard let rom = launch.romPath else { return .noRom }
        let state = romState(rom, launch)

        if let record = store.record(romPath: rom) {
            if record.hash != state.hash || record.size != state.size || record.modified != state.modified {
                var updated = record
                updated.hash = state.hash; updated.size = state.size; updated.modified = state.modified
                store.save(romPath: rom, updated)
            }
            return .matched(gameId: record.gameId, consoleId: record.consoleId,
                            verification: try await verification(state, gameId: record.gameId, consoleId: record.consoleId))
        }

        if let hash = state.hash {
            for console in state.consoles {
                if let entry = try await ra.gameList(consoleId: console).first(where: { $0.hashes.contains(hash) }) {
                    save(rom, entry.id, console, manual: false, state)
                    return .matched(gameId: entry.id, consoleId: console, verification: .verified)
                }
            }
        }

        let keys = Set([Titles.key(Titles.clean(rom)), Titles.key(Titles.clean(s.name))].filter { !$0.isEmpty })
        for console in state.consoles {
            let hits = try await ra.gameList(consoleId: console).filter { keys.contains(Titles.key($0.title)) && Titles.subsetName($0.title) == nil }
            if let best = hits.min(by: { ($0.numAchievements == 0 ? 1 : 0, $0.id) < ($1.numAchievements == 0 ? 1 : 0, $1.id) }) {
                save(rom, best.id, console, manual: false, state)
                return .matched(gameId: best.id, consoleId: console, verification: state.base)
            }
        }
        return .notMatched(consoleId: state.consoles.first, verification: state.base)
    }

    public func choose(_ s: ShortcutInfo, gameId: Int, consoleId: Int) async throws -> Resolution {
        guard let launch = EmulatorLaunch.parse(exe: s.exe, launchOptions: s.launchOptions) else { return .notEmulator }
        guard let rom = launch.romPath else { return .noRom }
        let state = romState(rom, launch)
        save(rom, gameId, consoleId, manual: true, state)
        return .matched(gameId: gameId, consoleId: consoleId, verification: try await verification(state, gameId: gameId, consoleId: consoleId))
    }

    public func search(query: String, consoleId: Int) async throws -> [RAGameListEntry] {
        let key = Titles.key(query)
        return Array(try await ra.gameList(consoleId: consoleId)
            .filter { key.isEmpty || Titles.key($0.title).contains(key) }
            .sorted { ($0.numAchievements == 0 ? 1 : 0, $0.title) < ($1.numAchievements == 0 ? 1 : 0, $1.title) }
            .prefix(50))
    }

    /// The game and its subsets (same title with a `[Subset - Name]` tag), base first. Empty when there are no subsets.
    public func sets(gameId: Int, consoleId: Int) async throws -> [PanelPayload.SetRef] {
        let list = try await ra.gameList(consoleId: consoleId)
        guard let base = list.first(where: { $0.id == gameId }), Titles.subsetName(base.title) == nil else { return [] }
        let key = Titles.key(base.title)
        let subsets = list.compactMap { e in
            Titles.subsetName(e.title).flatMap { Titles.key(e.title) == key ? PanelPayload.SetRef(id: e.id, name: $0) : nil }
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        return subsets.isEmpty ? [] : [.init(id: gameId, name: "Base Set")] + subsets
    }

    /// Hash, base verification and candidate consoles; the stored hash is reused while the file is unchanged.
    private func romState(_ rom: String, _ launch: EmulatorLaunch) -> RomState {
        let attrs = try? FileManager.default.attributesOfItem(atPath: rom)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // Unchanged file with a stored fingerprint: skip hashing, disc images are slow to read.
        if let r = store.record(romPath: rom), r.size == size, r.modified == modified, attrs != nil, let h = r.hash {
            return RomState(hash: h, base: .unrecognizedHash, consoles: [r.consoleId], size: size, modified: modified)
        }
        let fps = hasher.allFingerprints(romPath: rom)
        let consoles = Consoles.candidates(emulator: launch.emulator, coreFile: launch.coreFile, fingerprints: fps)
        let result: HashResult = consoles.first.map { c in fps.first { $0.consoleId == c }.map { .hash($0.hash) } ?? hasher.fingerprint(romPath: rom, consoleId: c) }
            ?? hasher.fingerprint(romPath: rom, consoleId: 0)
        switch result {
        case .hash(let h): return RomState(hash: h, base: .unrecognizedHash, consoles: consoles, size: size, modified: modified)
        case .unsupportedFormat: return RomState(hash: nil, base: .unchecked, consoles: consoles, size: size, modified: modified)
        case .unreadable(.missing): return RomState(hash: nil, base: .missing, consoles: consoles, size: size, modified: modified)
        case .unreadable(.blocked): return RomState(hash: nil, base: .blocked, consoles: consoles, size: size, modified: modified)
        }
    }

    private func verification(_ state: RomState, gameId: Int, consoleId: Int) async throws -> Verification {
        guard let hash = state.hash else { return state.base }
        let hashes = try await ra.gameList(consoleId: consoleId).first { $0.id == gameId }?.hashes ?? []
        return hashes.contains(hash) ? .verified : .unrecognizedHash
    }

    private func save(_ rom: String, _ gameId: Int, _ consoleId: Int, manual: Bool, _ state: RomState) {
        store.save(romPath: rom, MatchRecord(gameId: gameId, consoleId: consoleId, manual: manual, hash: state.hash, size: state.size, modified: state.modified))
    }
}
