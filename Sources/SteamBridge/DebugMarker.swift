import Foundation
#if os(Windows)
import WinSDK
#endif

/// The empty file that makes Steam serve its DevTools port on 127.0.0.1.
public struct DebugMarker: Sendable {
    /// Steam's install folder: it reads the marker from there at launch.
    public static var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
        #elseif os(Windows)
        return URL(fileURLWithPath: Registry.steamPath ?? "C:\\Program Files (x86)\\Steam")
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
    let (status, data) = runProcessData(exe, args)
    return (status, String(decoding: data, as: UTF8.self))
}

#if os(Windows)
private let launchLock = NSLock()

/// Foundation's Process gives a console program (tasklist, reg, tar) a console window of its own when the parent has none,
/// as this windowless app hasn't: every Steam check flashed one. CREATE_NO_WINDOW runs it hidden.
public func runProcessData(_ exe: String, _ args: [String]) -> (status: Int32, output: Data) {
    var readEnd: HANDLE?, writeEnd: HANDLE?, pi = PROCESS_INFORMATION()
    let started: Bool = launchLock.withLock {
        // Only the child's end is inheritable, and only while it starts: another launch must not inherit it and hold the pipe open.
        guard CreatePipe(&readEnd, &writeEnd, nil, 0) else { return false }
        defer { CloseHandle(writeEnd) }
        SetHandleInformation(writeEnd, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = STARTF_USESTDHANDLES
        si.hStdOutput = writeEnd  // no stdin or stderr: these programs read nothing, and their errors aren't needed
        return windowsCommandLine([exe] + args).withCString(encodedAs: UTF16.self) {
            CreateProcessW(nil, UnsafeMutablePointer<WCHAR>(mutating: $0), nil, nil, true, DWORD(CREATE_NO_WINDOW), nil, nil, &si, &pi)
        }
    }
    defer { if let readEnd { CloseHandle(readEnd) } }
    guard started else { return (-1, Data()) }
    defer { CloseHandle(pi.hProcess); CloseHandle(pi.hThread) }
    var out = Data(), buffer = [UInt8](repeating: 0, count: 65_536), count: DWORD = 0
    while ReadFile(readEnd, &buffer, DWORD(buffer.count), &count, nil), count > 0 { out.append(contentsOf: buffer[..<Int(count)]) }
    WaitForSingleObject(pi.hProcess, WinSDK.INFINITE)
    var code: DWORD = 0
    GetExitCodeProcess(pi.hProcess, &code)
    return (Int32(bitPattern: code), out)
}
#else
public func runProcessData(_ exe: String, _ args: [String]) -> (status: Int32, output: Data) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}
#endif

/// One command line from arguments, quoted so a Windows program splits it back the same way (CommandLineToArgvW's rules).
func windowsCommandLine(_ args: [String]) -> String {
    args.map { arg in
        guard arg.isEmpty || arg.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return arg }
        var out = "\"", backslashes = 0
        for ch in arg {
            if ch == "\\" { backslashes += 1; continue }
            // Backslashes count only before a quote: doubled there, plus one to escape the quote.
            out += String(repeating: "\\", count: ch == "\"" ? backslashes * 2 + 1 : backslashes) + String(ch)
            backslashes = 0
        }
        return out + String(repeating: "\\", count: backslashes * 2) + "\""
    }.joined(separator: " ")
}
