import Foundation
import Testing
@testable import RACore

private var fm: FileManager { .default }

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
private let downloadBase = "https://github.com/hamzamohamedsg/steam-retroachievements/releases/download/v9.0.0/"
private let apiURL = "https://api.github.com/repos/hamzamohamedsg/steam-retroachievements/releases/latest"

/// An installed copy in a temp folder, plus an archive of a newer one in the format this platform downloads.
private struct Scene {
    let folder = tempDir()
    let work = tempDir()
    var layout: UpdateLayout { UpdateLayout(folder: folder, archiveRoot: "pkg", required: ["prog", "inject.js"], program: "prog") }

    init() {
        try! Data("old prog".utf8).write(to: folder.appendingPathComponent("prog"))
        try! Data("old js".utf8).write(to: folder.appendingPathComponent("inject.js"))
        try! Data("user file".utf8).write(to: folder.appendingPathComponent("mine.txt"))
    }

    /// The installed folder's files and contents.
    var state: [String: String] {
        Dictionary(uniqueKeysWithValues: try! fm.contentsOfDirectory(atPath: folder.path).map {
            ($0, String(decoding: (try? Data(contentsOf: folder.appendingPathComponent($0))) ?? Data(), as: UTF8.self))
        })
    }
    static let old = ["prog": "old prog", "inject.js": "old js", "mine.txt": "user file"]

    /// Packs `names` (relative to `from`, by default `work`) with this platform's tool. `raw` keeps `..` and absolute names in the archive.
    func pack(_ names: [String], raw: Bool = false, from dir: URL? = nil) -> Data {
        let work = dir ?? self.work
        let archive = work.appendingPathComponent("out-\(UUID().uuidString)")
        #if os(macOS)
        let status = run("/usr/bin/zip", ["-r", "-q", "-y", archive.path + ".zip"] + names, in: work)
        let file = archive.path + ".zip"
        #elseif os(Windows)
        let status = run("C:\\Windows\\System32\\tar.exe", ["-a", raw ? "-cPf" : "-cf", archive.path + ".zip"] + names, in: work)
        let file = archive.path + ".zip"
        #else
        let status = run("/usr/bin/env", ["tar", raw ? "-czPf" : "-czf", archive.path] + names, in: work)
        let file = archive.path
        #endif
        #expect(status == 0)
        return try! Data(contentsOf: URL(fileURLWithPath: file))
    }

    func good() -> Data {
        let pkg = work.appendingPathComponent("pkg")
        try! fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        for (name, text) in [("prog", "new prog"), ("inject.js", "new js"), ("new.dll", "new dll")] {
            try! Data(text.utf8).write(to: pkg.appendingPathComponent(name))
        }
        return pack(["pkg"])
    }

    static let new = ["prog": "new prog", "inject.js": "new js", "new.dll": "new dll", "mine.txt": "user file"]
}

