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
}
