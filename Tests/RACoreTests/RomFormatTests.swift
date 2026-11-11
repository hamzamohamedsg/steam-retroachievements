import Foundation
import Testing
@testable import RACore

// MARK: .7z. Fixtures were written by libarchive's 7z writer (bsdtar), not by anything in this repo.

// game.7z holds game.nes; multi.7z holds a folder and an empty file before sub/game.nes, then other.nes.
private func archive(_ name: String, _ ext: String = "7z") throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext))
}

@Test func sevenZipContentsHashLikeThePlainRom() throws {
    let plain = RomHasher().fingerprint(romPath: writeNES(tempDir()).path, consoleId: 7)
    #expect(plain == .hash(md5(payload)))
    #expect(RomHasher().fingerprint(romPath: try archive("game").path, consoleId: 7) == plain)
    #expect(RomHasher().allFingerprints(romPath: try archive("game").path).contains(ConsoleHash(consoleId: 7, hash: md5(payload))))
}

@Test func sevenZipSkipsFoldersAndEmptyFiles() throws {
    #expect(RomHasher().fingerprint(romPath: try archive("multi").path, consoleId: 7) == .hash(md5(payload)))
}

@Test func corruptSevenZipIsUnsupported() throws {
    let garbage = tempDir().appendingPathComponent("x.7z")
    try Data(count: 1024).write(to: garbage)
    #expect(RomHasher().fingerprint(romPath: garbage.path, consoleId: 7) == .unsupportedFormat)
    #expect(RomHasher().allFingerprints(romPath: garbage.path) == [])

    // A flipped byte in the packed data must fail the CRC check, not hash garbage.
    var flipped = try Data(contentsOf: try archive("game"))
    flipped[64] ^= 0xFF
    let damaged = tempDir().appendingPathComponent("y.7z")
    try flipped.write(to: damaged)
    #expect(RomHasher().fingerprint(romPath: damaged.path, consoleId: 7) == .unsupportedFormat)

    let truncated = tempDir().appendingPathComponent("z.7z")
    try flipped.prefix(flipped.count / 2).write(to: truncated)
    #expect(RomHasher().fingerprint(romPath: truncated.path, consoleId: 7) == .unsupportedFormat)
}

@Test func sevenZipOverTheSizeLimitIsRefused() throws {
    #expect(RomHasher.firstSevenZipEntry(try archive("game").path, limit: 1024) == nil)
    #expect(RomHasher.firstSevenZipEntry(try archive("game").path)?.1.count == payload.count + 16)
}

@Test func arcadeSevenZipUsesFileName() throws {
    let url = tempDir().appendingPathComponent("sf2.7z")
    try Data([1, 2, 3]).write(to: url)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 27) == .hash(md5(Data("sf2".utf8))))
}

// rcheevos only reads MS-DOS games from zip containers, so a 7z has no hash there.
@Test func msDosSevenZipIsUnsupported() throws {
    #expect(RomHasher().fingerprint(romPath: try archive("game").path, consoleId: 26) == .unsupportedFormat)
}

// MARK: .rvz, built by hand from Dolphin's docs/WiaAndRvz.md

private func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
private func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

private let rvzChunk = 0x8000
private let junkRange = 0x11234..<0x16234
private let junkSeed: [UInt32] = (0..<17).map { 0x1234_5678 &* UInt32($0 + 1) }

/// The padding stream as the spec describes it, walked byte by byte from the start of its 32 KiB block.
private func junk(offset: Int, count: Int) -> Data {
    var b = junkSeed + [UInt32](repeating: 0, count: 521 - 17)
    for i in 17..<521 { b[i] = (b[i - 17] << 23) ^ (b[i - 16] >> 9) ^ b[i - 1] }
    func forward() {
        for i in 0..<32 { b[i] ^= b[i + 521 - 32] }
        for i in 32..<521 { b[i] ^= b[i - 32] }
    }
    for _ in 0..<4 { forward() }
    var out = Data()
    let skip = offset % 0x8000
    for position in 0..<(skip + count) {
        if position > 0, position % (521 * 4) == 0 { forward() }
        let word = b[(position % (521 * 4)) / 4]
        if position >= skip { out.append(UInt8(truncatingIfNeeded: word >> [24, 18, 8, 0][position % 4])) }
    }
    return out
}

