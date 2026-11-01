import Foundation
import Testing
@testable import RACore

final class Spy: @unchecked Sendable { var credentials = false, login = false }

@Test func uninstallRemovesEverything() throws {
    let root = tempDir(), fm = FileManager.default
    let marker = root.appendingPathComponent(".cef-enable-remote-debugging")
    let data = root.appendingPathComponent("data"), log = root.appendingPathComponent("x.log")
    let app = root.appendingPathComponent("Fake \(UUID().uuidString).app")
    try Data().write(to: marker)
    try fm.createDirectory(at: data, withIntermediateDirectories: true)
    try Data("m".utf8).write(to: data.appendingPathComponent("matches.json"))
    try Data("l".utf8).write(to: log)
    try fm.createDirectory(at: app, withIntermediateDirectories: true)

    let spy = Spy()
    try Uninstaller.run(UninstallPaths(marker: marker, dataDir: data, log: log, app: app),
                        deleteCredentials: { spy.credentials = true }, disableLogin: { spy.login = true })

    #expect(!fm.fileExists(atPath: marker.path))
    #expect(!fm.fileExists(atPath: data.path))
    #expect(!fm.fileExists(atPath: log.path))
    #if os(macOS)
    #expect(!fm.fileExists(atPath: app.path))  // only macOS moves the app to the Trash; elsewhere the user deletes the folder
    #endif
    #expect(spy.credentials)
    #expect(spy.login)
}
