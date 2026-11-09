import Foundation
import Testing
@testable import RACore

@Test func nesHeaderIsSkipped() {
    #expect(RomHasher().fingerprint(romPath: writeNES(tempDir()).path, consoleId: 7) == .hash(md5(payload)))
}

@Test func zipContentsAreHashed() {
    let dir = tempDir()
    writeNES(dir)
    #expect(zip("game.nes", into: "game.zip", in: dir) == 0)
    #expect(RomHasher().fingerprint(romPath: dir.appendingPathComponent("game.zip").path, consoleId: 7) == .hash(md5(payload)))
}

@Test func arcadeUsesFileName() throws {
    let url = tempDir().appendingPathComponent("sf2.zip")
    try Data([1, 2, 3]).write(to: url)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 27) == .hash(md5(Data("sf2".utf8))))
}

@Test func m3uFollowsFirstEntry() throws {
    let dir = tempDir()
    writeNES(dir)
    let m3u = dir.appendingPathComponent("game.m3u")
    try "game.nes\n".write(to: m3u, atomically: true, encoding: .utf8)
    #expect(RomHasher().fingerprint(romPath: m3u.path, consoleId: 7) == .hash(md5(payload)))
}

@Test func accentedFileNameIsHashed() {
    #expect(RomHasher().fingerprint(romPath: writeNES(tempDir(), "Pokémon Rojo.nes").path, consoleId: 7) == .hash(md5(payload)))
}

#if os(Windows)
@Test func m3uFollowsAbsoluteWindowsPath() throws {
    let rom = writeNES(tempDir(), "abs.nes")
    let m3u = tempDir().appendingPathComponent("game.m3u")
    try (rom.path.replacingOccurrences(of: "/", with: "\\") + "\n").write(to: m3u, atomically: true, encoding: .utf8)
    #expect(RomHasher().fingerprint(romPath: m3u.path, consoleId: 7) == .hash(md5(payload)))
}
#endif

// The same PS1 disc made with chdman four ways. The hash is what rcheevos gives the cue/bin of that disc.
@Test(arguments: ["ps1-cooked", "ps1-raw-audio", "ps1-pregap", "ps1-dvd"])
func chdIsHashed(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "chd"))
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 12) == .hash("3077ba9f2d82bdd8ae39217b5af4c04e"))
    #expect(RomHasher().allFingerprints(romPath: url.path) == [ConsoleHash(consoleId: 12, hash: "3077ba9f2d82bdd8ae39217b5af4c04e")])
}

@Test func corruptChdIsUnsupported() throws {
    let url = tempDir().appendingPathComponent("x.chd")
    try Data(count: 1024).write(to: url)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 12) == .unsupportedFormat)
}

@Test func missingFileIsMissing() {
    #expect(RomHasher().fingerprint(romPath: tempDir().appendingPathComponent("nope.nes").path, consoleId: 7) == .unreadable(.missing))
}

// Windows ignores POSIX permission bits, and root (as in a CI container) reads files regardless of them.
#if !os(Windows)
@Test(.enabled(if: geteuid() != 0, "root ignores file permissions"))
func unreadableFileIsBlocked() throws {
    let url = writeNES(tempDir())
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 7) == .unreadable(.blocked))
}
#endif

@Test func allFingerprintsIncludesNES() {
    let all = RomHasher().allFingerprints(romPath: writeNES(tempDir()).path)
    #expect(all.contains(ConsoleHash(consoleId: 7, hash: md5(payload))))
}