/// A small GameCube disc whose boot program runs through ordinary data, padding and an all-zero chunk.
private func plainDisc() -> Data {
    var d = Data((0..<(rvzChunk * 4)).map { UInt8(truncatingIfNeeded: $0 &* 7 ^ ($0 >> 8)) })
    d.replaceSubrange(0x1C..<0x20, with: [0xC2, 0x33, 0x9F, 0x3D])
    d.replaceSubrange(0x420..<0x424, with: be32(0x6000))
    d.replaceSubrange(0x2454..<0x245C, with: be32(0x100) + be32(0x40))
    d.replaceSubrange(0x6000..<0x60D8, with: Data(count: 0xD8))
    d.replaceSubrange(0x6000..<0x6004, with: be32(0x9000))
    d.replaceSubrange(0x6090..<0x6094, with: be32(0x10000))
    d.replaceSubrange(junkRange, with: junk(offset: junkRange.lowerBound, count: junkRange.count))
    d.replaceSubrange(0x18000..<0x20000, with: Data(count: rvzChunk))
    return d
}

private enum Codec: Int, CaseIterable { case none = 0, bzip2 = 2, lzma2 = 4, zstd = 5 }

private func encode(_ data: Data, _ codec: Codec) -> Data {
    switch codec {
    case .none, .bzip2: return data
    case .zstd:
        // A frame of one raw block: magic, descriptor with a 4-byte content size, block header, bytes.
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0xA0])
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { frame.append(contentsOf: $0) }
        let header = UInt32(data.count) << 3 | 1
        frame.append(contentsOf: [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)])
        return frame + data
    case .lzma2:
        // Stored chunks: control byte (1 resets the dictionary, 2 keeps it), big-endian size minus one, bytes.
        var out = Data(), offset = data.startIndex, first = true
        while offset < data.endIndex {
            let n = min(0x10000, data.endIndex - offset)
            out.append(contentsOf: [first ? 1 : 2, UInt8((n - 1) >> 8), UInt8((n - 1) & 0xFF)])
            out.append(data[offset..<(offset + n)])
            offset += n
            first = false
        }
        return out + Data([0])
    }
}

private struct Rvz {
    var codec = Codec.zstd
    var discType: UInt32 = 1
    var magic = Data("RVZ\u{1}".utf8)
}

private func buildRvz(_ o: Rvz = Rvz()) -> Data {
    let disc = plainDisc()
    let compressed: UInt32 = o.codec == .none ? 0 : 0x8000_0000
    var groups: [(Data, UInt32, UInt32)] = []  // stored bytes, data_size, rvz_packed_size

    func add(_ bytes: Data, packed: Bool = false) {
        let stored = encode(bytes, o.codec)
        groups.append((stored, compressed | UInt32(stored.count), packed ? UInt32(bytes.count) : 0))
    }
    // The first 0x80 bytes come from wia_disc_t, so whatever is stored here must not be used.
    add(Data(repeating: 0xFF, count: 0x80) + disc[0x80..<rvzChunk])
    add(disc[rvzChunk..<(rvzChunk * 2)])
    let start = rvzChunk * 2
    let before = disc[start..<junkRange.lowerBound], after = disc[junkRange.upperBound..<(rvzChunk * 3)]
    var packed = be32(UInt32(before.count)) + before
    packed += be32(0x8000_0000 | UInt32(junkRange.count))
    for word in junkSeed { packed += be32(word) }
    packed += be32(UInt32(after.count)) + after
    add(packed, packed: true)
    groups.append((Data(), 0, 0))  // data_size 0: an all-zero chunk with nothing stored

    let raw = encode(be64(0x80) + be64(UInt64(disc.count - 0x80)) + be32(0) + be32(UInt32(groups.count)), o.codec)
    let rawOffset = 0x48 + 0xDC
    func aligned(_ n: Int) -> Int { (n + 3) & ~3 }
    var dataOffset = rawOffset + raw.count
    let groupTableSize = encode(Data(count: groups.count * 12), o.codec).count
    dataOffset = aligned(dataOffset + groupTableSize)

    var table = Data(), body = Data(), position = dataOffset
    for (stored, size, packedSize) in groups {
        table += be32(UInt32(position / 4)) + be32(size) + be32(packedSize)
        body += stored + Data(count: aligned(stored.count) - stored.count)
        position += aligned(stored.count)
    }
    let groupTable = encode(table, o.codec)

    var discStruct = be32(o.discType) + be32(UInt32(o.codec.rawValue)) + be32(0) + be32(UInt32(rvzChunk))
    discStruct += disc[0..<0x80] + be32(0) + be32(0x48) + be64(0) + Data(count: 20)
    discStruct += be32(1) + be64(UInt64(rawOffset)) + be32(UInt32(raw.count))
    discStruct += be32(UInt32(groups.count)) + be64(UInt64(rawOffset + raw.count)) + be32(UInt32(groupTable.count))
    discStruct += Data([o.codec == .lzma2 ? 1 : 0, o.codec == .lzma2 ? 20 : 0]) + Data(count: 6)

    var file = o.magic + be32(0x0100_0000) + be32(0x0003_0000) + be32(UInt32(discStruct.count)) + Data(count: 20)
    file += be64(UInt64(disc.count)) + be64(UInt64(position)) + Data(count: 20)
    file += discStruct + raw + groupTable
    file += Data(count: dataOffset - file.count) + body
    return file
}

