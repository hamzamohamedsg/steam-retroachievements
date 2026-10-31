import RACore
import SwiftUI

/// Form state lives in an @Observable object: Command Line Tools ships no SwiftUI macro plugin, so `@State` won't compile.
@MainActor @Observable final class SignInForm {
    var username = ""
    var apiKey = ""
    var error: String?
    var busy = false
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var form: SignInForm

    var body: some View {
        Form {
            Section("RetroAchievements") {
                if let c = model.credentials {
                    LabeledContent("Signed in as \(c.username)") {
                        Button("Sign Out") { model.signOut() }
                    }
                } else {
                    // Visible boxes with prompts: grouped-form fields otherwise render as near-invisible strips beside the label.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username")
                        TextField("Username", text: $form.username, prompt: Text("Your RetroAchievements username"))
                            .textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Web API key")
                        SecureField("Web API key", text: $form.apiKey, prompt: Text("Paste your Web API key"))
                            .textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    Link("Find your Web API key", destination: URL(string: "https://retroachievements.org/settings")!)
                    if let error = form.error { Text(error).foregroundStyle(.red) }
                    Button("Sign In") {
                        form.busy = true
                        Task {
                            form.error = await model.signIn(username: form.username, apiKey: form.apiKey)
                            form.busy = false
                            if form.error == nil { form.apiKey = "" }
                        }
                    }
                    .disabled(form.busy || form.username.isEmpty || form.apiKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            Section("Steam") {
                Text(model.statusText)
                if model.steamState == .needsRestart {
                    Button("Restart Steam") { model.confirmRestartSteam() }
                }
            }
            Section("Emulators") {
                ForEach(Emulator.allCases, id: \.self) { e in
                    LabeledContent(e.displayName, value: e.installedApp() == nil ? "Not installed" : "Installed")
                }
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section {
                Button("Uninstall…") { model.confirmUninstall() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
