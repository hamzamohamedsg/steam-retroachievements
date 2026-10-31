import Foundation

/// The RetroAchievements emulators that have a macOS build and load ROM files.
public enum Emulator: String, Codable, CaseIterable, Sendable {
    case retroarch, duckstation, pcsx2, ppsspp, dolphin, flycast, skyemu

    public var displayName: String {
        switch self {
        case .retroarch: "RetroArch"
        case .duckstation: "DuckStation"
        case .pcsx2: "PCSX2"
        case .ppsspp: "PPSSPP"
        case .dolphin: "Dolphin"
        case .flycast: "Flycast"
        case .skyemu: "SkyEmu"
        }
    }

    public var appNames: [String] {
        switch self {
        case .ppsspp: ["PPSSPPSDL", "PPSSPP"]
        default: [displayName]
        }
    }

    /// Empty for RetroArch, whose console comes from the core.
    public var consoles: [Int] {
        switch self {
        case .retroarch: []
        case .duckstation: [12]
        case .pcsx2: [21]
        case .ppsspp: [41]
        case .dolphin: [16, 19]
        case .flycast: [40, 27]
        case .skyemu: [4, 6, 5]
        }
    }

    public func launchOptions(rom: String, coreFile: String?) -> String {
        switch self {
        case .retroarch: "-L \"\(coreFile ?? "")\" \"\(rom)\""
        case .duckstation, .pcsx2: "-batch -- \"\(rom)\""
        case .dolphin: "-b -e \"\(rom)\""
        case .ppsspp, .flycast, .skyemu: "\"\(rom)\""
        }
    }
}

public struct EmulatorLaunch: Equatable, Sendable {
    public let emulator: Emulator
    public let coreFile: String?
    public let romPath: String?

    public init(emulator: Emulator, coreFile: String?, romPath: String?) {
        self.emulator = emulator; self.coreFile = coreFile; self.romPath = romPath
    }

    // shortcut: flag list covers common emulator flags; add any that show up in real shortcuts
    static let flagsWithValue: Set<String> = ["-L", "--libretro", "-c", "--config", "--appendconfig", "-s", "--save",
                                              "-S", "--savestate", "--subsystem", "--log-file", "-a", "-e", "--exec"]

    /// nil when the shortcut doesn't launch a supported emulator.
    public static func parse(exe: String, launchOptions: String) -> EmulatorLaunch? {
        parse(exePath: tokenize(exe).first ?? exe, args: tokenize(launchOptions))
    }

    static func parse(exePath: String, args: [String]) -> EmulatorLaunch? {
        var args = args
        // `arch -arm64 <emulator> …`: Steam on macOS launches games as x86_64, so shortcuts wrap emulators in arch.
        if (exePath as NSString).lastPathComponent == "arch" {
            guard let i = args.firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
            return parse(exePath: args[i], args: Array(args[(i + 1)...]))
        }
        let emulator: Emulator
        if ["open", "/usr/bin/open"].contains(exePath) {
            guard let i = args.firstIndex(where: { $0 == "-a" }), i + 1 < args.count, let e = match(args[i + 1]) else { return nil }
            emulator = e
            args = args.firstIndex(of: "--args").map { Array(args[($0 + 1)...]) } ?? []
        } else {
            guard let e = match(exePath) else { return nil }
            emulator = e
        }

        var core: String?, rom: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                if i + 1 < args.count { rom = args[i + 1] }
                break
            } else if a.hasPrefix("--libretro=") {
                core = String(a.dropFirst("--libretro=".count))
            } else if a.hasPrefix("--exec=") {
                rom = String(a.dropFirst("--exec=".count))
            } else if flagsWithValue.contains(a) {
                if (a == "-L" || a == "--libretro"), i + 1 < args.count { core = args[i + 1] }
                if (a == "-e" || a == "--exec"), i + 1 < args.count { rom = args[i + 1] }  // Dolphin: -e <rom>
                i += 1
            } else if !a.hasPrefix("-") {
                rom = a
            }
            i += 1
        }
        return EmulatorLaunch(emulator: emulator, coreFile: core, romPath: rom)
    }

    /// An exe or `open -a` value names emulator E if it ends in `/<app>` or `/<app>.app`, or contains `<app>.app/`.
    static func match(_ path: String) -> Emulator? {
        let p = path.lowercased()
        return Emulator.allCases.first { e in
            e.appNames.map { $0.lowercased() }.contains { app in
                p == app || p.hasSuffix("/\(app)") || p.hasSuffix("/\(app).app") || p.contains("\(app).app/") || p == "\(app).app"
            }
        }
    }

    /// Shell-style splitting: double quotes, single quotes and backslash escapes.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = [], current = "", inToken = false
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; inToken = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inToken = true; continue }
            if ch.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch); inToken = true
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
