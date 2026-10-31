import Foundation

/// The empty file that makes Steam serve its DevTools port on 127.0.0.1.
public struct DebugMarker: Sendable {
    /// Steam's install folder: it reads the marker from there at launch.
    public static var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
        #elseif os(Windows)
        let reg = runProcess("C:\\Windows\\System32\\reg.exe", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"]).output
        let path = reg.components(separatedBy: "REG_SZ").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path.flatMap { $0.isEmpty ? nil : $0 } ?? "C:\\Program Files (x86)\\Steam")
        #else
        // ~/.steam/steam links to the native install; the Flatpak keeps its own.
        let candidates = [".steam/steam", ".local/share/Steam", ".var/app/com.valvesoftware.Steam/.local/share/Steam"].map(home.appendingPathComponent)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        #endif
    }

    public let url: URL

    public init(directory: URL = DebugMarker.defaultDirectory) {
        url = directory.appendingPathComponent(".cef-enable-remote-debugging")
    }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func ensure() throws {
        if !exists() { try Data().write(to: url) }
    }

    public func remove() throws {
        if exists() { try FileManager.default.removeItem(at: url) }
    }

    /// Falls back to the modification date where the file system keeps no creation date; the file is never written after creation.
    public var createdAt: Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] ?? attrs?[.modificationDate]) as? Date
    }
}

/// Runs a program to completion and returns its exit status and standard output; status -1 if it couldn't start.
@discardableResult
public func runProcess(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