private func releaseJSON(_ assets: [String]?) -> Data {
    let list = assets.map { ",\"assets\":[\($0.joined(separator: ","))]" } ?? ""
    return Data(#"{"tag_name":"v9.0.0","html_url":"https://github.com/o/r/releases/tag/v9.0.0"\#(list)}"#.utf8)
}

private func asset(_ name: String = Updater.assetName, url: String? = nil, digest: String?) -> String {
    let d = digest.map { ",\"digest\":\"\($0)\"" } ?? ""
    return #"{"name":"\#(name)","browser_download_url":"\#(url ?? downloadBase + name)"\#(d)}"#
}

private func digest(_ d: Data) -> String { "sha256:" + Updater.sha256(d) }

/// Replies with `release` to the API and `archive` to everything else.
private func transport(_ release: Data, _ archive: Data) -> FakeTransport {
    FakeTransport { url in url.absoluteString == apiURL ? (release, 200) : (archive, 200) }
}

private func install(_ s: Scene, _ t: FakeTransport, current: String = "1.0",
                     check: @escaping @Sendable (URL) -> Bool = { _ in true }, relaunch: @escaping @Sendable () -> Bool = { true },
                     move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) async throws {
    try await Updater.install(current: current, layout: s.layout, transport: t, download: t, check: check, relaunch: relaunch, move: move)
}

/// The failure `install` throws, nil if it doesn't.
private func failure(_ s: Scene, _ t: FakeTransport, current: String = "1.0",
                     check: @escaping @Sendable (URL) -> Bool = { _ in true }, relaunch: @escaping @Sendable () -> Bool = { true },
                     move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) async -> UpdateFailure? {
    do { try await install(s, t, current: current, check: check, relaunch: relaunch, move: move); return nil }
    catch { return error as? UpdateFailure }
}

@Test func installsTheNewCopyAndClearsTheOldOne() async throws {
    let s = Scene(), archive = s.good()
    let stagePermissions = Locked<Int?>(nil)
    try await install(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), check: { program in
        // The staged program is complete and sits in a private folder.
        #expect(FileManager.default.fileExists(atPath: program.path))
        stagePermissions.withLock { $0 = (try? FileManager.default.attributesOfItem(atPath: program.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path))?[.posixPermissions] as? Int }
        return true
    })
    #expect(s.state == Scene.new)
    #if !os(Windows)
    #expect(stagePermissions.withLock { $0 } == 0o700)
    #endif
}

@Test func picksOnlyThisPlatformsAsset() async throws {
    let s = Scene(), archive = s.good()
    let others = ["steam-retroachievements-macos.zip", "steam-retroachievements-windows.zip", "steam-retroachievements-linux.tar.gz"]
        .filter { $0 != Updater.assetName }.map { asset($0, digest: "sha256:" + String(repeating: "0", count: 64)) }
    let t = transport(releaseJSON(others + [asset(digest: digest(archive))]), archive)
    try await install(s, t)
    #expect(t.urls.map(\.absoluteString) == [apiURL, downloadBase + Updater.assetName])
}

@Test func namesTheAssetForThisPlatform() {
    #if os(macOS)
    #expect(Updater.assetName == "steam-retroachievements-macos.zip")
    #elseif os(Windows)
    #expect(Updater.assetName == "steam-retroachievements-windows.zip")
    #else
    #expect(Updater.assetName == "steam-retroachievements-linux.tar.gz")
    #endif
}

@Test func refusesAWrongDigest() async {
    let s = Scene(), archive = s.good()
    let wrong = "sha256:" + String(repeating: "a", count: 64)
    #expect(await failure(s, transport(releaseJSON([asset(digest: wrong)]), archive)) == .badDigest)
    #expect(s.state == Scene.old)
}

@Test func refusesAMissingOrMalformedDigest() async {
    let s = Scene(), archive = s.good()
    for bad in [nil, "", "md5:abc", "sha256:", "sha256:xyz", "sha256:" + String(repeating: "g", count: 64), Updater.sha256(archive)] as [String?] {
        let t = transport(releaseJSON([asset(digest: bad)]), archive)
        #expect(await failure(s, t) == .noDigest)
        #expect(t.urls.count == 1, "nothing is downloaded without a digest")
    }
    #expect(s.state == Scene.old)
}

@Test func refusesAReleaseWithoutThisAsset() async {
    let s = Scene(), archive = s.good()
    #expect(await failure(s, transport(releaseJSON(nil), archive)) == .noAsset)
    #expect(await failure(s, transport(releaseJSON([asset("other.zip", digest: digest(archive))]), archive)) == .noAsset)
}

@Test func refusesAnAssetFromAnywhereElse() async {
    let s = Scene(), archive = s.good(), name = Updater.assetName
    for url in ["https://evil.example/\(name)", "http://github.com/hamzamohamedsg/steam-retroachievements/releases/download/v9.0.0/\(name)",
                "https://github.com/someone/else/releases/download/v9.0.0/\(name)", "https://github.com.evil.example/hamzamohamedsg/steam-retroachievements/releases/download/v9.0.0/\(name)"] {
        let t = transport(releaseJSON([asset(url: url, digest: digest(archive))]), archive)
        #expect(await failure(s, t) == .foreignHost)
        #expect(t.urls.count == 1, "the foreign URL is never fetched")
    }
    #expect(s.state == Scene.old)
}

