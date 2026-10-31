#if os(macOS)
import AppKit
import SwiftUI

@main
struct SteamRetroAchievementsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.credentials == nil || model.steamState == .needsRestart ? "exclamationmark.triangle" : "trophy")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.statusText)
        if model.steamState == .needsRestart {
            Button("Restart Steam…") { confirmRestartSteam() }
        }
        Divider()
        Button("Add Games…") { openInSteam("openAddGames") }.disabled(model.steamState != .connected)
        Button("Settings…") { openInSteam("openSettings") }.disabled(model.steamState != .connected)
        Divider()
        Button("Quit Steam RetroAchievements") { NSApp.terminate(nil) }
    }

    /// The dialogs live in Steam's library window.
    func openInSteam(_ function: String) {
        model.steam.activateSteam()
        Task { await model.run("window.__sra.\(function)()") }
    }

    func confirmRestartSteam() {
        let alert = NSAlert()
        alert.messageText = "Restart Steam?"
        alert.informativeText = "This quits Steam and any game running in it, then opens Steam again."
        alert.addButton(withTitle: "Restart Steam")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.steam.restartSteam() }
    }
}
#else
/// Linux and Windows: no menu bar, just the background program. Status goes to the terminal and the log.
@main
enum Headless {
    @MainActor static func main() async {
        AppModel.shared.launch()
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }
}
#endif