private func write(_ data: Data, as name: String) throws -> URL {
    let url = tempDir().appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func plainHash() throws -> HashResult {
    let result = RomHasher().fingerprint(romPath: try write(plainDisc(), as: "game.iso").path, consoleId: 16)
    guard case .hash = result else { Issue.record("the plain disc has no hash"); return result }
    return result
}

@Test(arguments: [Codec.none, .zstd, .lzma2])
private func rvzHashesLikeThePlainDisc(codec: Codec) throws {
    let url = try write(buildRvz(Rvz(codec: codec)), as: "game.rvz")
    let plain = try plainHash()
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 16) == plain)
    guard case .hash(let hash) = plain else { return }
    #expect(RomHasher().allFingerprints(romPath: url.path) == [ConsoleHash(consoleId: 16, hash: hash)])
}

// Encoded once with liblzma (Python's lzma module, LZMA1 raw) from this same disc layout, since there is no LZMA encoder here.
@Test func lzmaRvzHashesLikeThePlainDisc() throws {
    #expect(RomHasher().fingerprint(romPath: try archive("gc-lzma", "rvz").path, consoleId: 16) == (try plainHash()))
}

@Test func rvzIsOnlyHashedAsGameCube() throws {
    #expect(RomHasher().fingerprint(romPath: try write(buildRvz(), as: "game.rvz").path, consoleId: 7) == .unsupportedFormat)
}

// rcheevos hashes a Wii disc's encrypted bytes, which an RVZ does not store.
@Test func wiiRvzIsUnsupported() throws {
    let url = try write(buildRvz(Rvz(discType: 2)), as: "wii.rvz")
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 19) == .unsupportedFormat)
    #expect(RomHasher().fingerprint(romPath: url.path, consoleId: 16) == .unsupportedFormat)
    #expect(RomHasher().allFingerprints(romPath: url.path) == [])
}

@Test func rvzWithAnUnsupportedCompressionIsUnsupported() throws {
    #expect(RomHasher().fingerprint(romPath: try write(buildRvz(Rvz(codec: .bzip2)), as: "game.rvz").path, consoleId: 16) == .unsupportedFormat)
}

@Test func damagedRvzIsUnsupported() throws {
    let good = buildRvz()
    #expect(RomHasher().fingerprint(romPath: try write(buildRvz(Rvz(magic: Data("WIA\u{1}".utf8))), as: "a.rvz").path, consoleId: 16) == .unsupportedFormat)
    #expect(RomHasher().fingerprint(romPath: try write(good.prefix(0x60), as: "b.rvz").path, consoleId: 16) == .unsupportedFormat)
    // Cutting into the group data fails partway through hashing, after rcheevos has already started.
    #expect(RomHasher().fingerprint(romPath: try write(good.prefix(good.count - 0x4000), as: "c.rvz").path, consoleId: 16) == .unsupportedFormat)
}
