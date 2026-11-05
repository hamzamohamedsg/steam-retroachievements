import Foundation
import Testing
@testable import SteamBridge

@Test func markerEnsureAndRemove() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sra-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let m = DebugMarker(directory: dir)
    #expect(!m.exists())
    try m.ensure()
    #expect(m.exists())
    #expect(m.createdAt != nil)
    try m.remove()
    #expect(!m.exists())
}

@Test func picksSharedJSContext() throws {
    let json = #"""
    [{"id":"a","title":"Steam","type":"page","webSocketDebuggerUrl":"ws://x/a"},
     {"id":"b","title":"SharedJSContext","type":"page","webSocketDebuggerUrl":"ws://x/b"},
     {"id":"c","title":"Friends List","type":"page"}]
    """#
    let targets = try JSONDecoder().decode([CDPTarget].self, from: Data(json.utf8))
    #expect(SteamConnection.sharedJSContext(in: targets)?.id == "b")
}

@Test func decideRules() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    #expect(SteamConnection.decide(steamRunning: false, steamLaunched: nil, markerCreated: t0, portAnswered: false, now: t0) == .steamNotRunning)
    #expect(SteamConnection.decide(steamRunning: true, steamLaunched: t0, markerCreated: t0 + 5, portAnswered: false, now: t0 + 6) == .needsRestart)
    #expect(SteamConnection.decide(steamRunning: true, steamLaunched: t0 + 10, markerCreated: t0, portAnswered: true, now: t0 + 11) == .connecting)
    #expect(SteamConnection.decide(steamRunning: true, steamLaunched: t0 + 10, markerCreated: t0, portAnswered: false, now: t0 + 20) == .connecting)
    #expect(SteamConnection.decide(steamRunning: true, steamLaunched: t0 + 10, markerCreated: t0, portAnswered: false, now: t0 + 31) == .needsRestart)
    // Steam's port answering proves it's open with the switch on, even if the process check missed it.
    #expect(SteamConnection.decide(steamRunning: false, steamLaunched: nil, markerCreated: t0, portAnswered: true, now: t0) == .connecting)
}

#if os(Windows)
@Test func findsARunningProgramAndWhenItStarted() throws {
    let me = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
    let found = SteamConnection.runningProgram(me.uppercased())
    #expect(found.running)
    let started = try #require(found.launched)
    #expect(started <= Date() && started > Date() - 3600)
    #expect(!SteamConnection.runningProgram("no-such-program-\(UUID().uuidString).exe").running)
}
#endif

@Test func windowsCommandLineQuotesLikeCommandLineToArgvW() {
    #expect(windowsCommandLine([#"C:\Windows\System32\tasklist.exe"#, "/FI", "IMAGENAME eq steam.exe", "/NH"])
        == #"C:\Windows\System32\tasklist.exe /FI "IMAGENAME eq steam.exe" /NH"#)
    // The Run key's value is the exe path in quotes; a folder ending in a backslash keeps it; an empty argument survives.
    #expect(windowsCommandLine([#""C:\Program Files\SRA\a.exe""#, #"C:\My Games\"#, ""]) == #""\"C:\Program Files\SRA\a.exe\"" "C:\My Games\\" """#)
}