@Test func downloadHostsAreGitHubsOnly() {
    #expect(Updater.isAllowedDownload(URL(string: "https://github.com/a")!))
    #expect(Updater.isAllowedDownload(URL(string: "https://release-assets.githubusercontent.com/a")!))
    #expect(Updater.isAllowedDownload(URL(string: "https://objects.githubusercontent.com/a")!))
    #expect(!Updater.isAllowedDownload(URL(string: "http://github.com/a")!))
    #expect(!Updater.isAllowedDownload(URL(string: "https://raw.githubusercontent.com/a")!))
    #expect(!Updater.isAllowedDownload(URL(string: "https://github.com.evil.example/a")!))
}

@Test func refusesAFailedDownload() async {
    let s = Scene(), archive = s.good()
    let t = FakeTransport { url in url.absoluteString == apiURL ? (releaseJSON([asset(digest: digest(archive))]), 200) : (Data(), 404) }
    #expect(await failure(s, t) == .download)
    #expect(s.state == Scene.old)
}

@Test func doesNothingWhenTheReleaseIsNotNewer() async {
    let s = Scene(), archive = s.good()
    let t = transport(releaseJSON([asset(digest: digest(archive))]), archive)
    #expect(await failure(s, t, current: "9.0.0") == .noRelease)
    #expect(t.urls.count == 1)
    #expect(s.state == Scene.old)
}

@Test func anUnwritableFolderIsReportedBeforeDownloading() async {
    let s = Scene(), archive = s.good()
    let t = transport(releaseJSON([asset(digest: digest(archive))]), archive)
    let missing = UpdateLayout(folder: s.folder.appendingPathComponent("not/there"), archiveRoot: "pkg", required: ["prog"], program: "prog")
    await #expect(throws: UpdateFailure.notWritable) {
        try await Updater.install(current: "1.0", layout: missing, transport: t, download: t, check: { _ in true }, relaunch: { true })
    }
    #expect(t.urls.count == 1)
}

@Test func entryNamesThatEscapeAreRefused() {
    for good in ["a", "a/b.txt", "a/", "./a/b", "Steam RetroAchievements.app/Contents/Info.plist", "a/..b/c..", "win\\sub\\x.dll"] {
        #expect(Updater.isSafeEntry(good), "\(good)")
    }
    for bad in ["../a", "a/../../b", "..", "/etc/passwd", "\\\\server\\share\\x", "\\x", "..\\x", "a\\..\\..\\b", "C:\\x", "C:x", "a:stream"] {
        #expect(!Updater.isSafeEntry(bad), "\(bad)")
    }
}

@Test func onlyPlainFilesAndFoldersPassTheListing() {
    #expect(Updater.isPlainListing("drwxr-xr-x 0 a b 0 Nov 1 d/\n-rw-r--r-- 0 a b 1 Nov 1 d/f\n"))
    #expect(!Updater.isPlainListing("-rw-r--r-- 0 a b 1 Nov 1 f\nlrwxr-xr-x 0 a b 0 Nov 1 l -> /etc\n"))
    #expect(!Updater.isPlainListing("hrw-r--r-- 0 a b 0 Nov 1 h link to /etc/passwd\n"))
    #expect(!Updater.isPlainListing(""))
}

@Test func anArchiveThatEscapesIsRefused() async throws {
    let s = Scene()
    try Data("evil".utf8).write(to: s.work.appendingPathComponent("evil"))
    let inner = s.work.appendingPathComponent("inner")
    try fm.createDirectory(at: inner, withIntermediateDirectories: true)
    let archive = s.pack(["../evil"], raw: true, from: inner)
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive)) == .unsafeArchive)
    #expect(s.state == Scene.old)
    #expect(!fm.fileExists(atPath: s.folder.deletingLastPathComponent().appendingPathComponent("evil").path))
}

