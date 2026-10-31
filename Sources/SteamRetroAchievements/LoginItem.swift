import Foundation
#if os(macOS)
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
#elseif os(Windows)
import SteamBridge

/// A value under the user's Run key.
enum LoginItem {
    static let key = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", name = "SteamRetroAchievements"
    static let reg = "C:\\Windows\\System32\\reg.exe"

    static var isEnabled: Bool { runProcess(reg, ["query", key, "/v", name]).status == 0 }

    static func set(_ on: Bool) throws {
        let args = on ? ["add", key, "/v", name, "/t", "REG_SZ", "/d", "\"\(AppPaths.executable)\"", "/f"] : ["delete", key, "/v", name, "/f"]
        if runProcess(reg, args).status != 0, isEnabled != on { throw CocoaError(.fileWriteUnknown) }
    }
}
#else
import SteamBridge

/// A systemd user service: it starts in Steam Deck's Game Mode too, where desktop autostart entries don't run.
enum LoginItem {
    static let unit = "steam-retroachievements.service"
    static var unitFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/systemd/user/\(unit)") }

    static var isEnabled: Bool { runProcess("/usr/bin/env", ["systemctl", "--user", "is-enabled", "--quiet", unit]).status == 0 }

    static func set(_ on: Bool) throws {
        if on {
            try FileManager.default.createDirectory(at: unitFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try """
            [Unit]
            Description=Steam RetroAchievements

            [Service]
            ExecStart="\(AppPaths.executable)"
            Restart=on-failure

            [Install]
            WantedBy=default.target

            """.write(to: unitFile, atomically: true, encoding: .utf8)
            // enable without --now: this process is already the running copy.
            guard runProcess("/usr/bin/env", ["systemctl", "--user", "enable", unit]).status == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            runProcess("/usr/bin/env", ["systemctl", "--user", "disable", unit])
            try? FileManager.default.removeItem(at: unitFile)
        }
    }
}
#endif
