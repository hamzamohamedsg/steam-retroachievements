import AppKit
import Observation
import RACore
import SteamBridge

@MainActor @Observable final class AppModel {
    static let shared: AppModel = AppModel()

    var credentials: RACredentials? = Keychain.load()
    var steamState: SteamState = .steamNotRunning
    var openAtLogin = LoginItem.isEnabled

    @ObservationIgnored let marker: DebugMarker
    @ObservationIgnored let steam: SteamConnection
    @ObservationIgnored var windows: [AppWindow: NSWindow] = [:]
    @ObservationIgnored var services: Services?
    @ObservationIgnored let router: BridgeRouter

    init() {
        let marker = DebugMarker()
        self.marker = marker
        steam = SteamConnection(
            marker: marker,
            script: { (Bundle.main.url(forResource: "inject", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "" },
            onBinding: { payload in await AppModel.shared.router.respond(to: payload) })
        router = BridgeRouter(handler: BridgeHandler(
            services: { await AppModel.shared.services },
            actions: BridgeActions(
                openSettings: { await AppModel.shared.show(.settings) },
                openAddGames: { await AppModel.shared.show(.addGames) },
                openURL: { url in _ = await MainActor.run { NSWorkspace.shared.open(url) } },
                log: { level, message in level == "error" ? Log.error("steam: \(message)") : Log.info("steam: \(message)") }),
            push: { js in await AppModel.shared.run(js) }))
        services = credentials.map { Services(credentials: $0, dataDirectory: AppPaths.data) }
    }

    /// Evaluates JS in Steam and drops the result (pushes from the bridge).
    func run(_ js: String) async { _ = try? await steam.evaluate(js) }

    var statusText: String {
        if credentials == nil { return "Sign in to RetroAchievements to start" }
        switch steamState {
        case .connected: return "Connected to Steam"
        case .connecting, .steamNotRunning: return "Waiting for Steam to open"
        case .needsRestart: return "Restart Steam to finish setup"
        }
    }

    var iconName: String { credentials == nil || steamState == .needsRestart ? "exclamationmark.triangle" : "trophy" }

    func launch() {
        steam.onStateChange = { [weak self] in self?.steamState = $0 }
        steam.onError = { Log.error("steam: \($0)") }
        steam.start()  // also while signed out: the Steam panel then shows the sign-in prompt
        if credentials == nil { show(.settings) }
        Log.info("launched")
    }

    /// nil on success, otherwise the error text for the Settings window.
    func signIn(username: String, apiKey: String) async -> String? {
        let c = RACredentials(username: username.trimmingCharacters(in: .whitespaces), apiKey: apiKey.trimmingCharacters(in: .whitespaces))
        do {
            try await RAClient(credentials: c).checkCredentials()
            try Keychain.save(c)
        } catch RAError.badCredentials {
            return "Couldn't sign in. Check your username and Web API key."
        } catch {
            return "Couldn't reach RetroAchievements. Try again in a moment."
        }
        credentials = c
        services = Services(credentials: c, dataDirectory: AppPaths.data)
        setOpenAtLogin(true)
        try? marker.ensure()
        return nil
    }

    func signOut() {
        Keychain.delete()
        credentials = nil
        services = nil
    }

    func setOpenAtLogin(_ on: Bool) {
        do { try LoginItem.set(on) } catch { Log.error("login item: \(error)") }
        openAtLogin = LoginItem.isEnabled
    }

    func confirmRestartSteam() {
        let alert = NSAlert()
        alert.messageText = "Restart Steam?"
        alert.informativeText = "This quits Steam and any game running in it, then opens Steam again."
        alert.addButton(withTitle: "Restart Steam")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await steam.restartSteam() }
    }

    func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Steam RetroAchievements?"
        alert.informativeText = "This turns off Steam's debug switch, deletes your saved sign-in and cached data, and moves the app to the Trash. Games it added stay in your Steam library."
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Uninstaller.run(UninstallPaths(marker: marker.url, dataDir: AppPaths.data, log: AppPaths.log, app: Bundle.main.bundleURL),
                                deleteCredentials: Keychain.delete, disableLogin: { try? LoginItem.set(false) })
        } catch {
            Log.error("uninstall: \(error)")
        }
        NSApp.terminate(nil)
    }
}
