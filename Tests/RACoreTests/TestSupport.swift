import CryptoKit
import Foundation

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sra-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func md5(_ d: Data) -> String {
    Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

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
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
