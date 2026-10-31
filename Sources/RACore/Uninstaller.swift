import Foundation

public struct UninstallPaths: Sendable {
    public var marker, dataDir, log: URL
    /// The .app to trash on macOS; nil elsewhere, where the user deletes the program's folder.
    public var app: URL?
    public init(marker: URL, dataDir: URL, log: URL, app: URL?) {
        self.marker = marker; self.dataDir = dataDir; self.log = log; self.app = app
    }
}

public enum Uninstaller {
    /// Removes everything the app made except the Steam shortcuts it added, then moves the app to the Trash (macOS).
    public static func run(_ p: UninstallPaths, deleteCredentials: () -> Void, disableLogin: () -> Void) throws {
        let fm = FileManager.default
        disableLogin()
        deleteCredentials()
        for url in [p.marker, p.dataDir, p.log] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        #if os(macOS)
        if let app = p.app, fm.fileExists(atPath: app.path) { try fm.trashItem(at: app, resultingItemURL: nil) }
        #endif
    }
}

#if os(macOS)
extension Emulator {
    /// The installed app bundle, looked up by name in /Applications and ~/Applications.
    public func installedApp(searchDirectories: [URL] = [URL(fileURLWithPath: "/Applications"),
                                                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> URL? {
        for dir in searchDirectories {
            for name in appNames {
                let url = dir.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
#endif
