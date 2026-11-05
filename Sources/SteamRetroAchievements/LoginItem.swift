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

    /// Whether the Run value starts this copy of the program, rather than one in another folder (an older version's).
    static var startsThisCopy: Bool {
        let out = runProcess(reg, ["query", key, "/v", name]).output
        let value = out.components(separatedBy: "REG_SZ").dropFirst().first ?? ""
        // Paths take either slash and any case on Windows.
        func normal(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\""])).replacingOccurrences(of: "\\", with: "/").lowercased()
        }
        return normal(value) == normal(AppPaths.executable)
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

/// One copy at a time, the newest: a copy started by hand (an update, or from the app menu) replaces the one the login
/// service started, so an old version never keeps answering Steam beside the new one.
enum RunningCopy {
    static var pidFile: URL { AppPaths.data.appendingPathComponent("steam-retroachievements.pid") }

    static func takeOver() {
        if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
           pid != getpid(),
           // A pid can be reused: signal it only while it's still this program (comm is cut to 15 characters).
           (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?.hasPrefix("steam-retroach") == true {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true)
        try? "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
    }
}

/// An app-menu entry with the icon, pointing at wherever this copy of the program is (it's rewritten on every launch).
enum DesktopEntry {
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/applications/steam-retroachievements.desktop") }

    static func install() {
        let icon = URL(fileURLWithPath: AppPaths.executable).deletingLastPathComponent().appendingPathComponent("icon.png").path
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        [Desktop Entry]
        Type=Application
        Name=Steam RetroAchievements
        Comment=Shows your RetroAchievements in the Steam library
        Exec="\(AppPaths.executable)"
        Icon=\(icon)
        Terminal=false
        Categories=Game;

        """.write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
