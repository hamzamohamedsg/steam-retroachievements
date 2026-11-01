#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sra-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

#if canImport(CryptoKit)
func md5(_ d: Data) -> String {
    Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
}
#else
// RFC 1321, for platforms without CryptoKit.
func md5(_ d: Data) -> String {
    let s: [UInt32] = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]
    let k = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
    var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
    var msg = [UInt8](d)
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    withUnsafeBytes(of: UInt64(d.count * 8).littleEndian) { msg.append(contentsOf: $0) }
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        let m = (0..<16).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(msg[chunk + i * 4 + $1]) << UInt32(8 * $1) } }
        var a = a0, b = b0, c = c0, dd = d0
        for i in 0..<64 {
            var f: UInt32, g: Int
            switch i / 16 {
            case 0: f = (b & c) | (~b & dd); g = i
            case 1: f = (dd & b) | (~dd & c); g = (5 * i + 1) % 16
            case 2: f = b ^ c ^ dd; g = (3 * i + 5) % 16
            default: f = c ^ (b | ~dd); g = (7 * i) % 16
            }
            f = f &+ a &+ k[i] &+ m[g]
            a = dd; dd = c; c = b
            let sh = s[(i / 16) * 4 + i % 4]
            b = b &+ ((f << sh) | (f >> (32 - sh)))
        }
        a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ dd
    }
    return [a0, b0, c0, d0].map { v in (0..<4).map { String(format: "%02x", (v >> UInt32(8 * $0)) & 0xff) }.joined() }.joined()
}
#endif

let payload = Data((0..<32768).map { UInt8($0 % 251) })

@discardableResult
func writeNES(_ dir: URL, _ name: String = "game.nes") -> URL {
    let url = dir.appendingPathComponent(name)
    var data = Data("NES\u{1A}".utf8)
    data.append(Data(count: 12))
    data.append(payload)
    try! data.write(to: url)
    return url
}

@discardableResult
func run(_ tool: String, _ args: [String], in dir: URL) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = dir
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Zips `file` into `archive` inside `dir`; Windows has no zip, but its tar writes zip files.
@discardableResult
func zip(_ file: String, into archive: String, in dir: URL) -> Int32 {
    #if os(Windows)
    run("C:\\Windows\\System32\\tar.exe", ["-a", "-c", "-f", archive, file], in: dir)
    #else
    run("/usr/bin/zip", ["-j", "-q", archive, file], in: dir)
    #endif
}
