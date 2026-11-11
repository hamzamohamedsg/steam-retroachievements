#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import RACore
import SteamBridge
#if os(Windows)
import WinSDK
#endif

/// Everything the app does on every platform. Settings and Add Games are dialogs inside Steam (steam/inject.js).
@MainActor @Observable final class AppModel {
    static let shared: AppModel = AppModel()

    var credentials: RACredentials? = CredentialStore.load()
    var steamState: SteamState = .steamNotRunning
    /// A newer release on GitHub, if there is one.
    var update: (version: String, page: URL)?
    var updating = false

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
                uninstall: { await AppModel.shared.uninstall() },
                updateVersion: { await MainActor.run { AppModel.shared.update?.version } },
                installUpdate: { await AppModel.shared.installUpdate() },
                // Detached and off the main actor: xdg-open can hold on until the viewer closes.
                openLog: { Task.detached { AppModel.open(AppPaths.log) } },
                credentials: { await MainActor.run { AppModel.shared.credentials } },
                steamState: { await MainActor.run { "\(AppModel.shared.steamState)" } }),
            push: { js in await AppModel.shared.run(js) },
            folderFile: AppPaths.data.appendingPathComponent("rom-folder.txt"), logFile: AppPaths.log))
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
        #elseif os(Windows)
        // The Run value starts the copy that set it: point it at this one, so an update unzipped somewhere else is the one that starts at login.
        if LoginItem.isEnabled, !LoginItem.startsThisCopy { _ = setOpenAtLogin(true) }
        #endif
        #if !os(macOS)  // macOS clears up after itself; listing a Mac app's folder at every start could raise a privacy prompt
        Updater.removeLeftovers(in: URL(fileURLWithPath: AppPaths.executable).deletingLastPathComponent())
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

    /// Update Now, from the menu, the tray or the Steam dialog. nil when the new copy is starting, otherwise the error to show.
    /// Whatever goes wrong, the old copy keeps running and the release page opens.
    func installUpdate() async -> String? {
        guard let update, !updating else { return "An update is already running." }
        updating = true
        defer { updating = false }
        // Read now: once the running program is renamed aside, its reported path can be the aside name.
        let executable = AppPaths.executable
        do {
            guard let layout = Updater.layout(executable: executable, app: AppPaths.app) else { throw UpdateFailure.notWritable }
            try await Updater.install(layout: layout, check: AppModel.runs, relaunch: { AppModel.relaunch(layout, executable: executable) })
            Log.info("updated to \(update.version)")
            #if os(macOS)
            // Linux's and Windows's new copies stop this one when they start; macOS has no such handover.
            Task {
                try? await Task.sleep(for: .seconds(1))
                exit(0)
            }
            #endif
            return nil
        } catch {
            Log.error("update: \(error)")
            AppModel.open(update.page)
            return "The update couldn't be installed here, so its release page has opened instead."
        }
    }

    /// Tries the staged copy before anything is replaced. A release that ignored --version would hang here with the old copy still running.
    nonisolated static func runs(_ program: URL) -> Bool {
        #if os(macOS)
        let app = program.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { return false }
        #endif
        return runProcess(program.path, ["--version"]).status == 0
    }

    /// Starts the new copy, which is in place by now. False puts the old copy back.
    nonisolated static func relaunch(_ layout: UpdateLayout, executable: String) -> Bool {
        #if os(macOS)
        return runProcess("/usr/bin/open", ["-n", layout.folder.appendingPathComponent(layout.program.components(separatedBy: "/")[0]).path]).status == 0
        #else
        #if os(Linux)
        // Under the login service, restart it so the new copy stays under the service. --no-block: the restart stops this process.
        if (try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8))?.contains("/\(LoginItem.unit)") == true {
            return runProcess("/usr/bin/env", ["systemctl", "--user", "--no-block", "restart", LoginItem.unit]).status == 0
        }
        #endif
        #if os(Windows)
        // Not Process: it hands the child every inheritable handle open here, and this child runs for good, holding them.
        var si = STARTUPINFOW(), pi = PROCESS_INFORMATION()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        let started = "\"\(executable)\"".withCString(encodedAs: UTF16.self) {
            CreateProcessW(nil, UnsafeMutablePointer(mutating: $0), nil, nil, false, 0, nil, nil, &si, &pi)
        }
        if started { CloseHandle(pi.hProcess); CloseHandle(pi.hThread) }
        return started
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        return (try? process.run()) != nil
        #endif
        #endif
    }

    nonisolated static func open(_ url: URL) {
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
