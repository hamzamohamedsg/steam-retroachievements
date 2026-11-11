import Foundation
import Testing
@testable import RACore

private let fake = RACredentials(username: "FakeUser", apiKey: "FAKEKEY123")
private let home = "/Users/fakeperson"

private func handler(log: String?, credentials: RACredentials? = fake, opened: Counter = Counter()) throws -> BridgeHandler {
    var file: URL?
    if let log {
        file = tempDir().appendingPathComponent("app.log")
        try log.write(to: file!, atomically: true, encoding: .utf8)
    }
    let missing = tempDir().appendingPathComponent("never-written.log")
    let installed = Installed(emulators: [.duckstation: Launcher(exe: "\(home)/Apps/DuckStation")], coresDirectory: tempDir())
    return BridgeHandler(services: { nil },
                         actions: BridgeActions(openLog: { opened.add() }, credentials: { credentials }, steamState: { "connected" }),
                         push: { _ in }, installed: { installed }, artwork: SteamGridDB(key: "FAKESGDBKEY", transport: FakeTransport { _ in (Data(), 500) }),
                         logFile: file ?? missing, home: home)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

private func diagnostics(_ h: BridgeHandler, _ params: String = "{}") async throws -> String {
    try JSONDecoder().decode(String.self, from: try await h.handle(method: "diagnostics", params: Data(params.utf8)))
}

@Test func diagnosticsNeverCarriesPrivateText() async throws {
    let log = """
    2026-11-09T10:00:00Z ERROR progress 1: Error Domain=NSURLErrorDomain UserInfo={NSErrorFailingURLStringKey=https://retroachievements.org/API/API_GetGameInfoAndUserProgress.php?z=FakeUser&y=FAKEKEY123&g=1, NSLocalizedDescription=The request timed out.}
    2026-11-09T10:00:01Z INFO steam: retroachievements.org/API/x.php?u=someone&y=OTHERKEY
    2026-11-09T10:00:02Z INFO hello fakeuser, sent fakekey123 and FAKESGDBKEY
    2026-11-09T10:00:03Z INFO scanned /Users/fakeperson/ROMs/game.nes
    """
    let text = try await diagnostics(handler(log: log))
    for leaked in ["FAKEKEY123", "fakekey123", "FakeUser", "fakeuser", "FAKESGDBKEY", "OTHERKEY", "someone", "fakeperson", "?z=", "&y=", "?u="] {
        #expect(!text.contains(leaked), "leaked \(leaked)")
    }
    #expect(text.contains("https://retroachievements.org/API/API_GetGameInfoAndUserProgress.php?[removed]"))
    #expect(text.contains("scanned ~/ROMs/game.nes"))
}

@Test func diagnosticsListsTheFacts() async throws {
    let text = try await diagnostics(handler(log: "one line"), #"{"steamBuild":1792618285}"#)
    #expect(text.contains(UpdateChecker.currentVersion))
    #expect(text.contains("Steam build: 1792618285"))
    #expect(text.contains("Signed in: yes"))
    #expect(text.contains("Emulators detected: DuckStation"))
    #expect(text.contains("Steam connection: connected"))
    #expect(text.contains("one line"))
    let signedOut = try await diagnostics(handler(log: "", credentials: nil))
    #expect(signedOut.contains("Signed in: no"))
    #expect(signedOut.contains("Steam build: unknown"))
}

@Test func scrubCoversEveryFormOfTheHomeFolder() {
    func scrub(_ s: String, home: String) -> String { Diagnostics.scrub(s, home: home, secrets: []) }
    #expect(scrub(#"C:\Users\me\a and C:/Users/me/b and C:\\Users\\me\\c and c:\users\ME\d"#, home: "/C:/Users/me") == #"~\a and ~/b and ~\\c and ~\d"#)
    #expect(scrub("/home/al/a /var/home/al/b", home: "/var/home/al") == "~/a ~/b")
    #expect(scrub("/home/al/a /var/home/al/b", home: "/home/al/") == "~/a ~/b")
    #expect(scrub("file:///Users/my%20name/a", home: "/Users/my name") == "file://~/a")
    #expect(scrub("/a/b", home: "/") == "/a/b")
    #expect(scrub("/a/b", home: "") == "/a/b")
}

@Test func diagnosticsKeepsTheLast100LogLines() async throws {
    let text = try await diagnostics(handler(log: (0..<150).map { "entry \($0)." }.joined(separator: "\n")))
    #expect(text.components(separatedBy: "entry ").count - 1 == 100)
    #expect(!text.contains("entry 49."))
    #expect(text.contains("entry 50."))
    #expect(text.contains("entry 149."))
}

@Test func diagnosticsSurvivesAMissingLog() async throws {
    let text = try await diagnostics(handler(log: nil))
    #expect(text.contains("No log file"))
}

@Test func openLogIgnoresWhateverThePageSends() async throws {
    let opened = Counter()
    let h = try handler(log: "", opened: opened)
    _ = try await h.handle(method: "openLog", params: Data(#"{"path":"/etc/passwd","url":"file:///etc/passwd"}"#.utf8))
    #expect(opened.value == 1)  // the action takes no arguments, so nothing the page sends can reach it
    await #expect(throws: (any Error).self) {
        _ = try await h.handle(method: "openURL", params: Data(#"{"url":"file:///etc/passwd"}"#.utf8))
    }
}