#if !os(Windows)  // making a symlink on Windows needs a privilege CI doesn't have
@Test func anArchiveWithASymlinkIsRefused() async throws {
    let s = Scene()
    _ = s.good()
    try fm.createSymbolicLink(atPath: s.work.appendingPathComponent("pkg/link").path, withDestinationPath: "/etc")
    let archive = s.pack(["pkg"])
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive)) == .unsafeArchive)
    #expect(s.state == Scene.old)
}
#endif

@Test func anIncompleteCopyIsRefused() async throws {
    let s = Scene()
    let pkg = s.work.appendingPathComponent("pkg")
    try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
    try Data("new prog".utf8).write(to: pkg.appendingPathComponent("prog"))  // no inject.js
    let archive = s.pack(["pkg"])
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive)) == .incomplete)
    #expect(s.state == Scene.old)
}

@Test func aCorruptArchiveIsRefused() async {
    let s = Scene(), junk = Data("not an archive".utf8)
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(junk))]), junk)) == .unsafeArchive)
    #expect(s.state == Scene.old)
}

@Test func aCopyThatDoesNotRunIsRefused() async {
    let s = Scene(), archive = s.good()
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), check: { _ in false }) == .doesNotRun)
    #expect(s.state == Scene.old)
}

/// Fails the `index`th rename and, with `andAfter`, every one after it.
private func failingMove(at index: Int, andAfter: Bool = false) -> @Sendable (URL, URL) throws -> Void {
    let count = Locked(0)
    return { from, to in
        let n = count.withLock { c -> Int in defer { c += 1 }; return c }
        if n == index || (andAfter && n > index) { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: from, to: to)
    }
}

@Test func aFailureAtAnyRenameLeavesTheOldCopy() async {
    // inject.js aside, inject.js in, new.dll in, prog aside, prog in.
    for index in 0..<5 {
        let s = Scene(), archive = s.good()
        #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), move: failingMove(at: index)) == .swap, "rename \(index)")
        #expect(s.state == Scene.old, "rename \(index)")
    }
}

@Test func swapsAWholeBundleFromTheArchiveTop() async throws {
    // The macOS shape: the archive's top level is the .app, swapped as one folder.
    let s = Scene()
    let old = s.folder.appendingPathComponent("My.app/Contents"), new = s.work.appendingPathComponent("My.app/Contents")
    for dir in [old, new] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    try Data("old".utf8).write(to: old.appendingPathComponent("x"))
    try Data("new".utf8).write(to: new.appendingPathComponent("x"))
    try Data("gone next time".utf8).write(to: old.appendingPathComponent("only-old"))
    let archive = s.pack(["My.app"]), layout = UpdateLayout(folder: s.folder, archiveRoot: "", required: ["My.app/Contents/x"], program: "My.app/Contents/x")
    let t = transport(releaseJSON([asset(digest: digest(archive))]), archive)
    await #expect(throws: UpdateFailure.relaunch) {
        try await Updater.install(current: "1.0", layout: layout, transport: t, download: t, check: { _ in true }, relaunch: { false })
    }
    #expect(try String(contentsOf: old.appendingPathComponent("x"), encoding: .utf8) == "old")
    try await Updater.install(current: "1.0", layout: layout, transport: t, download: t, check: { _ in true }, relaunch: { true })
    #expect(try String(contentsOf: old.appendingPathComponent("x"), encoding: .utf8) == "new")
    #expect(!fm.fileExists(atPath: old.appendingPathComponent("only-old").path))
    #expect(!s.state.keys.contains { $0.contains(".sra-") })
}

@Test func theProgramIsSwappedLast() async throws {
    let s = Scene(), archive = s.good()
    let order = Locked<[String]>([])
    try await install(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), move: { from, to in
        order.withLock { $0.append(to.lastPathComponent) }
        try FileManager.default.moveItem(at: from, to: to)
    })
    #expect(order.withLock { $0 }.last == "prog")
}

@Test func aFailedRelaunchPutsTheOldCopyBack() async {
    let s = Scene(), archive = s.good()
    #expect(await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), relaunch: { false }) == .relaunch)
    #expect(s.state == Scene.old)
}

