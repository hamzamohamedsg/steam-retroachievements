#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import RACore
import SteamBridge

/// Everything the app does on every platform. Settings and Add Games are dialogs inside Steam (steam/inject.js).
@MainActor @Observable final class AppModel {
    static let shared: AppModel = AppModel()

    var credentials: RACredentials? = CredentialStore.load()
    var steamState: SteamState = .steamNotRunning
    /// A newer release on GitHub, if there is one.
    var update: (version: String, page: URL)?

    @ObservationIgnored let marker: DebugMarker
    @ObservationIgnored let steam: SteamConnection
    @ObservationIgnored var services: Services?
    @ObservationIgnored let router: BridgeRouter

    init() {
        let marker = DebugMarker()
        self.marker = marker
        steam = SteamConnection(
            marker: marker,
            script: { AppPaths.injectScript() },
            onBinding: { payload in await AppModel.shared.router.respond(to: payload) })
        router = BridgeRouter(handler: BridgeHandler(
            services: { await AppModel.shared.services },
            actions: BridgeActions(
                openURL: { url in await MainActor.run { AppModel.open(url) } },
                log: { level, message in level == "error" ? Log.error("steam: \(message)") : Log.info("steam: \(message)") },
                account: { await MainActor.run { (AppModel.shared.credentials?.username, LoginItem.isEnabled) } },
                signIn: { username, apiKey in await AppModel.shared.signIn(username: username, apiKey: apiKey) },
                signOut: { await AppModel.shared.signOut() },
                setOpenAtLogin: { on in await AppModel.shared.setOpenAtLogin(on) },
                uninstall: { await AppModel.shared.uninstall() }),
            push: { js in await AppModel.shared.run(js) },
            folderFile: AppPaths.data.appendingPathComponent("rom-folder.txt")))
        services = credentials.map { Services(credentials: $0, dataDirectory: AppPaths.data) }
    }

    /// Evaluates JS in Steam and drops the result (pushes from the bridge).
    func run(_ js: String) async { _ = try? await steam.evaluate(js) }

    var statusText: String {
        switch steamState {
        case .connected: return credentials == nil ? "Connected to Steam. Sign in from Steam's library" : "Connected to Steam"
        case .connecting, .steamNotRunning: return "Waiting for Steam to open"
        case .needsRestart: return "Restart Steam to finish setup"
        }
    }

    func launch() {
        #if os(Linux)
        RunningCopy.takeOver()
        DesktopEntry.install()
        // The login service starts this copy from now on, so an update unpacked somewhere else takes over at the next login too.
        if LoginItem.isEnabled, (try? String(contentsOf: LoginItem.unitFile, encoding: .utf8))?.contains(AppPaths.executable) != true {
            _ = setOpenAtLogin(true)
        }
        let freshMarker = !marker.exists()
        #endif
        steam.onStateChange = { [weak self] state in
            guard let self else { return }
            steamState = state
            Log.info(statusText)
            #if os(Windows)
            Tray.status.withLock { $0 = statusText }
            #elseif os(Linux)
            // Only on first setup: a Steam that is slow to open its port at login isn't worth a notice.
            if state == .needsRestart, freshMarker {
                AppModel.notify("Restart Steam to finish setup", "Steam reads the setting Steam RetroAchievements needs only when it starts. On a Steam Deck, going back to Game Mode restarts it.")
            }
            #endif
            // First run: put the sign-in dialog in front of the user as soon as Steam can show it.
            if state == .connected, credentials == nil { Task { await self.run("window.__sra.openSettings()") } }
        }
        steam.onError = { Log.error("steam: \($0)") }
        // The handler only hears about changes: show the starting state too, or a Steam that isn't open leaves the tray at "Starting".
        steam.onStateChange?(steam.state)
        steam.start()  // also while signed out: the Steam panel then shows the sign-in prompt
        Log.info("launched")
        Task {
            guard let found = await UpdateChecker.newerRelease() else { return }
            update = found
            Log.info("update available: \(found.version) \(found.page)")
            #if os(Windows)
            Tray.update.withLock { $0 = found }
            #elseif os(Linux)
            AppModel.notify("Steam RetroAchievements \(found.version) is out", found.page.absoluteString)
            #endif
        }
    }

    /// nil on success, otherwise the error text for the Settings dialog.
    func signIn(username: String, apiKey: String) async -> String? {
        let c = RACredentials(username: username.trimmingCharacters(in: .whitespaces), apiKey: apiKey.trimmingCharacters(in: .whitespaces))
        do {
            try await RAClient(credentials: c).checkCredentials()
            try CredentialStore.save(c)
        } catch RAError.badCredentials {
            return "Couldn't sign in. Check your username and Web API key."
        } catch {
            return "Couldn't reach RetroAchievements. Try again in a moment."
        }
        credentials = c
        services = Services(credentials: c, dataDirectory: AppPaths.data)
        _ = setOpenAtLogin(true)
        try? marker.ensure()
        return nil
    }

    func signOut() {
        CredentialStore.delete()
        credentials = nil
        services = nil
    }

    func setOpenAtLogin(_ on: Bool) -> Bool {
        do { try LoginItem.set(on) } catch { Log.error("login item: \(error)") }
        return LoginItem.isEnabled
    }

    /// The Settings dialog asked first. Quits once the bridge reply has had time to reach Steam.
    func uninstall() {
        do {
            try Uninstaller.run(UninstallPaths(marker: marker.url, dataDir: AppPaths.data, log: AppPaths.log, app: AppPaths.app),
                                deleteCredentials: CredentialStore.delete, disableLogin: { try? LoginItem.set(false) })
        } catch {
            Log.error("uninstall: \(error)")
        }
        #if os(Linux)
        try? FileManager.default.removeItem(at: DesktopEntry.file)
        #endif
        Task {
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(Windows)
        runProcess("C:\\Windows\\System32\\rundll32.exe", ["url.dll,FileProtocolHandler", url.absoluteString])
        #else
        runProcess("/usr/bin/env", ["xdg-open", url.absoluteString])
        #endif
    }

    #if os(Linux)
    /// A desktop notification (Linux has no menu or tray): notify-send, or where that isn't installed the notification
    /// service over D-Bus with busctl, which comes with systemd (SteamOS, Bazzite). Nothing shows if neither works.
    static func notify(_ title: String, _ body: String) {
        guard runProcess("/usr/bin/env", ["notify-send", title, body]).status != 0 else { return }
        runProcess("/usr/bin/env", ["busctl", "--user", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                                    "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", "Steam RetroAchievements", "0", "", title, body, "0", "0", "-1"])
    }
    #endif
}
