import Foundation

public enum ScanStatus: Equatable, Sendable { case ready, alreadyInSteam, noEmulator(String), chooseConsole }

public struct ScanItem: Identifiable, Equatable, Sendable {
    public var id: String { romPath }
    public var romPath, title: String
    public var consoleId: Int?
    public var emulator: Emulator?
    public var coreFile: String?
    public var status: ScanStatus

    public init(romPath: String, title: String, consoleId: Int?, emulator: Emulator?, coreFile: String?, status: ScanStatus) {
        self.romPath = romPath; self.title = title; self.consoleId = consoleId
        self.emulator = emulator; self.coreFile = coreFile; self.status = status
    }
}

/// What's installed: emulator → executable path, and RetroArch's cores folder.
public struct Installed: Sendable {
    public var emulators: [Emulator: String]
    public var coresDirectory: URL

    public init(emulators: [Emulator: String], coresDirectory: URL) {
        self.emulators = emulators; self.coresDirectory = coresDirectory
    }

    public static func detect() -> Installed {
        var found: [Emulator: String] = [:]
        for e in Emulator.allCases {
            if let exe = e.installedApp().flatMap({ Bundle(url: $0)?.executableURL?.path }) { found[e] = exe }
        }
        let cores = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RetroArch/cores")
        return Installed(emulators: found, coresDirectory: cores)
    }

    /// The first installed core RetroArch has for a console, as a full path.
    func core(for console: Console) -> String? {
        console.cores.map { coresDirectory.appendingPathComponent("\($0)_libretro.dylib").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Default emulator per console, in preference order (spec "Adding games").
public enum EmulatorPreference {
    public static func order(for consoleId: Int) -> [Emulator] {
        switch consoleId {
        case 12: [.duckstation, .retroarch]
        case 21: [.pcsx2]
        case 41: [.ppsspp, .retroarch]
        case 16, 19: [.dolphin]
        case 40: [.flycast, .retroarch]
        case 4, 5, 6: [.retroarch, .skyemu]
        default: [.retroarch]
        }
    }
}

public struct Scanner: Sendable {
    static let skipped: Set<String> = ["txt", "nfo", "jpg", "jpeg", "png", "pdf", "sav", "srm", "state", "cfg", "xml", "dat"]
    let installed: Installed
    let hasher: Fingerprinting

    public init(installed: Installed, hasher: Fingerprinting) { self.installed = installed; self.hasher = hasher }

    /// `consoleOverrides` is keyed by folder path; `emulatorOverrides` by console id.
    public func scan(folder: URL, existingRomPaths: Set<String>, consoleOverrides: [String: Int], emulatorOverrides: [Int: Emulator]) -> [ScanItem] {
        // Compare resolved paths: the enumerator reports /private/var for /var, for example.
        let resolve = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let folder = folder.resolvingSymlinksInPath()
        let existingRomPaths = Set(existingRomPaths.map(resolve))
        let consoleOverrides = Dictionary(consoleOverrides.map { (resolve($0.key), $0.value) }) { a, _ in a }
        return roms(in: folder).map { url in
            let url = url.resolvingSymlinksInPath()
            let path = url.path, title = Titles.clean(url.lastPathComponent)
            guard let consoleId = console(for: url, root: folder, overrides: consoleOverrides) else {
                return ScanItem(romPath: path, title: title, consoleId: nil, emulator: nil, coreFile: nil, status: .chooseConsole)
            }
            let prefs = emulatorOverrides[consoleId].map { [$0] } ?? EmulatorPreference.order(for: consoleId)
            let console = Consoles.byID(consoleId)
            for e in prefs where installed.emulators[e] != nil {
                if e == .retroarch {
                    guard let console, let core = installed.core(for: console) else { continue }
                    return item(path, title, consoleId, e, core, existingRomPaths)
                }
                return item(path, title, consoleId, e, nil, existingRomPaths)
            }
            let first = prefs.first ?? .retroarch
            let hint = first == .retroarch
                ? "In RetroArch, open Online Updater → Core Downloader and get \(console?.cores.first ?? "a core for this console")."
                : "Install \(first.displayName)."
            return ScanItem(romPath: path, title: title, consoleId: consoleId, emulator: nil, coreFile: nil, status: .noEmulator(hint))
        }
    }

    /// Steam on macOS launches games as x86_64, which can't load arm64 cores, so the emulator runs through `arch -arm64`.
    /// `bundle` is the .app that Steam's AddShortcut needs before the exe is switched to arch.
    public static func shortcut(for item: ScanItem, installed: Installed) -> (name: String, exe: String, launchOptions: String, startDir: String, bundle: String) {
        let emulator = item.emulator ?? .retroarch
        let exe = installed.emulators[emulator] ?? ""
        let dir = (exe as NSString).deletingLastPathComponent + "/"
        let bundle = exe.range(of: ".app/").map { String(exe[..<$0.lowerBound]) + ".app" } ?? exe
        return (item.title, "\"/usr/bin/arch\"", "-arm64 \"\(exe)\" " + emulator.launchOptions(rom: item.romPath, coreFile: item.coreFile),
                "\"\(dir)\"", bundle)
    }

    private func item(_ path: String, _ title: String, _ console: Int, _ e: Emulator, _ core: String?, _ existing: Set<String>) -> ScanItem {
        ScanItem(romPath: path, title: title, consoleId: console, emulator: e, coreFile: core,
                 status: existing.contains(path) ? .alreadyInSteam : .ready)
    }

    private func console(for url: URL, root: URL, overrides: [String: Int]) -> Int? {
        var dir = url.deletingLastPathComponent()
        while dir.path.count >= root.path.count {
            if let c = Consoles.forFolder(dir.lastPathComponent) { return c.id }
            if dir.path == root.path { break }
            dir = dir.deletingLastPathComponent()
        }
        if let c = overrides[url.deletingLastPathComponent().path] { return c }
        let fps = Set(hasher.allFingerprints(romPath: url.path).map(\.consoleId))
        return fps.count == 1 ? fps.first : nil
    }

    /// ROM files under `folder`. A folder with an .m3u lists only playlists; one with .cue/.gdi skips its track files.
    private func roms(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let files = walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let byFolder = Dictionary(grouping: files) { $0.deletingLastPathComponent().path }
        return byFolder.values.flatMap { group -> [URL] in
            let exts = Set(group.map { $0.pathExtension.lowercased() })
            if exts.contains("m3u") { return group.filter { $0.pathExtension.lowercased() == "m3u" } }
            // shortcut: skips every .bin beside a .cue instead of parsing the cue; upgrade if mixed folders show up
            let trackFiles: Set<String> = exts.contains("cue") || exts.contains("gdi") ? ["bin", "raw", "img"] : []
            return group.filter { u in
                let e = u.pathExtension.lowercased()
                return !e.isEmpty && !Self.skipped.contains(e) && !trackFiles.contains(e)
            }
        }.sorted { $0.path < $1.path }
    }
}