@Test func aFailedRollbackKeepsTheOldFiles() async {
    let s = Scene(), archive = s.good()
    // Fails moving new.dll in, then every undo, so inject.js stays new with its old copy aside.
    let result = await failure(s, transport(releaseJSON([asset(digest: digest(archive))]), archive), move: failingMove(at: 2, andAfter: true))
    #expect(result == .rollback)
    let state = s.state
    #expect(state.first { $0.key.hasPrefix("inject.js.sra-old-") }?.value == "old js")
}

@Test func leftoversGoOnlyWhenTheFileTheyReplacedIsThere() throws {
    let folder = tempDir()
    for name in ["prog", "prog.sra-old-1", "lost.dll.sra-old-1", "keep.txt"] { try Data().write(to: folder.appendingPathComponent(name)) }
    try fm.createDirectory(at: folder.appendingPathComponent(".sra-update-1"), withIntermediateDirectories: true)
    Updater.removeLeftovers(in: folder)
    #expect(Set(try fm.contentsOfDirectory(atPath: folder.path)) == ["prog", "lost.dll.sra-old-1", "keep.txt"])
}

@Test func sha256MatchesPublishedVectors() {
    #expect(Updater.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(Updater.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(Updater.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(Updater.sha256(Data(repeating: 0x61, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test func layoutRefusesAnythingButAReleasedCopy() {
    #if os(macOS)
    let app = URL(fileURLWithPath: "/Users/a/Applications/Steam RetroAchievements.app")
    let layout = Updater.layout(executable: app.path + "/Contents/MacOS/SteamRetroAchievements", app: app)
    #expect(layout?.folder.path == "/Users/a/Applications")
    #expect(layout?.required.contains("Steam RetroAchievements.app/Contents/Resources/inject.js") == true)
    #expect(layout?.program == "Steam RetroAchievements.app/Contents/MacOS/SteamRetroAchievements")
    // A dev build, a renamed copy and a translocated (quarantined, run in place) copy.
    #expect(Updater.layout(executable: "/x/.build/debug/SteamRetroAchievements", app: URL(fileURLWithPath: "/x/.build/debug")) == nil)
    #expect(Updater.layout(executable: "", app: URL(fileURLWithPath: "/Applications/Other.app")) == nil)
    let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Steam RetroAchievements.app")
    #expect(Updater.layout(executable: "", app: translocated) == nil)
    #elseif os(Windows)
    #expect(Updater.layout(executable: "C:\\Games\\SRA\\SteamRetroAchievements.exe", app: nil)?.required.contains("inject.js") == true)
    #expect(Updater.layout(executable: "C:\\x\\.build\\debug\\Other.exe", app: nil) == nil)
    #else
    #expect(Updater.layout(executable: "/home/deck/sra/steam-retroachievements", app: nil)?.folder.path == "/home/deck/sra")
    #expect(Updater.layout(executable: "/home/deck/sra/steam-retroachievements", app: nil)?.required.contains("icon.png") == true)
    #expect(Updater.layout(executable: "/x/.build/debug/SteamRetroAchievements", app: nil) == nil)
    #endif
}

@Test func theBridgeOffersAndStartsTheUpdate() async throws {
    let started = Locked(0)
    let handler = BridgeHandler(services: { nil }, actions: BridgeActions(updateVersion: { "9.0.0" }, installUpdate: {
        started.withLock { $0 += 1 }
        return "Couldn't install it."
    }), push: { _ in }, installed: { Installed(emulators: [:], coresDirectory: tempDir()) })
    let settings = try JSONSerialization.jsonObject(with: try await handler.handle(method: "settings", params: Data("{}".utf8))) as? [String: Any]
    #expect(settings?["updateVersion"] as? String == "9.0.0")
    // The page passes no parameters: it can't choose what gets installed.
    let reply = try JSONSerialization.jsonObject(with: try await handler.handle(method: "installUpdate", params: Data("{}".utf8))) as? [String: Any]
    #expect(reply?["error"] as? String == "Couldn't install it.")
    #expect(started.withLock { $0 } == 1)
}
