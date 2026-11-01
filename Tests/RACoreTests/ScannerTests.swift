import Foundation
import Testing
@testable import RACore

struct PathHasher: Fingerprinting {
    var byFile: [String: [ConsoleHash]]
    func fingerprint(romPath: String, consoleId: Int) -> HashResult { .unsupportedFormat }
    func allFingerprints(romPath: String) -> [ConsoleHash] { byFile[(romPath as NSString).lastPathComponent] ?? [] }
}

func touch(_ root: URL, _ rel: String) {
    let url = root.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data([0]))
}

func installed(cores: [String]) -> Installed {
    let dir = tempDir()
    for c in cores { touch(dir, "\(c)_libretro.\(Installed.coreExtension)") }
    return Installed(emulators: [.retroarch: Launcher(exe: "/A/RetroArch"), .duckstation: Launcher(exe: "/A/DuckStation")], coresDirectory: dir)
}

@Test func scansFolderTree() {
    let root = tempDir()
    for f in ["snes/Super Mario World (USA).sfc", "misc/game.gbc", "psx/FF7/FF7 (Disc 1).cue", "psx/FF7/FF7 (Disc 1).bin", "psx/FF7/FF7.m3u", "notes.txt"] {
        touch(root, f)
    }
    let scanner = Scanner(installed: installed(cores: ["snes9x", "gambatte"]), hasher: PathHasher(byFile: ["game.gbc": [ConsoleHash(consoleId: 6, hash: "h")]]))
    let items = scanner.scan(folder: root, existingRomPaths: [], consoleOverrides: [:], emulatorOverrides: [:]).sorted { $0.title < $1.title }
    #expect(items.count == 3)
    let smw = items.first { $0.title == "Super Mario World" }, gbc = items.first { $0.title == "game" }, ff7 = items.first { $0.title == "FF7" }
    #expect(smw?.consoleId == 3 && smw?.emulator == .retroarch && smw?.status == .ready)
    #expect(smw?.coreFile?.hasSuffix("/snes9x_libretro.\(Installed.coreExtension)") == true)
    #expect(gbc?.consoleId == 6 && gbc?.emulator == .retroarch && gbc?.coreFile?.hasSuffix("/gambatte_libretro.\(Installed.coreExtension)") == true,
            "gbc: \(String(describing: gbc)); root: \(root.path); items: \(items.map(\.romPath))")
    #expect(ff7?.consoleId == 12 && ff7?.emulator == .duckstation && ff7?.status == .ready)
}

@Test func existingPathIsAlreadyInSteam() {
    let root = tempDir()
    touch(root, "snes/a.sfc")
    let path = root.appendingPathComponent("snes/a.sfc").path
    let items = Scanner(installed: installed(cores: ["snes9x"]), hasher: PathHasher(byFile: [:]))
        .scan(folder: root, existingRomPaths: [path], consoleOverrides: [:], emulatorOverrides: [:])
    #expect(items.first?.status == .alreadyInSteam)
}

@Test func ambiguousFileAsksForConsole() {
    let root = tempDir()
    touch(root, "misc/game.bin")
    let hasher = PathHasher(byFile: ["game.bin": [ConsoleHash(consoleId: 1, hash: "a"), ConsoleHash(consoleId: 12, hash: "b")]])
    let scanner = Scanner(installed: installed(cores: ["genesis_plus_gx"]), hasher: hasher)
    #expect(scanner.scan(folder: root, existingRomPaths: [], consoleOverrides: [:], emulatorOverrides: [:]).first?.status == .chooseConsole)
    let fixed = scanner.scan(folder: root, existingRomPaths: [], consoleOverrides: [root.appendingPathComponent("misc").path: 1], emulatorOverrides: [:])
    #expect(fixed.first?.consoleId == 1)
    #expect(fixed.first?.status == .ready)
}

@Test func missingCoreNamesIt() {
    let root = tempDir()
    touch(root, "n64/game.z64")
    let items = Scanner(installed: installed(cores: []), hasher: PathHasher(byFile: [:]))
        .scan(folder: root, existingRomPaths: [], consoleOverrides: [:], emulatorOverrides: [:])
    #expect(items.first?.status == .noEmulator("In RetroArch, open Online Updater → Core Downloader and get mupen64plus_next."))
}

@Test func shortcutLaunchOptions() {
    let inst = installed(cores: ["snes9x"])
    let item = ScanItem(romPath: "/r/snes/Super Mario World (USA).sfc", title: "Super Mario World", consoleId: 3, emulator: .retroarch,
                        coreFile: inst.coresDirectory.appendingPathComponent("snes9x_libretro.dylib").path, status: .ready)
    let s = Scanner.shortcut(for: item, installed: inst, wrapInArch: true)
    // Steam on macOS launches games as x86_64; arch -arm64 keeps emulators native so arm64 cores load.
    #expect(s.exe == "\"/usr/bin/arch\"")
    #expect(s.launchOptions == "-arm64 \"/A/RetroArch\" -L \"\(inst.coresDirectory.path)/snes9x_libretro.dylib\" \"/r/snes/Super Mario World (USA).sfc\"")
    #expect(s.bundle == "/A/RetroArch")
    #expect(s.name == "Super Mario World")
}

@Test func shortcutWithoutArch() {
    let inst = Installed(emulators: [.retroarch: Launcher(exe: "/usr/bin/flatpak", args: "run org.libretro.RetroArch")], coresDirectory: tempDir())
    let item = ScanItem(romPath: "/r/nes/a.nes", title: "a", consoleId: 7, emulator: .retroarch, coreFile: "/c/mesen_libretro.so", status: .ready)
    let s = Scanner.shortcut(for: item, installed: inst, wrapInArch: false)
    #expect(s.exe == "\"/usr/bin/flatpak\"")
    #expect(s.launchOptions == "run org.libretro.RetroArch -L \"/c/mesen_libretro.so\" \"/r/nes/a.nes\"")
    #expect(s.startDir == "\"/usr/bin/\"" && s.bundle == "/usr/bin/flatpak")
    // The shortcut reads back as the same emulator, core and ROM.
    #expect(EmulatorLaunch.parse(exe: s.exe, launchOptions: s.launchOptions) == EmulatorLaunch(emulator: .retroarch, coreFile: "/c/mesen_libretro.so", romPath: "/r/nes/a.nes"))
}

#if os(Windows)
@Test func steamLibrariesComeFromLibraryFolders() throws {
    let steam = tempDir()
    try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
    let vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\SteamLibrary\"\n\t}\n}\n"
    try vdf.write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
    let libs = Installed.steamLibraries(steamFolder: steam.path.replacingOccurrences(of: "/", with: "\\"))
    #expect(libs.count == 3 && libs.last == "D:\\SteamLibrary")
}

@Test func windowsInstallDirsCoverSteamAndDolphin() {
    let env = ["ProgramFiles": "C:\\Program Files", "ProgramFiles(x86)": "C:\\Program Files (x86)", "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local", "USERPROFILE": "C:\\Users\\u"]
    let ra = Installed.windowsInstallDirs(for: .retroarch, env: env, steamLibraries: ["D:\\SteamLibrary"])
    #expect(ra.contains("D:\\SteamLibrary\\steamapps\\common\\RetroArch") && ra.contains("C:\\RetroArch-Win64") && ra.contains("C:\\Program Files (x86)\\RetroArch"))
    let dolphin = Installed.windowsInstallDirs(for: .dolphin, env: env, steamLibraries: [])
    #expect(dolphin.contains("C:\\Program Files\\Dolphin-x64") && dolphin.contains("C:\\Users\\u\\scoop\\apps\\dolphin\\current"))
}
#endif
