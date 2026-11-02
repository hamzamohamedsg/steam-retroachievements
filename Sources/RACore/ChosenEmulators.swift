import Foundation

/// Emulators the user pointed to themselves in Settings, for copies detection doesn't find: emulator id → executable, in one JSON file.
public struct ChosenEmulators: Sendable {
    let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> [Emulator: String] {
        Dictionary(saved().compactMap { k, v in Emulator(rawValue: k).map { ($0, v) } }) { a, _ in a }
    }

    /// nil when saved, otherwise what to tell the user. Takes a macOS .app too, and stores the program inside it.
    public func choose(_ emulator: Emulator, path: String) -> String? {
        var exe = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
        if exe.hasSuffix(".app"), let inner = Bundle(path: exe)?.executablePath { exe = inner }
        // Shortcuts are told apart by their program's name, so one the app wouldn't recognize as this emulator gets no panel.
        guard FileManager.default.isExecutableFile(atPath: exe), EmulatorLaunch.match(exe) == emulator else {
            return "That isn't \(emulator.displayName). Choose the program you start \(emulator.displayName) with."
        }
        var all = saved()
        all[emulator.rawValue] = exe
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
        } catch {
            return "Couldn't save that: \(error.localizedDescription)"
        }
        return nil
    }

    private func saved() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }
}
