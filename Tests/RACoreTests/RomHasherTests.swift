import Foundation
import Testing
@testable import RACore

@Test func nesHeaderIsSkipped() {
    #expect(RomHasher().fingerprint(romPath: writeNES(tempDir()).path, consoleId: 7) == .hash(md5(payload)))
}

@Test func zipContentsAreHashed() {
    let dir = tempDir()
    writeNES(dir)
    run("/usr/bin/zip", ["-j", "-q", "game.zip", "game.nes"], in: dir)
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

@Test func chdIsUnsupported() throws {
    let url = tempDir().appendingPathComponent("x.chd")
    try Data(count: 1024).write(to: url)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 12) == .unsupportedFormat)
}

@Test func missingFileIsMissing() {
    #expect(RomHasher().fingerprint(romPath: tempDir().appendingPathComponent("nope.nes").path, consoleId: 7) == .unreadable(.missing))
}

@Test func unreadableFileIsBlocked() throws {
    let url = writeNES(tempDir())
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 7) == .unreadable(.blocked))
}

@Test func allFingerprintsIncludesNES() {
    let all = RomHasher().allFingerprints(romPath: writeNES(tempDir()).path)
    #expect(all.contains(ConsoleHash(consoleId: 7, hash: md5(payload))))
}
