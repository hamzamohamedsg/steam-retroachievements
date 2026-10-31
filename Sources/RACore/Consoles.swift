import Foundation
import rcheevos

/// A RetroAchievements console (ids match rcheevos' RC_CONSOLE_* and the RA API).
public struct Console: Equatable, Sendable {
    public let id: Int
    public let folders: [String]
    /// RetroArch cores without the `_libretro.dylib` suffix, default first.
    public let cores: [String]
    public var name: String { String(cString: rc_console_name(UInt32(id))) }
}

public enum Consoles {
    // Consoles with no libretro core on macOS are left out: nothing can launch them.
    public static let all: [Console] = [
        (1, ["genesis", "megadrive", "md"], ["genesis_plus_gx", "picodrive"]),
        (2, ["n64"], ["mupen64plus_next", "parallel_n64"]),
        (3, ["snes", "sfc", "superfamicom"], ["snes9x", "bsnes", "mesen-s"]),
        (4, ["gb"], ["gambatte", "sameboy", "mgba", "gearboy"]),
        (5, ["gba"], ["mgba", "vbam", "gpsp"]),
        (6, ["gbc"], ["gambatte", "sameboy", "mgba", "gearboy"]),
        (7, ["nes", "famicom", "fc"], ["mesen", "fceumm", "nestopia"]),
        (8, ["pce", "pcengine", "tg16"], ["mednafen_pce_fast", "mednafen_pce"]),
        (9, ["segacd", "megacd"], ["genesis_plus_gx", "picodrive"]),
        (10, ["sega32x", "32x"], ["picodrive"]),
        (11, ["mastersystem", "sms"], ["genesis_plus_gx", "picodrive", "gearsystem"]),
        (12, ["psx", "ps1", "playstation"], ["swanstation", "mednafen_psx_hw", "pcsx_rearmed"]),
        (13, ["lynx"], ["handy", "mednafen_lynx"]),
        (14, ["ngp", "ngpc"], ["mednafen_ngp", "race"]),
        (15, ["gamegear", "gg"], ["genesis_plus_gx", "gearsystem"]),
        (16, ["gamecube", "gc", "ngc"], ["dolphin"]),
        (17, ["jaguar"], ["virtualjaguar"]),
        (18, ["nds"], ["melondsds", "melonds", "desmume"]),
        (19, ["wii"], ["dolphin"]),
        (21, ["ps2"], ["pcsx2"]),
        (23, ["odyssey2", "videopac"], ["o2em"]),
        (24, ["pokemini"], ["pokemini"]),
        (25, ["atari2600"], ["stella", "stella2014"]),
        (26, ["dos", "msdos"], ["dosbox_pure"]),
        (27, ["arcade", "fbneo", "mame", "neogeo", "naomi", "atomiswave"], ["fbneo", "mame2003_plus", "mame"]),
        (28, ["virtualboy", "vb"], ["mednafen_vb"]),
        (29, ["msx", "msx2"], ["bluemsx", "fmsx"]),
        (30, ["c64"], ["vice_x64sc"]),
        (31, ["zx81"], ["81"]),
        (33, ["sg1000"], ["genesis_plus_gx", "gearsystem"]),
        (34, ["vic20"], ["vice_xvic"]),
        (35, ["amiga"], ["puae"]),
        (36, ["atarist"], ["hatari"]),
        (37, ["amstradcpc", "cpc"], ["cap32", "crocods"]),
        (39, ["saturn"], ["mednafen_saturn", "yabause", "kronos"]),
        (40, ["dreamcast", "dc"], ["flycast"]),
        (41, ["psp"], ["ppsspp"]),
        (42, ["cdi"], ["same_cdi"]),
        (43, ["3do"], ["opera"]),
        (44, ["colecovision", "coleco"], ["gearcoleco", "bluemsx"]),
        (45, ["intellivision"], ["freeintv"]),
        (46, ["vectrex"], ["vecx"]),
        (47, ["pc88"], ["quasi88"]),
        (48, ["pc98"], ["np2kai"]),
        (49, ["pcfx"], ["mednafen_pcfx"]),
        (50, ["atari5200"], ["a5200", "atari800"]),
        (51, ["atari7800"], ["prosystem"]),
        (52, ["x68000"], ["px68k"]),
        (53, ["wonderswan", "ws", "wsc"], ["mednafen_wswan"]),
        (56, ["neogeocd"], ["neocd"]),
        (57, ["channelf"], ["freechaf"]),
        (59, ["zxspectrum"], ["fuse"]),
        (60, ["gameandwatch"], ["gw"]),
        (62, ["3ds"], ["citra"]),
        (63, ["supervision"], ["potator"]),
        (64, ["x1"], ["x1"]),
        (65, ["tic80"], ["tic80"]),
        (66, ["to8", "thomson"], ["theodore"]),
        (68, ["pico"], ["picodrive"]),
        (69, ["megaduck"], ["sameduck"]),
        (71, ["arduboy"], ["arduous"]),
        (72, ["wasm4"], ["wasm4"]),
        (76, ["pcenginecd", "pcecd", "tgcd"], ["mednafen_pce_fast", "mednafen_pce"]),
        (77, ["jaguarcd"], ["virtualjaguar"]),
        (78, ["dsi"], ["melondsds"]),
        (79, ["ti83"], ["numero"]),
        (80, ["uzebox"], ["uzem"]),
        (81, ["fds"], ["mesen", "fceumm", "nestopia"]),
    ].map { Console(id: $0.0, folders: $0.1, cores: $0.2) }

    public static func byID(_ id: Int) -> Console? { all.first { $0.id == id } }

    public static func forFolder(_ folderName: String) -> Console? {
        let name = folderName.lowercased()
        return all.first { $0.folders.contains(name) }
    }

    /// Every console listing this core. Accepts a full path or a bare `x_libretro.dylib` name.
    public static func forCore(file: String) -> [Console] {
        let core = URL(fileURLWithPath: file).lastPathComponent
            .replacingOccurrences(of: "_libretro.dylib", with: "")
            .replacingOccurrences(of: ".dylib", with: "")
        return all.filter { $0.cores.contains(core) }
    }

    /// Consoles to try for a ROM: the emulator's own consoles narrowed by rcheevos' extension-based
    /// candidates; the emulator's alone if they don't overlap; the fingerprints' if the emulator says nothing.
    public static func candidates(emulator: Emulator, coreFile: String?, fingerprints: [ConsoleHash]) -> [Int] {
        let own = emulator == .retroarch ? (coreFile.map { forCore(file: $0).map(\.id) } ?? []) : emulator.consoles
        let fromHashes = fingerprints.map(\.consoleId)
        let both = own.filter(fromHashes.contains)
        if !both.isEmpty { return both }
        return own.isEmpty ? fromHashes : own
    }
}
