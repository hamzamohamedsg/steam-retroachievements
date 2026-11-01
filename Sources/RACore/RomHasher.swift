import Foundation
import rcheevos

public enum Unreadable: Equatable, Sendable { case missing, blocked }
public enum HashResult: Equatable, Sendable { case hash(String), unsupportedFormat, unreadable(Unreadable) }
public struct ConsoleHash: Equatable, Sendable {
    public let consoleId: Int
    public let hash: String
    public init(consoleId: Int, hash: String) { self.consoleId = consoleId; self.hash = hash }
}

public protocol Fingerprinting: Sendable {
    func fingerprint(romPath: String, consoleId: Int) -> HashResult
    func allFingerprints(romPath: String) -> [ConsoleHash]
}

/// ROM fingerprints computed with RetroAchievements' own rcheevos library, the same code emulators use.
public struct RomHasher: Fingerprinting {
    static let unsupportedExtensions: Set<String> = ["chd", "7z"]
    static let arcade = 27, msDos = 26

    public init() {}

    public func fingerprint(romPath: String, consoleId: Int) -> HashResult {
        let romPath = Self.followPlaylist(romPath)
        if let problem = Self.precheck(romPath) { return problem }
        return withIterator(romPath: romPath, consoleId: consoleId) { it in
            var hash = [CChar](repeating: 0, count: 33)
            return rc_hash_generate(&hash, UInt32(consoleId), &it) != 0 ? .hash(Self.string(hash)) : .unsupportedFormat
        }
    }

    public func allFingerprints(romPath: String) -> [ConsoleHash] {
        let romPath = Self.followPlaylist(romPath)
        if Self.precheck(romPath) != nil { return [] }
        return withIterator(romPath: romPath, consoleId: nil) { it in
            var results: [ConsoleHash] = []
            var hash = [CChar](repeating: 0, count: 33)
            while rc_hash_iterate(&hash, &it) != 0 {
                let console = withUnsafeBytes(of: it.consoles) { Int($0[Int(it.index) - 1]) }
                results.append(ConsoleHash(consoleId: console, hash: Self.string(hash)))
            }
            return results
        }
    }

    static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// rcheevos only follows .m3u for whole-file consoles, so resolve the first entry here.
    static func followPlaylist(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "m3u",
              let text = try? String(contentsOf: url, encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return path }
        #if os(Windows)
        let entry = first.replacingOccurrences(of: "\\", with: "/")
        let absolute = entry.hasPrefix("/") || entry.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
        #else
        let entry = first, absolute = first.hasPrefix("/")
        #endif
        return absolute ? entry : url.deletingLastPathComponent().appendingPathComponent(entry).path
    }

    /// Missing, unreadable and v1-unsupported files never reach rcheevos.
    static func precheck(_ path: String) -> HashResult? {
        #if os(Windows)
        // The C runtime's open() reads the path in the ANSI code page, so a name like "Pokémon.nes" looks missing.
        guard FileManager.default.fileExists(atPath: path) else { return .unreadable(.missing) }
        guard FileManager.default.isReadableFile(atPath: path) else { return .unreadable(.blocked) }
        #else
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            return errno == ENOENT ? .unreadable(.missing) : (errno == EACCES || errno == EPERM ? .unreadable(.blocked) : .unsupportedFormat)
        }
        close(fd)
        #endif
        return unsupportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? .unsupportedFormat : nil
    }

    /// Runs `body` with an iterator over the file, or over the first file inside a zip
    /// (except arcade and MS-DOS, where rcheevos hashes the zip itself).
    private func withIterator<T>(romPath: String, consoleId: Int?, _ body: (inout rc_hash_iterator_t) -> T) -> T {
        var it = rc_hash_iterator_t()
        defer { rc_hash_destroy_iterator(&it) }
        let isZip = URL(fileURLWithPath: romPath).pathExtension.lowercased() == "zip"
        if isZip, consoleId != Self.arcade, consoleId != Self.msDos, let (name, bytes) = Self.firstZipEntry(romPath) {
            return bytes.withUnsafeBytes { buf in
                rc_hash_initialize_iterator(&it, name, buf.bindMemory(to: UInt8.self).baseAddress, buf.count)
                return body(&it)
            }
        }
        rc_hash_initialize_iterator(&it, romPath, nil, 0)
        return body(&it)
    }

    // shortcut: hashes the first file in the zip; upgrade if multi-file zips show up
    static func firstZipEntry(_ path: String) -> (String, Data)? {
        guard let list = unzip(list: path), let name = String(data: list, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.hasSuffix("/") }),
              let bytes = unzip(extract: name, from: path) else { return nil }
        return (name, bytes)
    }

    // Windows has no unzip, but its built-in tar (bsdtar) reads zip files.
    #if os(Windows)
    private static let unzipTool = "C:\\Windows\\System32\\tar.exe"
    private static func unzip(list path: String) -> Data? { run(["-tf", path]) }
    private static func unzip(extract name: String, from path: String) -> Data? { run(["-xOf", path, name]) }
    #else
    private static let unzipTool = "/usr/bin/unzip"
    private static func unzip(list path: String) -> Data? { run(["-Z1", path]) }
    private static func unzip(extract name: String, from path: String) -> Data? { run(["-p", path, name]) }
    #endif

    private static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: unzipTool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
