import AppKit
import RACore
import SwiftUI

@MainActor @Observable final class AddGamesModel {
    var folder = AppPaths.roms
    var items: [ScanItem] = []
    var included: Set<String> = []
    var consoleOverrides: [String: Int] = [:]
    var emulatorOverrides: [Int: Emulator] = [:]
    var result: String?
    var busy = false
    @ObservationIgnored let app: AppModel
    @ObservationIgnored var installed = Installed.detect()

    init(app: AppModel) {
        self.app = app
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var readyCount: Int { items.filter { $0.status == .ready && included.contains($0.id) }.count }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url; Task { await scan() } }
    }

    func scan() async {
        busy = true
        defer { busy = false }
        installed = Installed.detect()
        let existing = await existingRomPaths()
        let (folder, consoleOverrides, emulatorOverrides, installed) = (folder, consoleOverrides, emulatorOverrides, installed)
        items = await Task.detached {
            Scanner(installed: installed, hasher: RomHasher())
                .scan(folder: folder, existingRomPaths: existing, consoleOverrides: consoleOverrides, emulatorOverrides: emulatorOverrides)
        }.value
        included = Set(items.filter { $0.status == .ready }.map(\.id))
        result = items.isEmpty ? "No games found in this folder." : nil
    }

    func add() async {
        busy = true
        defer { busy = false }
        let chosen = items.filter { $0.status == .ready && included.contains($0.id) }
        let payload = chosen.map { item -> [String: String] in
            let s = Scanner.shortcut(for: item, installed: installed)
            return ["name": s.name, "exe": s.exe, "launchOptions": s.launchOptions, "startDir": s.startDir, "bundle": s.bundle]
        }
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let results = try await app.steam.evaluate("window.__sra.addShortcuts(\(json))") as? [[String: Any]] ?? []
            let errors = results.compactMap { r in (r["error"] as? String).map { "\(r["name"] as? String ?? "?"): \($0)" } }
            let added = results.count - errors.count
            result = (["Added \(added) games to Steam."] + errors).joined(separator: "\n")
        } catch {
            result = "Couldn't add games: \(error)"
        }
        await scan()
    }

    /// ROM paths of every emulator shortcut already in Steam.
    private func existingRomPaths() async -> Set<String> {
        guard app.steamState == .connected,
              let list = try? await app.steam.evaluate("window.__sra.listShortcuts()") as? [[String: Any]] else { return [] }
        return Set(list.compactMap { s in
            EmulatorLaunch.parse(exe: s["exe"] as? String ?? "", launchOptions: s["launchOptions"] as? String ?? "")?.romPath
        })
    }

    func emulatorChoices(for consoleId: Int) -> [Emulator] {
        var choices = EmulatorPreference.order(for: consoleId)
        if !choices.contains(.retroarch) { choices.append(.retroarch) }
        return choices.filter { installed.emulators[$0] != nil }
    }

    func statusText(_ s: ScanStatus) -> String {
        switch s {
        case .ready: "Ready"
        case .alreadyInSteam: "Already in Steam"
        case .noEmulator(let hint): hint
        case .chooseConsole: "Choose a console"
        }
    }
}

struct AddGamesView: View {
    @Bindable var model: AddGamesModel
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.folder.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseFolder() }
                Button("Scan") { Task { await model.scan() } }.disabled(model.busy)
            }
            Table(model.items) {
                TableColumn("") { item in
                    Toggle("", isOn: Binding(get: { model.included.contains(item.id) },
                                             set: { on in if on { model.included.insert(item.id) } else { model.included.remove(item.id) } }))
                        .labelsHidden()
                        .disabled(item.status != .ready)
                }.width(24)
                TableColumn("Game") { item in Text(item.title) }
                TableColumn("Console") { item in
                    if item.status == .chooseConsole {
                        Picker("", selection: Binding(get: { -1 }, set: { id in
                            model.consoleOverrides[(item.romPath as NSString).deletingLastPathComponent] = id
                            Task { await model.scan() }
                        })) {
                            Text("Choose…").tag(-1)
                            ForEach(Consoles.all, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                    } else {
                        Text(item.consoleId.flatMap(Consoles.byID)?.name ?? "")
                    }
                }
                TableColumn("Emulator") { item in
                    if let c = item.consoleId, let e = item.emulator, model.emulatorChoices(for: c).count > 1 {
                        Picker("", selection: Binding(get: { e }, set: { model.emulatorOverrides[c] = $0; Task { await model.scan() } })) {
                            ForEach(model.emulatorChoices(for: c), id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden()
                    } else {
                        Text(item.emulator?.displayName ?? "")
                    }
                }
                TableColumn("Status") { item in Text(model.statusText(item.status)).foregroundStyle(item.status == .ready ? .primary : .secondary) }
            }
            .frame(minHeight: 280)
            HStack {
                if let result = model.result { Text(result).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                if app.steamState != .connected { Text("Open Steam first").foregroundStyle(.secondary) }
                Button("Add \(model.readyCount) Games to Steam") { Task { await model.add() } }
                    .disabled(model.busy || model.readyCount == 0 || app.steamState != .connected)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 760)
        .task { await model.scan() }
    }
}
