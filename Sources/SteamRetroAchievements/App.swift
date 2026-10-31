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
            Image(systemName: model.iconName)
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
            Button("Restart Steam…") { model.confirmRestartSteam() }
        }
        Divider()
        Button("Add Games…") { model.show(.addGames) }
        Button("Settings…") { model.show(.settings) }
        Divider()
        Button("Quit Steam RetroAchievements") { NSApp.terminate(nil) }
    }
}
