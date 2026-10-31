import Foundation
import Testing
@testable import RACore

struct FakeRA: RAProviding {
    var lists: [Int: [RAGameListEntry]]
    func gameList(consoleId: Int) async throws -> [RAGameListEntry] { lists[consoleId] ?? [] }
    func gameProgress(gameId: Int) async throws -> RAGameProgress { fatalError("unused") }
}

struct FakeHasher: Fingerprinting {
    var result: HashResult
    var all: [ConsoleHash] = []
    func fingerprint(romPath: String, consoleId: Int) -> HashResult { result }
    func allFingerprints(romPath: String) -> [ConsoleHash] { all }
}

func smb(_ rom: String = "/r/nes/Super Mario Bros. (World).nes") -> ShortcutInfo {
    .init(appid: 1, name: "Super Mario Bros.", exe: raExe, launchOptions: "-L \"/c/fceumm_libretro.dylib\" \"\(rom)\"")
}

let smbEntry = RAGameListEntry(id: 1446, title: "Super Mario Bros.", consoleId: 7, consoleName: "NES/Famicom", imageIcon: "/Images/1.png", numAchievements: 30, hashes: ["abc"])

func matcher(_ result: HashResult, lists: [Int: [RAGameListEntry]] = [7: [smbEntry]], store: MatchStore = MatchStore(file: tempDir().appendingPathComponent("m.json"))) -> Matcher {
    Matcher(ra: FakeRA(lists: lists), hasher: FakeHasher(result: result), store: store)
}

@Test func notEmulator() async throws {
    let s = ShortcutInfo(appid: 2, name: "Calc", exe: "\"/System/Applications/Calculator.app\"", launchOptions: "")
    #expect(try await matcher(.hash("abc")).resolve(s) == .notEmulator)
}

@Test func emulatorWithoutRom() async throws {
    let s = ShortcutInfo(appid: 2, name: "RetroArch", exe: raExe, launchOptions: "")
    #expect(try await matcher(.hash("abc")).resolve(s) == .noRom)
}

@Test func hashMatchIsVerified() async throws {
    let store = MatchStore(file: tempDir().appendingPathComponent("m.json"))
    #expect(try await matcher(.hash("abc"), store: store).resolve(smb()) == .matched(gameId: 1446, consoleId: 7, verification: .verified))
    #expect(store.record(romPath: "/r/nes/Super Mario Bros. (World).nes")?.gameId == 1446)
}

@Test func nameMatchWithUnknownHashWarns() async throws {
    #expect(try await matcher(.hash("zzz")).resolve(smb()) == .matched(gameId: 1446, consoleId: 7, verification: .unrecognizedHash))
}

@Test func unsupportedFormatIsUnchecked() async throws {
    #expect(try await matcher(.unsupportedFormat).resolve(smb()) == .matched(gameId: 1446, consoleId: 7, verification: .unchecked))
}

@Test func blockedRomStillNameMatches() async throws {
    #expect(try await matcher(.unreadable(.blocked)).resolve(smb()) == .matched(gameId: 1446, consoleId: 7, verification: .blocked))
}

@Test func noMatchReportsConsole() async throws {
    #expect(try await matcher(.hash("zzz"), lists: [7: []]).resolve(smb()) == .notMatched(consoleId: 7, verification: .unrecognizedHash))
}

@Test func manualChoiceIsRemembered() async throws {
    let other = RAGameListEntry(id: 2000, title: "SMB Hack", consoleId: 7, consoleName: "NES/Famicom", imageIcon: "", numAchievements: 5, hashes: ["abc"])
    let store = MatchStore(file: tempDir().appendingPathComponent("m.json"))
    let m = matcher(.hash("abc"), lists: [7: [smbEntry, other]], store: store)
    #expect(try await m.choose(smb(), gameId: 2000, consoleId: 7) == .matched(gameId: 2000, consoleId: 7, verification: .verified))
    #expect(try await m.resolve(smb()) == .matched(gameId: 2000, consoleId: 7, verification: .verified))
}

@Test func prefersGameWithAchievements() async throws {
    let empty = RAGameListEntry(id: 5, title: "Super Mario Bros.", consoleId: 7, consoleName: "", imageIcon: "", numAchievements: 0, hashes: [])
    let full = RAGameListEntry(id: 9, title: "Super Mario Bros.", consoleId: 7, consoleName: "", imageIcon: "", numAchievements: 10, hashes: [])
    #expect(try await matcher(.hash("zzz"), lists: [7: [empty, full]]).resolve(smb()) == .matched(gameId: 9, consoleId: 7, verification: .unrecognizedHash))
}

@Test func searchFindsByKey() async throws {
    #expect(try await matcher(.hash("abc")).search(query: "mario bros", consoleId: 7).first == smbEntry)
}

final class CountingHasher: Fingerprinting, @unchecked Sendable {
    var allCalls = 0, oneCalls = 0
    func fingerprint(romPath: String, consoleId: Int) -> HashResult { oneCalls += 1; return .hash("abc") }
    func allFingerprints(romPath: String) -> [ConsoleHash] { allCalls += 1; return [ConsoleHash(consoleId: 7, hash: "abc")] }
}

@Test func unchangedRomIsNotRehashed() async throws {
    let rom = writeNES(tempDir(), "Super Mario Bros. (World).nes").path
    let hasher = CountingHasher()
    let m = Matcher(ra: FakeRA(lists: [7: [smbEntry]]), hasher: hasher, store: MatchStore(file: tempDir().appendingPathComponent("m.json")))
    #expect(try await m.resolve(smb(rom)) == .matched(gameId: 1446, consoleId: 7, verification: .verified))
    #expect(try await m.resolve(smb(rom)) == .matched(gameId: 1446, consoleId: 7, verification: .verified))
    #expect(hasher.allCalls + hasher.oneCalls == 1)
}
