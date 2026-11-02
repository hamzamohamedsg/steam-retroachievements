import Foundation
#if os(Windows)
import SteamBridge
#endif

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

/// How Steam starts an emulator: its executable plus any arguments that come before the emulator's own (`run <id>` for Flatpak).
public struct Launcher: Equatable, Sendable {
    public var exe: String
    public var args: String
    public init(exe: String, args: String = "") { self.exe = exe; self.args = args }
}

/// What's installed: emulator → launcher, and RetroArch's cores folder.
public struct Installed: Sendable {
    public var emulators: [Emulator: Launcher]
    public var coresDirectory: URL

    public init(emulators: [Emulator: Launcher], coresDirectory: URL) {
        self.emulators = emulators; self.coresDirectory = coresDirectory
    }

    #if os(macOS)
    public static let coreExtension = "dylib"
    #elseif os(Windows)
    public static let coreExtension = "dll"
    #else
    public static let coreExtension = "so"
    #endif

    /// `chosen` holds the programs the user picked in Settings; they win over anything found here.
    public static func detect(chosen: [Emulator: String] = [:]) -> Installed {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [Emulator: Launcher] = [:]
        for (e, exe) in chosen where FileManager.default.isExecutableFile(atPath: exe) { found[e] = Launcher(exe: exe) }
        #if os(macOS)
        for e in Emulator.allCases where found[e] == nil {
            if let exe = e.installedApp().flatMap({ Bundle(url: $0)?.executableURL?.path }) { found[e] = Launcher(exe: exe) }
        }
        let cores = home.appendingPathComponent("Library/Application Support/RetroArch/cores")
        #else
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let pathDirs = (env["Path"] ?? env["PATH"] ?? "").split(separator: ";").map(String.init)
        let steam = Registry.steamPath?.replacingOccurrences(of: "/", with: "\\") ?? (env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)") + "\\Steam"
        let libraries = steamLibraries(steamFolder: steam), listed = installedProgramFolders()
        let extraDirs = { (e: Emulator) in windowsInstallDirs(for: e, env: env, steamLibraries: libraries) + (listed[e] ?? []) }
        let file = { (dir: String, name: String) in dir + "\\" + name + ".exe" }
        // Emulators that come as a zip (DuckStation, PPSSPP) run from wherever it was unpacked; Windows remembers the programs it started.
        let ran = programsRun()
        let appImages = [String]()
        #else
        let pathDirs = (env["PATH"] ?? "/usr/bin").split(separator: ":").map(String.init)
        let extraDirs = { (_: Emulator) in [String]() }
        let file = { (dir: String, name: String) in dir + "/" + name }
        // shortcut: AppImages are only looked for in ~/Applications (where EmuDeck puts them) and on PATH under the binary name
        let apps = home.path + "/Applications"
        let appImages = ((try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? []).sorted()
            .map { apps + "/" + $0 }.filter { $0.lowercased().hasSuffix(".appimage") && FileManager.default.isExecutableFile(atPath: $0) }
        let ran = [String]()
        #endif
        for e in Emulator.allCases where found[e] == nil {
            let names = Set(e.binaryNames.map { $0.lowercased() })
            let exe = (extraDirs(e) + pathDirs).lazy.flatMap { dir in e.binaryNames.lazy.map { file(dir, $0) } }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                ?? ran.first { names.contains(programName($0)) && FileManager.default.isExecutableFile(atPath: $0) }
            if let exe = exe ?? appImages.first(where: { EmulatorLaunch.match($0) == e }) {
                found[e] = Launcher(exe: exe)
            } else if let id = e.flatpakID, ["/var/lib/flatpak/app/\(id)", home.path + "/.local/share/flatpak/app/\(id)"].contains(where: FileManager.default.fileExists) {
                found[e] = Launcher(exe: "/usr/bin/flatpak", args: "run \(id)")
            }
        }
        #if os(Windows)
        let cores = URL(fileURLWithPath: found[.retroarch]?.exe ?? "C:\\RetroArch-Win64\\retroarch.exe").deletingLastPathComponent().appendingPathComponent("cores")
        #else
        // shortcut: distro-packaged cores (/usr/lib/libretro) aren't looked at, only ones RetroArch's Core Downloader fetched
        let cores = home.appendingPathComponent(found[.retroarch]?.exe == "/usr/bin/flatpak"
            ? ".var/app/org.libretro.RetroArch/config/retroarch/cores" : ".config/retroarch/cores")
        #endif
        #endif
        return Installed(emulators: found, coresDirectory: cores)
    }

    #if os(Windows)
    /// Steam's install folder plus any other library folders it lists, as paths with backslashes.
    static func steamLibraries(steamFolder: String) -> [String] {
        var libraries = [steamFolder]
        guard let vdf = try? String(contentsOfFile: steamFolder + "\\steamapps\\libraryfolders.vdf", encoding: .utf8) else { return libraries }
        for line in vdf.split(whereSeparator: \.isNewline) {
            // `"path"		"D:\\SteamLibrary"`: the value has its backslashes doubled.
            let words = line.split(separator: "\"").filter { !$0.allSatisfy(\.isWhitespace) }
            if words.count == 2, words[0] == "path" { libraries.append(words[1].replacingOccurrences(of: "\\\\", with: "\\")) }
        }
        return libraries
    }

    /// Where Windows emulators usually live besides PATH: default installers, Steam's RetroArch, EmuDeck, Scoop, and unzipped-in-place builds.
    static func windowsInstallDirs(for e: Emulator, env: [String: String], steamLibraries: [String]) -> [String] {
        var names = [e.displayName]
        if e == .dolphin { names += ["Dolphin-x64", "Dolphin Emulator"] }
        if e == .pcsx2 { names.append("PCSX2-Qt") }  // EmuDeck's folder
        var dirs: [String] = []
        if e == .retroarch {
            dirs.append("C:\\RetroArch-Win64")
            dirs += steamLibraries.map { $0 + "\\steamapps\\common\\RetroArch" }
        }
        let roots = [env["ProgramFiles"], env["ProgramFiles(x86)"], env["LOCALAPPDATA"].map { $0 + "\\Programs" },
                     env["APPDATA"].map { $0 + "\\emudeck\\Emulators" }].compactMap { $0 }
        dirs += roots.flatMap { root in names.map { root + "\\" + $0 } }
        if let profile = env["USERPROFILE"] { dirs += names.map { profile + "\\scoop\\apps\\" + $0.lowercased() + "\\current" } }
        return dirs
    }

    /// Folders from Windows' list of installed programs (Settings → Apps), for emulators installed somewhere other than the default.
    static func installedProgramFolders() -> [Emulator: [String]] {
        let list = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
        var folders: [Emulator: [String]] = [:]
        for (hive, key) in [(Registry.Hive.currentUser, list), (.localMachine, list), (.localMachine, "Software\\WOW6432Node\\" + list.dropFirst("Software\\".count))] {
            for sub in Registry.subkeys(hive, key) {
                let entry = key + "\\" + sub
                guard let e = Registry.string(hive, entry, "DisplayName").flatMap(emulator(installedAs:)) else { continue }
                folders[e, default: []] += [Registry.string(hive, entry, "InstallLocation"), Registry.string(hive, entry, "DisplayIcon").flatMap(folder(ofIcon:))]
                    .compactMap { $0 }.filter { !$0.isEmpty }
            }
        }
        return folders
    }

    /// "DuckStation", "Dolphin Emulator" or "PCSX2 - Nightly" names that emulator; "RetroArchiver" doesn't.
    static func emulator(installedAs displayName: String) -> Emulator? {
        let name = displayName.lowercased()
        return Emulator.allCases.first { e in
            let prefix = e.displayName.lowercased()
            return name.hasPrefix(prefix) && name.dropFirst(prefix.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
        }
    }

    /// The folder of an installed program's icon, `"C:\Emu\x.exe",0` → `C:\Emu`.
    static func folder(ofIcon icon: String) -> String? {
        var path = Substring(icon)
        if let comma = path.lastIndex(of: ","), path[path.index(after: comma)...].allSatisfy({ $0.isNumber || $0 == "-" }) { path = path[..<comma] }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))[...]
        return path.lastIndex(of: "\\").map { String(path[..<$0]) }
    }

