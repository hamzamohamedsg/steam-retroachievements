import Testing
@testable import RACore

let raExe = "\"/Applications/RetroArch.app/Contents/MacOS/RetroArch\""

@Test func parsesQuotedPaths() {
    #expect(EmulatorLaunch.parse(exe: raExe, launchOptions: "-L \"/Users/u/Library/Application Support/RetroArch/cores/snes9x_libretro.dylib\" \"/Users/u/ROMs/snes/Super Mario World (USA).sfc\"")
        == EmulatorLaunch(emulator: .retroarch, coreFile: "/Users/u/Library/Application Support/RetroArch/cores/snes9x_libretro.dylib", romPath: "/Users/u/ROMs/snes/Super Mario World (USA).sfc"))
}

@Test func parsesOpenDashA() {
    let l = EmulatorLaunch.parse(exe: "/usr/bin/open", launchOptions: "-a RetroArch --args -L \"/c/mgba_libretro.dylib\" \"/r/Pokémon - Red Version (USA, Europe).gb\"")
    #expect(l == EmulatorLaunch(emulator: .retroarch, coreFile: "/c/mgba_libretro.dylib", romPath: "/r/Pokémon - Red Version (USA, Europe).gb"))
}

@Test func parsesAppBundleExe() {
    #expect(EmulatorLaunch.parse(exe: "\"/Applications/RetroArch.app\"", launchOptions: "-L x_libretro.dylib \"/r/a b.nes\"")?.romPath == "/r/a b.nes")
}

@Test func parsesFlagsAndEscapes() {
    let l = EmulatorLaunch.parse(exe: raExe, launchOptions: "--libretro=/c/fceumm_libretro.dylib /r/My\\ Game.nes")
    #expect(l?.coreFile == "/c/fceumm_libretro.dylib")
    #expect(l?.romPath == "/r/My Game.nes")
}

@Test func skipsConfigValue() {
    #expect(EmulatorLaunch.parse(exe: raExe, launchOptions: "-c \"/x/retroarch.cfg\" -L '/c/a_libretro.dylib' '/r/g.sfc'")?.romPath == "/r/g.sfc")
}

@Test func retroArchWithoutRom() {
    #expect(EmulatorLaunch.parse(exe: raExe, launchOptions: "") == EmulatorLaunch(emulator: .retroarch, coreFile: nil, romPath: nil))
}

@Test func parsesStandalone() {
    #expect(EmulatorLaunch.parse(exe: "\"/Applications/DuckStation.app/Contents/MacOS/DuckStation\"", launchOptions: "-batch -- \"/r/psx/Crash (USA).cue\"")?.romPath == "/r/psx/Crash (USA).cue")
    #expect(EmulatorLaunch.parse(exe: "\"/Applications/Dolphin.app/Contents/MacOS/Dolphin\"", launchOptions: "-b -e \"/r/gc/Melee.iso\"")?.emulator == .dolphin)
    #expect(EmulatorLaunch.parse(exe: "\"/Applications/Dolphin.app/Contents/MacOS/Dolphin\"", launchOptions: "-b -e \"/r/gc/Melee.iso\"")?.romPath == "/r/gc/Melee.iso")
}

@Test func otherAppIsNotEmulator() {
    #expect(EmulatorLaunch.parse(exe: "\"/System/Applications/Calculator.app\"", launchOptions: "") == nil)
}

@Test func cleansTitles() {
    #expect(Titles.clean("Super Mario World (USA) [!].sfc") == "Super Mario World")
    #expect(Titles.clean("/r/Pokémon - Red Version (USA, Europe).gb") == "Pokémon - Red Version")
    #expect(Titles.clean("Final Fantasy VII (Disc 1).cue") == "Final Fantasy VII")
    #expect(Titles.clean("Dr. Mario") == "Dr. Mario")
    #expect(Titles.clean("Super Mario Bros. 3") == "Super Mario Bros. 3")
}

@Test func titleKeys() {
    #expect(Titles.key("The Legend of Zelda: A Link to the Past") == Titles.key("Legend of Zelda, The - A Link to the Past"))
    #expect(Titles.key("~Homebrew~ Tobu Tobu Girl") == Titles.key("Tobu Tobu Girl"))
    #expect(Titles.key("Sonic & Knuckles") == Titles.key("Sonic and Knuckles"))
    #expect(Titles.key("Pokémon Red") == "pokemonred")
}

@Test func consoleLookups() {
    #expect(Consoles.forFolder("SNES")?.id == 3)
    #expect(Consoles.forCore(file: "/c/snes9x_libretro.dylib").map(\.id) == [3])
    #expect(Consoles.candidates(emulator: .retroarch, coreFile: "genesis_plus_gx_libretro.dylib", fingerprints: [ConsoleHash(consoleId: 9, hash: "h")]) == [9])
    #expect(Consoles.candidates(emulator: .retroarch, coreFile: nil, fingerprints: [ConsoleHash(consoleId: 6, hash: "h")]) == [6])
    #expect(Consoles.candidates(emulator: .dolphin, coreFile: nil, fingerprints: [ConsoleHash(consoleId: 19, hash: "h")]) == [19])
    #expect(Consoles.byID(12)?.name == "PlayStation")
}

@Test func parsesArchWrapper() {
    let l = EmulatorLaunch.parse(exe: "\"/usr/bin/arch\"", launchOptions: "-arm64 \"/Applications/RetroArch.app/Contents/MacOS/RetroArch\" -L \"/c/fceumm_libretro.dylib\" \"/r/nes/From Below.nes\"")
    #expect(l == EmulatorLaunch(emulator: .retroarch, coreFile: "/c/fceumm_libretro.dylib", romPath: "/r/nes/From Below.nes"))
    #expect(EmulatorLaunch.parse(exe: "\"/usr/bin/arch\"", launchOptions: "-arm64 \"/System/Applications/Calculator.app/Contents/MacOS/Calculator\"") == nil)
}
