import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SteamBridge

/// Why an update didn't install. The old copy is still in place after each of these (`rollback` is the one that may
/// need a hand: the old files are then beside their new ones, named `*.sra-old-*`); the app opens the release page instead.
public enum UpdateFailure: Error, Equatable {
    case noRelease, noAsset, noDigest, foreignHost, notWritable, download, badDigest, unsafeArchive, incomplete, doesNotRun, swap, relaunch, rollback
}

/// Where this copy lives and what a release must contain to replace it.
public struct UpdateLayout: Sendable {
    /// Holds the installed copy: the .app's parent on macOS, the program's own folder elsewhere.
    public var folder: URL
    /// The folder in the archive whose contents land in `folder`; "" for the archive's top level.
    public var archiveRoot: String
    /// Paths relative to `archiveRoot` that must all be there.
    public var required: [String]
    /// Relative to `archiveRoot`: what is run to try the new copy. Its top-level entry is swapped last.
    public var program: String

    public init(folder: URL, archiveRoot: String, required: [String], program: String) {
        self.folder = folder; self.archiveRoot = archiveRoot; self.required = required; self.program = program
    }
}

/// Follows redirects only to GitHub's release hosts, and allows the time a 25 MB download takes on a slow connection.
public struct ReleaseDownload: HTTPTransport {
    final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {  // the session calls it serially
        let done: CheckedContinuation<(Data, Int), Error>
        var body = Data()
        init(_ done: CheckedContinuation<(Data, Int), Error>) { self.done = done }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { body.append(data) }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { done.resume(throwing: error) } else { done.resume(returning: (body, (task.response as? HTTPURLResponse)?.statusCode ?? 0)) }
        }

        // Refusing ends the transfer with the redirect's own status, which isn't 200, so the download is rejected.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(Updater.isAllowedDownload) == true ? request : nil)
        }
    }

    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1800
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.setValue("steam-retroachievements/0.1", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await withCheckedThrowingContinuation { done in
            let session = URLSession(configuration: config, delegate: Collector(done), delegateQueue: nil)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }
}

/// Replaces the installed copy with the latest release. Everything up to the swap happens in a private folder beside
/// the installed copy (same volume, so the swap is renames only), and the swap undoes itself on any failure.
public enum Updater {
    #if os(macOS)
    public static let assetName = "steam-retroachievements-macos.zip"
    static let appName = "Steam RetroAchievements.app"
    #elseif os(Windows)
    public static let assetName = "steam-retroachievements-windows.zip"
    #else
    public static let assetName = "steam-retroachievements-linux.tar.gz"
    #endif

    /// nil when this isn't a released copy in place: a development build, a renamed app, or a macOS translocated copy.
    public static func layout(executable: String, app: URL?) -> UpdateLayout? {
        #if os(macOS)
        guard let app, app.lastPathComponent == appName, !app.path.contains("/AppTranslocation/") else { return nil }
        let contents = "\(appName)/Contents", program = "\(contents)/MacOS/SteamRetroAchievements"
        return UpdateLayout(folder: app.deletingLastPathComponent(), archiveRoot: "",
                            required: ["\(contents)/Info.plist", "\(contents)/Resources/inject.js", program], program: program)
        #elseif os(Windows)
        let exe = URL(fileURLWithPath: executable), name = "SteamRetroAchievements.exe"
        guard exe.lastPathComponent.lowercased() == name.lowercased() else { return nil }
        return UpdateLayout(folder: exe.deletingLastPathComponent(), archiveRoot: "steam-retroachievements-windows", required: [name, "inject.js"], program: name)
        #else
        let exe = URL(fileURLWithPath: executable), name = "steam-retroachievements"
        guard exe.lastPathComponent == name else { return nil }
        return UpdateLayout(folder: exe.deletingLastPathComponent(), archiveRoot: "steam-retroachievements-linux", required: [name, "inject.js", "icon.png"], program: name)
        #endif
    }

    /// `check` tries the staged program before anything is replaced; `relaunch` starts the new copy once it's in place,
    /// and false puts the old copy back. Returns with the new copy started and this one still running.
    public static func install(current: String = UpdateChecker.currentVersion, layout: UpdateLayout,
                               transport: HTTPTransport = URLSessionTransport(), download: HTTPTransport = ReleaseDownload(),
                               check: @Sendable (URL) -> Bool, relaunch: @Sendable () -> Bool,
                               move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) async throws {
        guard let release = await UpdateChecker.latest(transport: transport), UpdateChecker.isNewer(release.tag_name, than: current) else { throw UpdateFailure.noRelease }
        guard let asset = release.assets?.first(where: { $0.name == assetName }) else { throw UpdateFailure.noAsset }
        guard let expected = expectedHash(asset.digest) else { throw UpdateFailure.noDigest }
        guard let url = asset.browser_download_url.flatMap(URL.init(string:)), isReleaseAsset(url) else { throw UpdateFailure.foreignHost }

        let fm = FileManager.default
        let stage = layout.folder.appendingPathComponent(".sra-update-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: privateFolder)) != nil else { throw UpdateFailure.notWritable }
        defer { try? fm.removeItem(at: stage) }

        guard let (data, status) = try? await download.get(url), status == 200 else { throw UpdateFailure.download }
        guard sha256(data) == expected else { throw UpdateFailure.badDigest }

        let archive = stage.appendingPathComponent(assetName), unpacked = stage.appendingPathComponent("new")
        guard (try? data.write(to: archive)) != nil,
              (try? fm.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: privateFolder)) != nil else { throw UpdateFailure.notWritable }
        guard archiveIsSafe(archive), extract(archive, to: unpacked), !containsSymlink(unpacked) else { throw UpdateFailure.unsafeArchive }

        let root = layout.archiveRoot.isEmpty ? unpacked : unpacked.appendingPathComponent(layout.archiveRoot)
        guard layout.required.allSatisfy({ fm.fileExists(atPath: root.appendingPathComponent($0).path) }) else { throw UpdateFailure.incomplete }
        guard check(root.appendingPathComponent(layout.program)) else { throw UpdateFailure.doesNotRun }

        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        let top = String(layout.program.split(separator: "/")[0])
        let id = UUID().uuidString
        var done: [(from: URL, to: URL)] = []  // every rename made, in order: undoing is the same list backwards
        do {
            // The program last: if the machine dies part-way, the copy that starts is still the old program.
            for name in names.filter({ $0 != top }) + names.filter({ $0 == top }) {
                let new = root.appendingPathComponent(name), target = layout.folder.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    let aside = layout.folder.appendingPathComponent("\(name).sra-old-\(id)")
                    try move(target, aside)
                    done.append((target, aside))
                }
                try move(new, target)
                done.append((new, target))
            }
        } catch {
            try undo(done, move: move)
            throw UpdateFailure.swap
        }