    /// Programs this user has started, from two lists Windows keeps: the shell's MuiCache (`C:\Emu\x.exe.FriendlyAppName`)
    /// and the Program Compatibility Assistant's (the paths themselves).
    static func programsRun() -> [String] {
        let mui = Registry.valueNames(.currentUser, "Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\MuiCache")
        let pca = Registry.valueNames(.currentUser, "Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Compatibility Assistant\\Store")
        return (mui + pca).compactMap(exePath(inRecord:))
    }

    /// `C:\Emu\x.exe.FriendlyAppName` → `C:\Emu\x.exe`; nil when the entry isn't a program file.
    static func exePath(inRecord name: String) -> String? {
        guard let r = name.range(of: ".exe", options: [.caseInsensitive, .backwards]),
              name[r.upperBound...].isEmpty || name[r.upperBound...].hasPrefix(".") else { return nil }
        return String(name[..<r.upperBound])
    }
    #endif

    /// A program's file name as `binaryNames` lists it: lowercased, without `.exe`.
    static func programName(_ path: String) -> String {
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// The first installed core RetroArch has for a console, as a full path.
    func core(for console: Console) -> String? {
        console.cores.map { coresDirectory.appendingPathComponent("\($0)_libretro.\(Self.coreExtension)").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// The fields a Steam shortcut needs. `bundle` is what Steam's AddShortcut gets before the exe is set (an .app on macOS).
public struct ShortcutSpec: Encodable, Equatable, Sendable {
    public var name, exe, launchOptions, startDir, bundle: String
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

    #if os(macOS)
    public static let wrapsInArch = true
    #else
    public static let wrapsInArch = false
    #endif

    /// Steam on macOS launches games as x86_64, which can't load arm64 cores, so there the emulator runs through `arch -arm64`.
    public static func shortcut(for item: ScanItem, installed: Installed, wrapInArch: Bool = Scanner.wrapsInArch) -> ShortcutSpec {
        let emulator = item.emulator ?? .retroarch
        let launcher = installed.emulators[emulator] ?? Launcher(exe: "")
        let exe = launcher.exe, args = emulator.launchOptions(rom: item.romPath, coreFile: item.coreFile)
        let sep = exe.lastIndex { $0 == "/" || $0 == "\\" }
        let dir = sep.map { String(exe[...$0]) } ?? ""
        guard wrapInArch else {
            return ShortcutSpec(name: item.title, exe: "\"\(exe)\"", launchOptions: launcher.args.isEmpty ? args : "\(launcher.args) \(args)",
                                startDir: "\"\(dir)\"", bundle: exe)
        }
        let bundle = exe.range(of: ".app/").map { String(exe[..<$0.lowerBound]) + ".app" } ?? exe
        // arch is SIP-protected and strips DYLD_INSERT_LIBRARIES, which carries Steam's overlay; `env` puts it back for the emulator.
        let overlay = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib").path
        return ShortcutSpec(name: item.title, exe: "\"/usr/bin/arch\"", launchOptions: "-arm64 /usr/bin/env DYLD_INSERT_LIBRARIES=\"\(overlay)\" \"\(exe)\" " + args, startDir: "\"\(dir)\"", bundle: bundle)
    }

    /// `~/ROMs`, or EmuDeck's ROM folder when only that exists (it uses the same per-console folder names): its `romsPath`
    /// setting, which points at the SD card or another drive when EmuDeck was installed there, else `~/Emulation/roms`.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let roms = home.appendingPathComponent("ROMs")
        let settings = try? String(contentsOf: home.appendingPathComponent(".config/EmuDeck/settings.sh"), encoding: .utf8)
        let emudeck = [settings.flatMap { emuDeckRomsPath(settings: $0, home: home.path) }, home.appendingPathComponent("Emulation/roms").path]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
        if !FileManager.default.fileExists(atPath: roms.path), let emudeck { return URL(fileURLWithPath: emudeck) }
        try? FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        return roms
    }

    /// The last `romsPath=` line of EmuDeck's settings.sh, unquoted, with `~` and `$HOME` expanded.
    static func emuDeckRomsPath(settings: String, home: String) -> String? {
        guard let line = settings.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("romsPath=") }) else { return nil }
        var value = line.dropFirst("romsPath=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        if value.hasPrefix("~") { value = home + value.dropFirst() }
        value = value.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        return value.isEmpty ? nil : value
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
