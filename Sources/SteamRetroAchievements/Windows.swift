import AppKit
import SwiftUI

enum AppWindow: Hashable { case settings, addGames }

extension AppModel {
    /// AppKit windows hosting SwiftUI views, so bridge calls from Steam can open them too. Created once, then reused.
    func show(_ w: AppWindow) {
        NSApp.activate()
        if let existing = windows[w] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window: NSWindow
        switch w {
        case .settings:
            window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: self, form: SignInForm())))
            window.title = "Steam RetroAchievements"
        case .addGames:
            window = NSWindow(contentViewController: NSHostingController(rootView: AddGamesView(model: AddGamesModel(app: self), app: self)))
            window.title = "Add Games"
        }
        window.styleMask = w == .addGames ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[w] = window
        window.makeKeyAndOrderFront(nil)
    }
}