        guard relaunch() else {
            try undo(done, move: move)
            throw UpdateFailure.relaunch
        }
        // On Windows the running program's files refuse this; removeLeftovers gets them on the next start.
        for step in done where step.to.lastPathComponent.contains(".sra-old-") { try? fm.removeItem(at: step.to) }
    }

    private static func undo(_ done: [(from: URL, to: URL)], move: (URL, URL) throws -> Void) throws {
        var failed = false
        for step in done.reversed() {
            do { try move(step.to, step.from) } catch { failed = true }
        }
        if failed { throw UpdateFailure.rollback }
    }

    /// Clears what an update left in `folder`. An old file goes only if the one it stood aside for is there: after a
    /// failed rollback it can be the only copy left.
    public static func removeLeftovers(in folder: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            if name.hasPrefix(".sra-update-") {
                try? fm.removeItem(at: url)
            } else if let mark = name.range(of: ".sra-old-"), fm.fileExists(atPath: folder.appendingPathComponent(String(name[..<mark.lowerBound])).path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Trust checks

    #if os(Windows)
    private static var privateFolder: [FileAttributeKey: Any]? { nil }  // inherits the install folder's access rights
    #else
    private static var privateFolder: [FileAttributeKey: Any]? { [.posixPermissions: 0o700] }
    #endif

    static func isAllowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }

    private static func isReleaseAsset(_ url: URL) -> Bool {
        isAllowedDownload(url) && url.host == "github.com" && url.path.hasPrefix("/hamzamohamedsg/steam-retroachievements/releases/download/")
    }

    /// The hex from GitHub's `sha256:<hex>`; nil for anything else, which counts as no digest.
    private static func expectedHash(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex.lowercased() : nil
    }

    /// Backslashes count as separators and colons are refused because Windows' tar acts on them (`..\x`, `C:\x`, `a:stream`).
    static func isSafeEntry(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains(":") else { return false }
        return !name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    /// `tar -tv` starts each line with the entry's type: only plain files and folders, so nothing can be written through a link.
    static func isPlainListing(_ listing: String) -> Bool {
        let lines = listing.split(whereSeparator: \.isNewline)
        return !lines.isEmpty && lines.allSatisfy { $0.first == "-" || $0.first == "d" }
    }

    // Windows has no unzip, but its built-in tar (bsdtar) reads zip files, as macOS's does.
    private static func tar(_ args: [String]) -> (status: Int32, output: Data) {
        #if os(Windows)
        runProcessData("C:\\Windows\\System32\\tar.exe", args)
        #elseif os(macOS)
        runProcessData("/usr/bin/tar", args)
        #else
        runProcessData("/usr/bin/env", ["tar"] + args)
        #endif
    }

    private static func archiveIsSafe(_ archive: URL) -> Bool {
        let names = tar(["-tf", archive.path]), kinds = tar(["-tvf", archive.path])
        guard names.status == 0, kinds.status == 0 else { return false }
        let entries = String(decoding: names.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        return !entries.isEmpty && entries.allSatisfy { isSafeEntry(String($0)) } && isPlainListing(String(decoding: kinds.output, as: UTF8.self))
    }

    private static func extract(_ archive: URL, to folder: URL) -> Bool {
        #if os(macOS)
        // ditto made this zip: it stores extended attributes as ._ files that only ditto folds back. Left in the bundle they'd break its signature.
        runProcessData("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]).status == 0
        #else
        tar(["-xf", archive.path, "-C", folder.path]).status == 0
        #endif
    }

    /// The listing already refused these; this catches a tar whose listing looks different from the ones known here.
    private static func containsSymlink(_ folder: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return true }
        for case let url as URL in items where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
        return false
    }

    /// FIPS 180-4. CryptoKit isn't on Windows or Linux, and this is the only hash the update needs.
    static func sha256(_ data: Data) -> String {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        message.append(0x80)
        message.append(contentsOf: [UInt8](repeating: 0, count: (120 - message.count % 64) % 64))
        withUnsafeBytes(of: UInt64(data.count * 8).bigEndian) { message.append(contentsOf: $0) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                w[i] = UInt32(message[chunk + i * 4]) << 24 | UInt32(message[chunk + i * 4 + 1]) << 16 | UInt32(message[chunk + i * 4 + 2]) << 8 | UInt32(message[chunk + i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let t1 = v[7] &+ (rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)) &+ ((v[4] & v[5]) ^ (~v[4] & v[6])) &+ k[i] &+ w[i]
                let t2 = (rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)) &+ ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]))
                v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] = h[i] &+ v[i] }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
