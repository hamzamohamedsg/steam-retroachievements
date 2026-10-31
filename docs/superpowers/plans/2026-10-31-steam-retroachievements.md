# Steam RetroAchievements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app that draws a Steam-styled RetroAchievements panel on the Steam library pages of emulator shortcuts (RetroArch and six standalone emulators) and can add those games to Steam.

**Architecture:**
- A Swift/SwiftUI menu bar app (`Steam RetroAchievements.app`) does all the file reading, ROM fingerprinting (vendored rcheevos), RetroAchievements API calls, caching, and Keychain storage.
- It connects to Steam's Chrome DevTools Protocol (CDP) port, injects one plain-JavaScript file (`steam/inject.js`) into `SharedJSContext`, and talks to it over a CDP binding.
- The script only draws what the app sends it.

**Tech Stack:** Swift 6.3 and SwiftUI as a Swift Package built with Command Line Tools only, Swift Testing, rcheevos v12.5.0 (C), `URLSessionWebSocketTask`, Security (Keychain), ServiceManagement (login item), plain JavaScript in Steam's browser engine, and Node 22 for one dev script.

**Spec:** `docs/superpowers/specs/2026-10-30-steam-retroachievements-design.md`

## Global Constraints

- **Build:** Command Line Tools only, using `swift build` and `swift test`. Tests use Swift Testing (`import Testing`), because XCTest isn't installed. No Xcode project.
- **Package:** `SteamRetroAchievements`, `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`. All testable logic lives in library target `RACore`.
- **rcheevos:** tag `v12.5.0`, vendored in `Vendor/rcheevos/` with its LICENSE. The C target must be named `rcheevos`, because its bundled `module.modulemap` declares that module name.
- **App:** `~/Applications/Steam RetroAchievements.app`, bundle id `local.steam-retroachievements`, `LSUIElement` true, signed ad-hoc.
- **Paths:**
  - Marker: `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging`
  - Data: `~/Library/Application Support/steam-retroachievements/`, containing `cache/` and `matches.json`
  - Log: `~/Library/Logs/steam-retroachievements.log`
  - Keychain service: `steam-retroachievements`
  - Default ROM folder: `~/ROMs`
- **Steam:**
  - CDP target list at `http://127.0.0.1:8080/json`; the target titled `SharedJSContext` runs Steam's UI.
  - Non-Steam shortcuts have `app_type` `1073741824`.
- **RetroAchievements:**
  - API base `https://retroachievements.org/API/`; media `https://media.retroachievements.org`.
  - Badges at `/Badge/<BadgeName>.png`, locked look at `/Badge/<BadgeName>_lock.png`.
  - Game page `https://retroachievements.org/game/<id>`.
  - Game lists are cached for 7 days. The panel refreshes 10 s after an emulator shortcut stops. HTTP timeout is 15 s.
- **Emulators** (spec Goal 7): RetroArch, DuckStation, PCSX2, PPSSPP, Dolphin, Flycast, and SkyEmu. No others.
- **Privacy and safety:**
  - The API key goes only to retroachievements.org. Nothing sent to Steam contains it.
  - The app opens no network port.
  - The app quits or restarts Steam only from the Restart Steam button, after the user confirms.
- **No Terminal for the user:** every user step happens in a window.
- **Threads:** ROM hashing and network calls never run on the main actor.
- **Never break Steam:** every entry point in `steam/inject.js` runs inside `safe()`, which is a try/catch that logs through the bridge. No exception ever reaches Steam's code.
- **Copy:** exact strings are pinned in Task 6 (panel) and Task 8 (menu and Settings).
- **Commits:** the user's rule is one commit per request, so tasks don't commit. Task 13 makes the single commit after everything is verified.
- **Downloads:** rcheevos, achievement-companion's CSS, the emulators, and a homebrew test ROM are each downloaded only after the user approves that download in chat.

## Review Focus

These are failure modes no unit test exercises. Each one is checked in the task named.

1. **Steam re-renders the game page and removes the panel:** the 500 ms heartbeat puts it back (Task 11 Step 5).
2. **Quickly switching between two games:** a late reply for the previous game is never drawn on the new one (Task 11 Step 5).
3. **Steam, its web helper, or the app restarts:** the app re-injects, and the page shows exactly one panel (Task 11 Step 6, Task 7 `decideRules`).
4. **RetroAchievements is down, slow, or returns 429/5xx:** the panel shows cached data with "Last updated …" or "Couldn't reach RetroAchievements.", never an endless spinner (Task 10 `fetchFailureFallsBackToCache`).
5. **Names and paths with spaces, quotes, accents, or dots** (`Pokémon - Red Version (USA, Europe).gb`, `Dr. Mario`, `My\ Game.nes`): parsing and cleaning keep them intact (Task 3 tests).

---

### Task 1: Repository and Steam internals check

**Files:**
- Create: `.gitignore`, `scripts/steam-eval.mjs`, `docs/steam-internals.md`

**Interfaces:**
- Produces: `node scripts/steam-eval.mjs '<js>'`
  - Evaluates the expression in `SharedJSContext` (`Runtime.evaluate` with `awaitPromise: true` and `returnByValue: true`) and prints the value as JSON.
  - Times out after 5 s and exits with code 1 on error.
  - `--binding-test` adds binding `__sra_probe`, calls `__sra_probe("ok")` in the page, and prints the `Runtime.bindingCalled` payload.
- Produces: `docs/steam-internals.md`, with one section per question Q1–Q12 below. Each section records the exact expression that worked on this Mac and a trimmed sample result. Later tasks use these answers instead of guesses.

- [ ] **Step 1:** Run `git init`. Write `.gitignore` with `.build/`, `build/`, `.DS_Store`.
- [ ] **Step 2:** Create the empty marker file. Run `open -a Steam` and wait for the library window. If Steam asks for a login, ask the user to log in.
- [ ] **Step 3:** Run `curl -s http://127.0.0.1:8080/json`. Expected: a list with an entry titled `SharedJSContext` that has a `webSocketDebuggerUrl`. **If it doesn't answer, stop the plan and report to the user.**
- [ ] **Step 4:** Write `scripts/steam-eval.mjs` with Node 22's built-in `fetch` and `WebSocket` (no dependencies). Check: `node scripts/steam-eval.mjs '1+1'` prints `2`.
- [ ] **Step 5:** Answer each question below and record the result. Starting points come from `otowm/achievement-companion` on Windows and may differ on Mac.
  - **Q1:** Steam's bundle id (`osascript -e 'id of app "Steam"'`, expected `com.valvesoftware.steam`).
  - **Q2:** an expression that returns the desktop library window's `document` from `SharedJSContext`. Try the `g_PopupManager` popup named `SP Desktop_uid0`, then its `.m_popup.document`.
  - **Q3:** the current route. Expected: `MainWindowBrowserManager.m_lastLocation.pathname` equals `/library/app/<appid>` on a game page.
  - **Q4:** for a shortcut's appid:
    - Confirm `appStore.GetAppOverviewByAppID(id)` returns `display_name` and `app_type`.
    - Find where exe, launch options, and start dir are read. Try the `strShortcutExe`, `strShortcutLaunchOptions`, and `strShortcutStartDir` fields of `appDetailsStore.GetAppDetails(id)`.
    - Note whether details first need `SteamClient.Apps.RegisterForAppDetails`.
  - **Q5:** an expression that lists every non-Steam shortcut with its appid, name, exe, and launch options.
  - **Q6:** `SteamClient.Apps.AddShortcut` argument order and return value, the setters for name, exe, launch options, and start dir, and `RemoveShortcut`.
    - Add the **test shortcut**: name `Super Mario Bros.`, exe `"/Applications/RetroArch.app/Contents/MacOS/RetroArch"`, launch options `-L "/Users/<you>/Library/Application Support/RetroArch/cores/fceumm_libretro.dylib" "/Users/<you>/ROMs/nes/Super Mario Bros. (World).nes"`.
    - Record its appid and the exact exe and launch-option strings Steam stores. Keep this shortcut until Task 13.
  - **Q7:** that `SteamClient.GameSessions.RegisterForAppLifetimeNotifications` exists, the callback's argument shape (`unAppID`, `bRunning`), and how to unregister.
  - **Q8:** on the test shortcut's page, find where to insert the panel: the right column where Steam games show achievements, else below the play bar. Also find the area around the library's "Add a Game" button.
    - Get readable class-map keys for both from Steam's webpack modules: push a chunk to `webpackChunksteamui` to get `__webpack_require__`, then scan `.c` for exports whose values are all class-name strings.
    - Record a working `findClass(key)` expression and the keys.
  - **Q9:** Steam's font family and the colors and sizes its achievements block uses (computed styles on a Steam game's achievements section). Note any CSS variables.
  - **Q10:** insert `<img src="https://media.retroachievements.org/Badge/250336.png">` into the desktop document. Record whether it loads (`naturalWidth > 0`) or is blocked.
  - **Q11:** `node scripts/steam-eval.mjs --binding-test` prints `ok`.
  - **Q12:** open Big Picture mode and record how to get its window's document, its game-page route, and an insertion point on a shortcut's game page.
- [ ] **Step 6:** Check that every question has an expression and a result. List any unanswered ones at the top under "Open", with what was tried.

### Task 2: Package, vendored rcheevos, ROM fingerprints

**Files:**
- Create: `Package.swift`
- Create: `Vendor/rcheevos/`, copied from tag v12.5.0: `include/`, `src/rhash/`, `src/rc_compat.c`, `src/rc_compat.h`, `src/rcheevos/consoleinfo.c`, `LICENSE`
- Create: `Sources/RACore/RomHasher.swift`
- Test: `Tests/RACoreTests/RomHasherTests.swift`, `Tests/RACoreTests/TestSupport.swift`

**Interfaces:**
- Produces, in module `RACore`:

```swift
public enum Unreadable: Equatable, Sendable { case missing, blocked }
public enum HashResult: Equatable, Sendable { case hash(String), unsupportedFormat, unreadable(Unreadable) }
public struct ConsoleHash: Equatable, Sendable { public let consoleId: Int; public let hash: String }
public protocol Fingerprinting: Sendable {
  func fingerprint(romPath: String, consoleId: Int) -> HashResult
  func allFingerprints(romPath: String) -> [ConsoleHash]
}
public struct RomHasher: Fingerprinting { public init() }
```

- Produces: `import rcheevos` works from Swift, including `rc_console_name`.
- Produces in `TestSupport.swift`:
  - `tempDir() -> URL`: a fresh folder under the temp directory.
  - `md5(_ d: Data) -> String`: uses CryptoKit `Insecure.MD5`, lowercase hex.
  - `let payload`: 32 768 bytes where byte `i` is `i % 251`.
  - `writeNES(_ dir: URL, _ name: String = "game.nes") -> URL`: writes `"NES\u{1A}"`, then 12 zero bytes, then `payload`.

- [ ] **Step 1:** Ask the user to approve a shallow clone of `https://github.com/RetroAchievements/rcheevos` at tag `v12.5.0` (about 5 MB) into the scratchpad. Copy the files listed above into `Vendor/rcheevos/`.
- [ ] **Step 2:** Write `Package.swift` with three targets:
  - `rcheevos` (C): `path: "Vendor/rcheevos"`, `sources: ["src/rhash", "src/rc_compat.c", "src/rcheevos/consoleinfo.c"]`, `publicHeadersPath: "include"`.
  - `RACore`: depends on `rcheevos`.
  - Test target `RACoreTests`: depends on `RACore`, with `resources: [.copy("Fixtures")]`. Create an empty `Fixtures/.keep` file.
- [ ] **Step 3:** Write the failing tests:

```swift
@Test func nesHeaderIsSkipped()       { #expect(RomHasher().fingerprint(romPath: writeNES(tempDir()).path, consoleId: 7) == .hash(md5(payload))) }
@Test func zipContentsAreHashed()     // `/usr/bin/zip -j -q game.zip game.nes` → console 7 → .hash(md5(payload))
@Test func arcadeUsesFileName()       // any bytes at <dir>/sf2.zip, console 27 → .hash(md5(Data("sf2".utf8)))
@Test func m3uFollowsFirstEntry()     // game.m3u containing "game.nes\n" beside game.nes, console 7 → .hash(md5(payload))
@Test func chdIsUnsupported()         // 1 KiB at <dir>/x.chd, console 12 → .unsupportedFormat
@Test func missingFileIsMissing()     // console 7 → .unreadable(.missing)
@Test func unreadableFileIsBlocked()  // writeNES then chmod 000 → .unreadable(.blocked)
@Test func allFingerprintsIncludesNES() // allFingerprints contains ConsoleHash(consoleId: 7, hash: md5(payload))
```

- [ ] **Step 4:** Run `swift test --filter RomHasherTests`. Expected: build fails because `RomHasher` doesn't exist yet.
- [ ] **Step 5:** Implement `RomHasher`:
  - Open the file with `open(2)` first. `ENOENT` → `.unreadable(.missing)`; `EACCES` or `EPERM` → `.unreadable(.blocked)`.
  - Extensions `chd` and `7z` → `.unsupportedFormat`.
  - `.zip` when the console isn't 27 (arcade) or 26 (MS-DOS):
    - Get the first file entry with `/usr/bin/unzip -Z1` and its bytes with `/usr/bin/unzip -p`, using `Process`.
    - Hash with `rc_hash_initialize_iterator(&it, innerName, bytes, count)` and then `rc_hash_generate`.
    - Comment `// shortcut: hashes the first file in the zip; upgrade if multi-file zips show up`.
  - Everything else: `rc_hash_initialize_iterator(&it, path, nil, 0)`, then `rc_hash_generate(&hash, UInt32(consoleId), &it)`. Always call `rc_hash_destroy_iterator`. rcheevos fills in its default file and disc readers by itself. A zero return → `.unsupportedFormat`.
  - `allFingerprints`:
    - Loop `rc_hash_iterate`. After each success, the console is `it.consoles[it.index - 1]`, a fixed-size C array read with `withUnsafeBytes`.
    - Do the same pre-checks and zip handling. Unreadable or unsupported files → `[]`.
  - If `m3uFollowsFirstEntry` fails, rcheevos isn't following the playlist. In that case resolve the first non-comment line relative to the `.m3u` folder before hashing.
- [ ] **Step 6:** Run `swift test --filter RomHasherTests`. Expected: all pass. If the link step reports undefined `_rc_*` symbols, find the v12.5.0 file that defines each one (`grep -l` in the clone), add it to `sources`, and rerun.

### Task 3: Consoles, emulators, launch parsing, titles

**Files:**
- Create: `Sources/RACore/Consoles.swift`, `Sources/RACore/Emulators.swift`, `Sources/RACore/Titles.swift`
- Test: `Tests/RACoreTests/ParsingTests.swift`

**Interfaces:**
- Consumes: `ConsoleHash` (Task 2); `rc_console_name` from `rcheevos`.
- Produces:

```swift
public struct Console: Equatable, Sendable { public let id: Int; public let folders: [String]; public let cores: [String]; public var name: String }  // name = rc_console_name(id)
public enum Consoles {
  public static let all: [Console]
  public static func byID(_ id: Int) -> Console?
  public static func forFolder(_ folderName: String) -> Console?      // case-insensitive
  public static func forCore(file: String) -> [Console]               // a path or "x_libretro.dylib"
  public static func candidates(emulator: Emulator, coreFile: String?, fingerprints: [ConsoleHash]) -> [Int]
}
public enum Emulator: String, Codable, CaseIterable, Sendable {
  case retroarch, duckstation, pcsx2, ppsspp, dolphin, flycast, skyemu
  public var displayName: String          // "RetroArch", "DuckStation", "PCSX2", "PPSSPP", "Dolphin", "Flycast", "SkyEmu"
  public var appNames: [String]           // bundle names to find under /Applications and ~/Applications
  public var consoles: [Int]              // [] for .retroarch (decided by core)
  public func launchOptions(rom: String, coreFile: String?) -> String
}
public struct EmulatorLaunch: Equatable, Sendable {
  public let emulator: Emulator; public let coreFile: String?; public let romPath: String?
  public static func parse(exe: String, launchOptions: String) -> EmulatorLaunch?   // nil = not a supported emulator
}
public enum Titles { public static func clean(_ fileOrName: String) -> String; public static func key(_ title: String) -> String }
```

**Console table** (RA console id → folder names → RetroArch cores, with the default core first). Consoles with no libretro core on macOS are left out, because nothing can launch them.

| id | folders | cores |
|---|---|---|
| 1 | genesis, megadrive, md | genesis_plus_gx, picodrive |
| 2 | n64 | mupen64plus_next, parallel_n64 |
| 3 | snes, sfc, superfamicom | snes9x, bsnes, mesen-s |
| 4 | gb | gambatte, sameboy, mgba, gearboy |
| 5 | gba | mgba, vbam, gpsp |
| 6 | gbc | gambatte, sameboy, mgba, gearboy |
| 7 | nes, famicom, fc | mesen, fceumm, nestopia |
| 8 | pce, pcengine, tg16 | mednafen_pce_fast, mednafen_pce |
| 9 | segacd, megacd | genesis_plus_gx, picodrive |
| 10 | sega32x, 32x | picodrive |
| 11 | mastersystem, sms | genesis_plus_gx, picodrive, gearsystem |
| 12 | psx, ps1, playstation | swanstation, mednafen_psx_hw, pcsx_rearmed |
| 13 | lynx | handy, mednafen_lynx |
| 14 | ngp, ngpc | mednafen_ngp, race |
| 15 | gamegear, gg | genesis_plus_gx, gearsystem |
| 16 | gamecube, gc, ngc | dolphin |
| 17 | jaguar | virtualjaguar |
| 18 | nds | melondsds, melonds, desmume |
| 19 | wii | dolphin |
| 21 | ps2 | pcsx2 |
| 23 | odyssey2, videopac | o2em |
| 24 | pokemini | pokemini |
| 25 | atari2600 | stella, stella2014 |
| 26 | dos, msdos | dosbox_pure |
| 27 | arcade, fbneo, mame, neogeo, naomi, atomiswave | fbneo, mame2003_plus, mame |
| 28 | virtualboy, vb | mednafen_vb |
| 29 | msx, msx2 | bluemsx, fmsx |
| 30 | c64 | vice_x64sc |
| 31 | zx81 | 81 |
| 33 | sg1000 | genesis_plus_gx, gearsystem |
| 34 | vic20 | vice_xvic |
| 35 | amiga | puae |
| 36 | atarist | hatari |
| 37 | amstradcpc, cpc | cap32, crocods |
| 39 | saturn | mednafen_saturn, yabause, kronos |
| 40 | dreamcast, dc | flycast |
| 41 | psp | ppsspp |
| 42 | cdi | same_cdi |
| 43 | 3do | opera |
| 44 | colecovision, coleco | gearcoleco, bluemsx |
| 45 | intellivision | freeintv |
| 46 | vectrex | vecx |
| 47 | pc88 | quasi88 |
| 48 | pc98 | np2kai |
| 49 | pcfx | mednafen_pcfx |
| 50 | atari5200 | a5200, atari800 |
| 51 | atari7800 | prosystem |
| 52 | x68000 | px68k |
| 53 | wonderswan, ws, wsc | mednafen_wswan |
| 56 | neogeocd | neocd |
| 57 | channelf | freechaf |
| 59 | zxspectrum | fuse |
| 60 | gameandwatch | gw |
| 62 | 3ds | citra |
| 63 | supervision | potator |
| 64 | x1 | x1 |
| 65 | tic80 | tic80 |
| 66 | to8, thomson | theodore |
| 68 | pico | picodrive |
| 69 | megaduck | sameduck |
| 71 | arduboy | arduous |
| 72 | wasm4 | wasm4 |
| 76 | pcenginecd, pcecd, tgcd | mednafen_pce_fast, mednafen_pce |
| 77 | jaguarcd | virtualjaguar |
| 78 | dsi | melondsds |
| 79 | ti83 | numero |
| 80 | uzebox | uzem |
| 81 | fds | mesen, fceumm, nestopia |

**Emulator table.** Launch forms are confirmed in Task 13 once each emulator is installed; fix the table there if one differs.

| emulator | appNames | consoles | launchOptions |
|---|---|---|---|
| retroarch | RetroArch | (by core) | `-L "<core>" "<rom>"` |
| duckstation | DuckStation | 12 | `-batch -- "<rom>"` |
| pcsx2 | PCSX2 | 21 | `-batch -- "<rom>"` |
| ppsspp | PPSSPPSDL, PPSSPP | 41 | `"<rom>"` |
| dolphin | Dolphin | 16, 19 | `-b -e "<rom>"` |
| flycast | Flycast | 40, 27 | `"<rom>"` |
| skyemu | SkyEmu | 4, 6, 5 | `"<rom>"` |

**Rules:**
- **Emulator detection:** strip quotes from the exe. It matches emulator E when it ends with `/<appName>` or `/<appName>.app`, or contains `<appName>.app/` for one of E's `appNames` (case-insensitive). When the exe is `open` or `/usr/bin/open`, the options must contain `-a <appName>` or a path to `<appName>.app`, and only the arguments after `--args` are parsed.
- **Tokenizing:** shell-style, handling double quotes, single quotes, and backslash escapes.
- **Core:** the value of `-L` or `--libretro`, or the part after `--libretro=`.
- **ROM:** the last token that isn't a flag and isn't the value of a flag that takes one: `-L`, `--libretro`, `-c`, `--config`, `--appendconfig`, `-s`, `--save`, `-S`, `--savestate`, `--subsystem`, `--log-file`, `-a`, `-e`, `--exec`. A token right after `--` is always the ROM. Comment `// shortcut: flag list covers common emulator flags; add any that show up in real shortcuts`.
- **`candidates`:**
  - The emulator's consoles are `forCore` ids for RetroArch (empty if the core is unknown), otherwise `emulator.consoles`.
  - The fingerprint consoles are the ids in `fingerprints`, in order.
  - Result: the emulator's consoles that also appear in the fingerprints, when that overlap isn't empty. Otherwise the emulator's consoles. If those are empty too, the fingerprint consoles.
- **`clean`:**
  - Take the last path component.
  - Drop the extension only if it's 1–4 ASCII letters or digits with no spaces.
  - Remove `(...)` and `[...]` groups, collapse runs of spaces, and trim.
- **`key`:**
  - Lowercase, then strip diacritics.
  - Remove `~...~`, `(...)`, and `[...]` groups.
  - Turn `&` into ` and `.
  - Drop a leading `the ` and any `, the`.
  - Keep only letters and digits.

- [ ] **Step 1:** Write the failing tests:

```swift
let ra = "\"/Applications/RetroArch.app/Contents/MacOS/RetroArch\""
@Test func parsesQuotedPaths() {
  #expect(EmulatorLaunch.parse(exe: ra, launchOptions: "-L \"/Users/u/Library/Application Support/RetroArch/cores/snes9x_libretro.dylib\" \"/Users/u/ROMs/snes/Super Mario World (USA).sfc\"")
    == EmulatorLaunch(emulator: .retroarch, coreFile: "/Users/u/Library/Application Support/RetroArch/cores/snes9x_libretro.dylib", romPath: "/Users/u/ROMs/snes/Super Mario World (USA).sfc"))
}
@Test func parsesOpenDashA()      // exe "/usr/bin/open", options "-a RetroArch --args -L \"/c/mgba_libretro.dylib\" \"/r/Pokémon - Red Version (USA, Europe).gb\"" → retroarch, rom "/r/Pokémon - Red Version (USA, Europe).gb"
@Test func parsesAppBundleExe()   // exe "\"/Applications/RetroArch.app\"", options "-L x_libretro.dylib \"/r/a b.nes\"" → rom "/r/a b.nes"
@Test func parsesFlagsAndEscapes() // "--libretro=/c/fceumm_libretro.dylib /r/My\\ Game.nes" → core "/c/fceumm_libretro.dylib", rom "/r/My Game.nes"
@Test func skipsConfigValue()     // "-c \"/x/retroarch.cfg\" -L '/c/a_libretro.dylib' '/r/g.sfc'" → rom "/r/g.sfc"
@Test func retroArchWithoutRom()  // options "" → EmulatorLaunch(emulator: .retroarch, coreFile: nil, romPath: nil)
@Test func parsesStandalone() {
  #expect(EmulatorLaunch.parse(exe: "\"/Applications/DuckStation.app/Contents/MacOS/DuckStation\"", launchOptions: "-batch -- \"/r/psx/Crash (USA).cue\"")?.romPath == "/r/psx/Crash (USA).cue")
  #expect(EmulatorLaunch.parse(exe: "\"/Applications/Dolphin.app/Contents/MacOS/Dolphin\"", launchOptions: "-b -e \"/r/gc/Melee.iso\"")?.emulator == .dolphin)
}
@Test func otherAppIsNotEmulator() // exe "\"/System/Applications/Calculator.app\"" → nil
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
```

- [ ] **Step 2:** Run `swift test --filter ParsingTests`. Expected: fails to build.
- [ ] **Step 3:** Implement the Interfaces, tables, and rules above.
- [ ] **Step 4:** Run `swift test --filter ParsingTests`. Expected: all pass.

### Task 4: RetroAchievements client and cache

**Files:**
- Create: `Sources/RACore/RAModels.swift`, `Sources/RACore/RAClient.swift`, `Sources/RACore/DiskCache.swift`
- Test: `Tests/RACoreTests/RAClientTests.swift`
- Fixtures: `Tests/RACoreTests/Fixtures/game-list.json` (2 games with `Hashes`) and `game-progress.json` (2 achievements, one earned on `2016-03-12 17:47:29`). Trim both from the samples on api-docs.retroachievements.org.

**Interfaces:**

```swift
public struct RACredentials: Codable, Equatable, Sendable { public var username: String; public var apiKey: String }
public protocol HTTPTransport: Sendable { func get(_ url: URL) async throws -> (Data, Int) }   // body, HTTP status
public struct URLSessionTransport: HTTPTransport { public init() }                            // 15 s timeout
public enum RAError: Error, Equatable { case badCredentials, http(Int), decoding }
public struct RAGameListEntry: Codable, Equatable, Sendable { public var id: Int; public var title: String; public var consoleId: Int; public var consoleName: String; public var imageIcon: String; public var numAchievements: Int; public var hashes: [String] }
public struct RAAchievement: Codable, Equatable, Sendable { public var id: Int; public var title: String; public var description: String; public var points: Int; public var badgeName: String; public var displayOrder: Int; public var numAwarded: Int; public var numAwardedHardcore: Int; public var dateEarned: Date?; public var dateEarnedHardcore: Date? }
public struct RAGameProgress: Codable, Equatable, Sendable { public var id: Int; public var title: String; public var consoleId: Int; public var consoleName: String; public var imageIcon: String; public var publisher: String?; public var developer: String?; public var genre: String?; public var released: String?; public var numDistinctPlayers: Int; public var achievements: [RAAchievement] }
public protocol RAProviding: Sendable {
  func gameList(consoleId: Int) async throws -> [RAGameListEntry]
  func gameProgress(gameId: Int) async throws -> RAGameProgress
}
public final class RAClient: RAProviding { public init(credentials: RACredentials, transport: HTTPTransport = URLSessionTransport()); public func checkCredentials() async throws }
public final class DiskCache: @unchecked Sendable { public init(directory: URL); public func get<T: Decodable>(_ key: String, as: T.Type) -> (value: T, savedAt: Date)?; public func put<T: Encodable>(_ key: String, _ value: T, savedAt: Date = Date()) }
public final class CachedRA: RAProviding { public init(client: RAProviding, cache: DiskCache, now: @escaping @Sendable () -> Date = { Date() }); public func cachedProgress(gameId: Int) -> (value: RAGameProgress, savedAt: Date)? }
```

**Rules:**
- Requests go to `API_GetUserProfile.php?u=&y=`, `API_GetGameList.php?i=<consoleId>&h=1&y=`, and `API_GetGameInfoAndUserProgress.php?g=<gameId>&u=<user>&y=`. Build them with `URLComponents` so values are percent-encoded.
- Errors: 401 → `.badCredentials`; any other non-2xx → `.http(status)`; a decode failure → `.decoding`.
- RA dates use `yyyy-MM-dd HH:mm:ss` in UTC.
- `Achievements` arrives as an object keyed by ID. Return it as an array sorted by `displayOrder`.
- `CachedRA.gameList` serves cache key `gamelist-<consoleId>` while it's under 7 days old. `gameProgress` always fetches, then stores the result under `progress-<gameId>`.

- [ ] **Step 1:** Write the failing tests:

```swift
@Test func decodesGameList() throws    // fixture → [0].id and title match the fixture, hashes not empty
@Test func decodesProgress() throws    // fixture → 2 achievements in displayOrder; the earned one's dateEarned == 2016-03-12 17:47:29 UTC
@Test func buildsRequestURL() async throws // FakeTransport records URLs; RAClient(credentials: .init(username: "Max Milyin", apiKey: "k&1")).gameProgress(gameId: 14402) → path "/API/API_GetGameInfoAndUserProgress.php", query g=14402, u="Max Milyin", y="k&1"
@Test func unauthorizedIsBadCredentials() async // status 401 → throws RAError.badCredentials
@Test func gameListCachedSevenDays() async throws // counting fake RAProviding, DiskCache(tempDir()): calls at t0 and t0+6d → 1 fetch; at t0+8d → 2 fetches
```

- [ ] **Step 2:** Run `swift test --filter RAClientTests`. Expected: fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter RAClientTests`. Expected: all pass.

### Task 5: Matching

**Files:**
- Create: `Sources/RACore/MatchStore.swift`, `Sources/RACore/Matcher.swift`
- Test: `Tests/RACoreTests/MatcherTests.swift`

**Interfaces:**
- Consumes:
  - `Fingerprinting`, `HashResult`, `ConsoleHash` (Task 2)
  - `Consoles`, `EmulatorLaunch`, `Titles` (Task 3)
  - `RAProviding`, `RAGameListEntry` (Task 4)
- Produces:

```swift
public struct ShortcutInfo: Codable, Equatable, Sendable { public var appid: UInt32; public var name: String; public var exe: String; public var launchOptions: String }
public enum Verification: String, Codable, Sendable { case verified, unrecognizedHash, unchecked, blocked, missing }
public enum Resolution: Equatable, Sendable {
  case notEmulator, noRom
  case matched(gameId: Int, consoleId: Int, verification: Verification)
  case notMatched(consoleId: Int?, verification: Verification)
}
public struct MatchRecord: Codable, Equatable, Sendable { public var gameId: Int; public var consoleId: Int; public var manual: Bool; public var hash: String?; public var size: Int64; public var modified: Double }
public final class MatchStore: @unchecked Sendable { public init(file: URL); public func record(romPath: String) -> MatchRecord?; public func save(romPath: String, _ r: MatchRecord) }
public actor Matcher {
  public init(ra: RAProviding, hasher: Fingerprinting, store: MatchStore)
  public func resolve(_ s: ShortcutInfo) async throws -> Resolution
  public func choose(_ s: ShortcutInfo, gameId: Int, consoleId: Int) async throws -> Resolution
  public func search(query: String, consoleId: Int) async throws -> [RAGameListEntry]
}
```

**`resolve` order** (spec "Matching"):
1. `EmulatorLaunch.parse` returns nil → `.notEmulator`. No ROM path → `.noRom`.
2. Work out the ROM's hash and console:
   - If the file's size and modified time equal the stored record's, reuse the record's `hash`.
   - Otherwise compute `fps = hasher.allFingerprints(rom)` and `consoles = Consoles.candidates(emulator:coreFile:fingerprints:)`. The hash for console `c` is its `fps` entry, or else `hasher.fingerprint(rom, c)`.
   - The base verification comes from that `HashResult`: a hash with no game matched yet → `.unrecognizedHash`; `.unsupportedFormat` → `.unchecked`; `.unreadable(.missing)` → `.missing`; `.unreadable(.blocked)` → `.blocked`.
3. A stored record exists → `.matched(record.gameId, record.consoleId, v)`. Here `v` is `.verified` if the hash is in that game's `hashes`, `.unrecognizedHash` if there's a hash that isn't, and the base otherwise.
4. For each console in `consoles`: find an entry whose `hashes` contains the hash. If found, save the record (`manual: false`) and return `.matched(…, .verified)`.
5. Name match:
   - Compute the keys of `Titles.clean(rom file name)` and `Titles.clean(s.name)`.
   - For each console, find entries whose `Titles.key(title)` equals either key. Prefer `numAchievements > 0`, then the lowest `id`.
   - Save the record (`manual: false`) and return `.matched(…, base)`.
6. Otherwise → `.notMatched(consoleId: consoles.first, verification: base)`.

`choose` saves the record with `manual: true` and returns what step 3 would return. `search` returns up to 50 entries for that console whose key contains `Titles.key(query)`, games with achievements first, then sorted by title.

- [ ] **Step 1:** Write the failing tests, using `FakeRA` (consoleId → entries) and `FakeHasher` (fixed results) with `MatchStore(file: tempDir()/m.json)`:

```swift
func smb(_ rom: String = "/r/nes/Super Mario Bros. (World).nes") -> ShortcutInfo { .init(appid: 1, name: "Super Mario Bros.", exe: "\"/Applications/RetroArch.app/Contents/MacOS/RetroArch\"", launchOptions: "-L \"/c/fceumm_libretro.dylib\" \"\(rom)\"") }
let smbEntry = RAGameListEntry(id: 1446, title: "Super Mario Bros.", consoleId: 7, consoleName: "NES/Famicom", imageIcon: "/Images/1.png", numAchievements: 30, hashes: ["abc"])

@Test func notEmulator()                 // Calculator exe → .notEmulator
@Test func emulatorWithoutRom()          // launchOptions "" → .noRom
@Test func hashMatchIsVerified()         // hasher "abc" → .matched(1446, 7, .verified); store has a record
@Test func nameMatchWithUnknownHashWarns() // hasher "zzz" → .matched(1446, 7, .unrecognizedHash)
@Test func unsupportedFormatIsUnchecked()  // .unsupportedFormat → .matched(1446, 7, .unchecked)
@Test func blockedRomStillNameMatches()    // .unreadable(.blocked) → .matched(1446, 7, .blocked)
@Test func noMatchReportsConsole()       // list without SMB, hash "zzz" → .notMatched(consoleId: 7, verification: .unrecognizedHash)
@Test func manualChoiceIsRemembered()    // choose(gameId: 2000) where 2000's hashes = ["abc"] → .matched(2000, 7, .verified); resolve again → same
@Test func prefersGameWithAchievements() // two "Super Mario Bros." entries: id 5 with 0 achievements, id 9 with 10 → gameId 9
@Test func searchFindsByKey()            // search("mario bros", 7).first == smbEntry
```

- [ ] **Step 2:** Run `swift test --filter MatcherTests`. Expected: fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter MatcherTests`. Expected: all pass.

### Task 6: Panel payload

**Files:**
- Create: `Sources/RACore/PanelPayload.swift`
- Test: `Tests/RACoreTests/PanelPayloadTests.swift`

**Interfaces:**
- Consumes: `RAGameProgress`, `RAAchievement` (Task 4); `Verification` (Task 5).
- Produces the JSON that `inject.js` draws. Its field names are the contract:

```swift
public struct PanelPayload: Codable, Equatable, Sendable {
  public var state: String              // "signedOut" | "hidden" | "notMatched" | "matched" | "noSet" | "error"
  public var message: String?
  public var notice: String?
  public var consoleId: Int?
  public var game: Game?
  public var summary: Summary?
  public var achievements: [Row] = []
  public var updatedText: String?
  public struct Game: Codable, Equatable, Sendable { public var id: Int; public var title, consoleName, iconURL, raURL: String; public var details: [Detail] }
  public struct Detail: Codable, Equatable, Sendable { public var label, value: String }
  public struct Summary: Codable, Equatable, Sendable { public var text, pointsText: String; public var hardcoreText: String?; public var percent: Int }
  public struct Row: Codable, Equatable, Sendable { public var id: Int; public var title, description: String; public var points: Int; public var badgeURL: String; public var unlocked, hardcore: Bool; public var unlockedText, rarityText: String? }
}
public enum PanelBuilder {
  public static func matched(_ p: RAGameProgress, verification: Verification, emulatorName: String, stale: Bool, savedAt: Date?, timeZone: TimeZone = .current, locale: Locale = .current) -> PanelPayload
  public static func signedOut() -> PanelPayload
  public static func hidden() -> PanelPayload
  public static func notMatched(consoleId: Int?, verification: Verification) -> PanelPayload
  public static func failed(cached: PanelPayload?, savedAt: Date?) -> PanelPayload
}
```

**Copy (exact):**
- **Summary:**
  - `text`: `You've unlocked <u>/<t> (<pct>%)`, where pct = floor(u × 100 / t).
  - `pointsText`: `<earned> / <total> points`.
  - `hardcoreText`: `<h> in hardcore`, or nil when h = 0.
- **Rows:**
  - `rarityText`: `String(format: "%.1f%% of players have this achievement", numAwarded × 100 / numDistinctPlayers)`, or nil when there are 0 players.
  - `unlockedText`: `Unlocked ` plus the date (medium date, short time).
  - `unlocked` is true when either date is set. `hardcore` is true when `dateEarnedHardcore` is set.
  - `badgeURL`: the media badge path when unlocked, the `_lock.png` path when locked.
  - Order: unlocked first, newest unlock first, then locked rows in `displayOrder`.
- **Game:**
  - `details`, in this order and skipping empty values: `Console`, `Developer`, `Publisher`, `Genre`, `Released` (date part only, medium format).
  - `iconURL`: `https://media.retroachievements.org` + `imageIcon`.
  - `raURL`: `https://retroachievements.org/game/<id>`.
- **Notices:**
  - `.verified` → nil
  - `.unrecognizedHash` → `RetroAchievements doesn't recognize this ROM version, so RetroArch won't unlock these achievements.`, with "RetroArch" replaced by `emulatorName`.
  - `.unchecked` → `Couldn't check this ROM version.`
  - `.blocked` → `macOS won't let Steam RetroAchievements read this ROM. Move it to the ROMs folder in your home folder.`
  - `.missing` → `Can't find this game's ROM file.`
- **States:**
  - No achievements → state `noSet`, message `No achievements for this game on RetroAchievements yet.` Game and details are still filled in.
  - `signedOut` → message `Open Steam RetroAchievements to sign in.`
  - `notMatched` → message `Couldn't find this game on RetroAchievements.`
  - `failed(cached:savedAt:)` → the cached payload with `updatedText` `Last updated <short time>`. With nothing cached → state `error`, message `Couldn't reach RetroAchievements.`
  - `matched` with `stale: true` → `updatedText` `Last updated <short time>`.

- [ ] **Step 1:** Write the failing tests:

```swift
@Test func summaryAndOrder()       // 40 achievements, 3 earned (1 hardcore) → "You've unlocked 3/40 (7%)", "1 in hardcore", rows[0] is the newest unlock, rows[3] is the locked one with the lowest displayOrder
@Test func rarityAndBadges()       // 5 of 10 players → "50.0% of players have this achievement"; a locked badgeURL ends in "_lock.png"; 0 players → rarityText nil
@Test func noticesPerVerification() // each Verification → its exact notice above (emulatorName "DuckStation" shows in the unrecognizedHash text)
@Test func emptySetIsNoSet()       // no achievements → state "noSet" and the exact message
@Test func failedUsesCache()       // failed(cached: x, savedAt: d).updatedText starts with "Last updated"; failed(cached: nil, savedAt: nil).state == "error"
```

- [ ] **Step 2:** Run `swift test --filter PanelPayloadTests`. Expected: fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter PanelPayloadTests`. Expected: all pass.

### Task 7: Steam connection

**Files:**
- Create: `Sources/SteamBridge/DebugMarker.swift`, `Sources/SteamBridge/SteamConnection.swift`
- Modify: `Package.swift` (add target `SteamBridge` and test target `SteamBridgeTests`)
- Test: `Tests/SteamBridgeTests/SteamConnectionTests.swift`

**Interfaces:**
- Consumes: `docs/steam-internals.md` Q1 (bundle id) and Q11 (binding works).
- Produces:

```swift
public struct DebugMarker: Sendable { public static let defaultDirectory: URL; public init(directory: URL = defaultDirectory); public var url: URL { get }; public func exists() -> Bool; public func ensure() throws; public func remove() throws; public var createdAt: Date? { get } }
public struct CDPTarget: Decodable, Equatable, Sendable { public let id, title, type: String; public let webSocketDebuggerUrl: String? }
public enum SteamState: Equatable, Sendable { case steamNotRunning, needsRestart, connecting, connected }
@MainActor public final class SteamConnection {
  public init(marker: DebugMarker, script: @escaping () -> String, onBinding: @escaping @Sendable (String) async -> String?)
  public private(set) var state: SteamState
  public var onStateChange: ((SteamState) -> Void)?
  public func start()
  public func evaluate(_ js: String) async throws -> Any?        // awaitPromise + returnByValue
  public func restartSteam() async
  public nonisolated static func sharedJSContext(in targets: [CDPTarget]) -> CDPTarget?
  public nonisolated static func decide(steamRunning: Bool, steamLaunched: Date?, markerCreated: Date?, portAnswered: Bool, now: Date) -> SteamState
}
```

**Behavior:**
- **Every 3 s:**
  - Run `marker.ensure()` if the marker is missing.
  - Check whether Steam is running with `NSRunningApplication` (bundle id from Q1).
  - Fetch `/json`, then set the state from `decide(...)`.
- **On `.connecting`:** open a `URLSessionWebSocketTask` and send, in order:
  - `Runtime.enable`
  - `Runtime.addBinding {name: "__sra_send"}`
  - `Runtime.evaluate {expression: script()}`
  
  Then set `.connected`.
- **On `Runtime.bindingCalled` named `__sra_send`:** pass its `payload` to `onBinding`, and evaluate whatever JS it returns.
- **On socket close or error:** go back to polling.
- **`restartSteam`:** call `terminate()` on Steam, wait up to 30 s for it to exit, then reopen it with `NSWorkspace.openApplication`.
- **`decide`:**
  - Not running → `.steamNotRunning`.
  - Running and `steamLaunched < markerCreated` → `.needsRestart`.
  - Port answered → `.connecting`.
  - Otherwise → `.needsRestart` once at least 20 s have passed since `steamLaunched`, else `.connecting`.

- [ ] **Step 1:** Write the failing tests:

```swift
@Test func markerEnsureAndRemove() throws  // DebugMarker(directory: temp): exists() false → ensure() → true and createdAt non-nil → remove() → false
@Test func picksSharedJSContext() throws   // decode a 3-target /json string → .title == "SharedJSContext"
@Test func decideRules()                   // each of the five decide cases above → its exact SteamState
```

- [ ] **Step 2:** Run `swift test --filter SteamConnectionTests`. Expected: fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter SteamConnectionTests`, then `swift build`. Expected: both pass.

### Task 8: App shell, sign-in, build script

**Files:**
- Create in `Sources/SteamRetroAchievements/`: `App.swift`, `AppModel.swift`, `Windows.swift`, `MenuContent.swift`, `SettingsView.swift`, `Keychain.swift`, `LoginItem.swift`, `Log.swift`
- Create: `Sources/RACore/Uninstaller.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `steam/inject.js` (placeholder)
- Modify: `Package.swift` (executable target `SteamRetroAchievements`, depending on `RACore` and `SteamBridge`)
- Test: `Tests/RACoreTests/UninstallerTests.swift`

**Interfaces:**
- Consumes: `RAClient`, `RACredentials`, `RAError` (Task 4); `SteamConnection`, `SteamState`, `DebugMarker` (Task 7).
- Produces:

```swift
// RACore
public struct UninstallPaths: Sendable { public var marker, dataDir, log, app: URL }
public enum Uninstaller { public static func run(_ p: UninstallPaths, deleteCredentials: () -> Void, disableLogin: () -> Void) throws }  // removes marker, data dir, log; trashes the app
// App target
enum Keychain { static func load() -> RACredentials?; static func save(_ c: RACredentials) throws; static func delete() }  // service "steam-retroachievements", account = username, data = apiKey
enum LoginItem { static var isEnabled: Bool { get }; static func set(_ on: Bool) throws }                                 // SMAppService.mainApp
enum Log { static func info(_ s: String); static func error(_ s: String) }                                                // appends "<ISO8601> <LEVEL> <msg>\n"
enum AppWindow { case settings }                                                                                           // Task 9 adds .addGames
@MainActor @Observable final class AppModel {
  var credentials: RACredentials?; var steamState: SteamState; var retroArchFound: Bool
  let steam: SteamConnection
  func signIn(username: String, apiKey: String) async -> String?   // nil on success, otherwise the error copy
  func signOut(); func restartSteam() async; func uninstall()
  func show(_ w: AppWindow)                                         // NSWindow + NSHostingController, created once and reused; NSApp.activate() first
}
```

The windows are AppKit `NSWindow`s that host SwiftUI views, so bridge calls (Task 10) can open them. The `App` scene declares only `MenuBarExtra`.

**Copy (exact):**
- **Menu bar icon:** SF Symbol `trophy`. It switches to `exclamationmark.triangle` when the state is `.needsRestart` or the user is signed out.
- **Menu status line:**
  - `.connected` → `Connected to Steam`
  - `.connecting` and `.steamNotRunning` → `Waiting for Steam to open`
  - `.needsRestart` → `Restart Steam to finish setup`
  - Signed out (overrides the others) → `Sign in to RetroAchievements to start`
- **Menu items:** `Restart Steam…` (only in `.needsRestart`), `Settings…`, `Quit Steam RetroAchievements`.
- **Settings window**, titled `Steam RetroAchievements`, as a `Form` with these sections:
  - **`RetroAchievements`:**
    - Signed out: fields `Username` and `Web API key` (a SecureField), link `Find your Web API key` to `https://retroachievements.org/settings`, button `Sign In`.
    - Errors: `Couldn't sign in. Check your username and Web API key.` for `.badCredentials`, otherwise `Couldn't reach RetroAchievements. Try again in a moment.`
    - Signed in: `Signed in as <username>` and button `Sign Out`.
  - **`Steam`:** the status line, plus a `Restart Steam` button in `.needsRestart`. It confirms with an alert titled `Restart Steam?`, message `This quits Steam and any game running in it, then opens Steam again.`, and buttons `Restart Steam` / `Cancel`.
  - **`Emulators`:** one row per `Emulator` showing `Installed` or `Not installed`, found by `appNames` under `/Applications` and `~/Applications`.
  - **`General`:** toggle `Open at login`.
  - Button `Uninstall…`: an alert titled `Uninstall Steam RetroAchievements?`, message `This turns off Steam's debug switch, deletes your saved sign-in and cached data, and moves the app to the Trash. Games it added stay in your Steam library.`, buttons `Uninstall` (destructive) / `Cancel`.
- **Startup and sign-in:** Settings opens at launch when `credentials == nil`. A successful sign-in runs `Keychain.save`, `LoginItem.set(true)`, and `marker.ensure()`.

**Info.plist:** `CFBundleIdentifier` `local.steam-retroachievements`, `CFBundleName` `Steam RetroAchievements`, `CFBundleExecutable` `SteamRetroAchievements`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `0.1.0`, `CFBundleVersion` `1`, `LSMinimumSystemVersion` `14.0`, `LSUIElement` true.

**`scripts/build-app.sh`:**
1. `swift build -c release --product SteamRetroAchievements`
2. Assemble `build/Steam RetroAchievements.app` with `Contents/MacOS/SteamRetroAchievements`, `Contents/Info.plist`, and `Contents/Resources/inject.js`.
3. Sign it: `codesign --force --sign - "$APP"`.
4. Quit any running copy: `osascript -e 'quit app id "local.steam-retroachievements"'`.
5. Replace `~/Applications/Steam RetroAchievements.app` and `open` it.

The app loads the script from `Bundle.main.url(forResource: "inject", withExtension: "js")`.

**Placeholder `steam/inject.js`:**
- Call `window.__sra?.dispose?.()` first.
- Set `window.__sra = { receive(){}, update(){}, dispose(){} }`.
- Send `window.__sra_send(JSON.stringify({id: 0, method: "log", params: {level: "info", message: "inject loaded"}}))`.

Until Task 10, `onBinding` only logs the raw payload.

- [ ] **Step 1:** Write the failing test `uninstallRemovesEverything`:
  - Set up a temp marker, a data dir with one file, a log, and a fake `.app` dir.
  - Run `Uninstaller.run` with spy closures.
  - Expected: the marker, data dir, and log are gone; the app no longer exists at its path (moved to the Trash with `FileManager.trashItem`); both closures were called.
- [ ] **Step 2:** Run `swift test --filter UninstallerTests`. Expected: fails.
- [ ] **Step 3:** Implement the Interfaces above.
- [ ] **Step 4:** Run `swift test`, then `bash scripts/build-app.sh`. Expected: tests pass, the app opens, the trophy icon appears in the menu bar, and the Settings window opens.
- [ ] **Step 5 (user step):** Ask the user to type their RA username and Web API key into Settings and click Sign In. Expected: `Signed in as <username>`, `Open at login` turned on, and the marker file present.
- [ ] **Step 6 (user step):** With Steam running, if the status reads `Restart Steam to finish setup`, ask the user to click Restart Steam and confirm. Expected: the status reads `Connected to Steam`, and the log contains `inject loaded`.

### Task 9: Add Games window

**Files:**
- Create: `Sources/RACore/Scanner.swift`, `Sources/SteamRetroAchievements/AddGamesView.swift`
- Modify: `steam/inject.js` (add `listShortcuts` and `addShortcuts`), `Windows.swift` (add `AppWindow.addGames`), `MenuContent.swift` (add item `Add Games…`)
- Test: `Tests/RACoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `Consoles`, `Emulator`, `EmulatorLaunch`, `Titles` (Task 3); `Fingerprinting` (Task 2); `SteamConnection.evaluate` (Task 7); `docs/steam-internals.md` Q5 and Q6.
- Produces:

```swift
public enum ScanStatus: Equatable, Sendable { case ready, alreadyInSteam, noEmulator(String), chooseConsole }   // noEmulator text = what to install
public struct ScanItem: Identifiable, Equatable, Sendable { public var id: String { romPath }; public var romPath, title: String; public var consoleId: Int?; public var emulator: Emulator?; public var coreFile: String?; public var status: ScanStatus }
public struct Installed: Sendable { public var emulators: [Emulator: String]; public var coresDirectory: URL }   // emulator → exe path
public struct Scanner: Sendable {
  public init(installed: Installed, hasher: Fingerprinting)
  public func scan(folder: URL, existingRomPaths: Set<String>, consoleOverrides: [String: Int], emulatorOverrides: [Int: Emulator]) -> [ScanItem]
  public static func shortcut(for item: ScanItem, installed: Installed) -> (name: String, exe: String, launchOptions: String, startDir: String)
}
public enum EmulatorPreference { public static func order(for consoleId: Int) -> [Emulator] }   // spec "Adding games"
```

- `window.__sra.listShortcuts()` returns `[ShortcutInfo]`, using the Q5 expression.
- `window.__sra.addShortcuts([{name, exe, launchOptions, startDir}])` returns one entry per item, either `{name, appid}` or `{name, error}`, using the Q6 calls.

**Rules:**
- **Walking the folder:**
  - Recurse, skipping hidden files and these extensions: `txt nfo jpg jpeg png pdf sav srm state cfg xml dat`.
  - In a folder that has an `.m3u`, list only the `.m3u` files.
  - In a folder that has a `.cue` or `.gdi`, skip `.bin`, `.raw`, and `.img` files. Comment `// shortcut: skips every .bin beside a .cue instead of parsing the cue; upgrade if mixed folders show up`.
- **Console:** the nearest ancestor folder name that `Consoles.forFolder` recognizes. Otherwise `consoleOverrides[parent path]`. Otherwise the console from `hasher.allFingerprints`, if there's exactly one. Otherwise `.chooseConsole`.
- **Emulator:** `emulatorOverrides[console]`, else the first entry in `EmulatorPreference.order` that's installed. RetroArch only counts as installed for a console if one of that console's cores exists as `<core>_libretro.dylib` in `coresDirectory`.
  - If none is installed → `.noEmulator(...)`. The text names the first preference: `In RetroArch, open Online Updater → Core Downloader and get <core>.` for RetroArch, or `Install <displayName>.` for a standalone emulator.
- **Already in Steam:** `.alreadyInSteam` when the ROM path is in `existingRomPaths`. Build that set by running `EmulatorLaunch.parse` on every result of `listShortcuts()`.
- **Shortcut fields:** name is `Titles.clean(file)`. Exe is the quoted exe path in the form Q6 recorded. Start dir is the exe's folder. Launch options come from `emulator.launchOptions(rom:coreFile:)`.
- **Detecting what's installed:** look for apps by `appNames` in `/Applications` and `~/Applications`. The cores dir is `~/Library/Application Support/RetroArch/cores/`; confirm it in Task 13.

**Window copy:**
- Title `Add Games`.
- A folder row showing the path (default `~/ROMs`, created if missing) with a `Choose…` button, and a `Scan` button.
- Table columns:
  - `Game`
  - `Console`: a picker on `chooseConsole` rows. It writes `consoleOverrides` and rescans.
  - `Emulator`: a picker listing the installed emulators for that console. It writes `emulatorOverrides`.
  - `Status`: `Ready`, `Already in Steam`, the `noEmulator` text, or `Choose a console`.
- Checkboxes on `Ready` rows, checked by default.
- Button `Add <N> Games to Steam`. It's disabled with the text `Open Steam first` unless the state is `.connected`.
- After adding: `Added <N> games to Steam.`, followed by any per-game errors.

- [ ] **Step 1:** Write the failing tests:

```swift
@Test func scansFolderTree() throws
// tree: snes/Super Mario World (USA).sfc, misc/game.gbc, psx/FF7/FF7 (Disc 1).cue, psx/FF7/FF7 (Disc 1).bin, psx/FF7/FF7.m3u, notes.txt
// Installed(emulators: [.retroarch: "/A/RetroArch", .duckstation: "/A/DuckStation"], coresDirectory: dir containing snes9x_libretro.dylib and gambatte_libretro.dylib)
// FakeHasher.allFingerprints(".../game.gbc") == [ConsoleHash(consoleId: 6, hash: "h")]
// → exactly 3 items:
//   Super Mario World: console 3, .retroarch, core snes9x, .ready, title "Super Mario World"
//   game.gbc: console 6, .retroarch, core gambatte, .ready
//   FF7.m3u: console 12, .duckstation, .ready
@Test func existingPathIsAlreadyInSteam()
@Test func ambiguousFileAsksForConsole()   // misc/game.bin whose allFingerprints gives 2 consoles → .chooseConsole; with consoleOverrides → resolved
@Test func missingCoreNamesIt()            // n64/game.z64 with no mupen64plus_next core → .noEmulator("In RetroArch, open Online Updater → Core Downloader and get mupen64plus_next.")
@Test func shortcutLaunchOptions()         // RetroArch item → launchOptions == "-L \"<cores>/snes9x_libretro.dylib\" \"/r/snes/Super Mario World (USA).sfc\""
```

- [ ] **Step 2:** Run `swift test --filter ScannerTests`. Expected: fails.
- [ ] **Step 3:** Implement the scanner, the window, and the two `inject.js` functions. Wrap both functions in `safe()`.
- [ ] **Step 4:** Run `swift test --filter ScannerTests`. Expected: all pass.
- [ ] **Step 5:** Run `bash scripts/build-app.sh` and open `Add Games…` from the menu. Scan a temp tree in `~/ROMs` made of fake files. Expected: rows appear, with `noEmulator` text where nothing is installed.
- [ ] **Step 6:** Run `node scripts/steam-eval.mjs 'window.__sra.addShortcuts([{name:"SRA Test",exe:"\"/Applications/RetroArch.app/Contents/MacOS/RetroArch\"",launchOptions:"",startDir:"\"/Applications/RetroArch.app/Contents/MacOS/\""}])'`. Expected: it returns an appid, and `listShortcuts()` includes `SRA Test`. Remove the shortcut with the Q6 remove call.

### Task 10: Bridge router and handler

**Files:**
- Create: `Sources/RACore/BridgeRouter.swift`, `Sources/RACore/BridgeHandler.swift`
- Modify: `AppModel.swift` (create `Services` after sign-in; set `SteamConnection.onBinding` to `router.respond`)
- Test: `Tests/RACoreTests/BridgeTests.swift`

**Interfaces:**
- Consumes:
  - `Matcher`, `ShortcutInfo` (Task 5)
  - `PanelBuilder` (Task 6)
  - `CachedRA`, `DiskCache`, `RAClient`, `HTTPTransport` (Task 4)
  - `Consoles`, `Emulator`, `EmulatorLaunch` (Task 3)
  - `AppModel.show` (Tasks 8 and 9)
- Produces the bridge protocol that `inject.js` relies on:
  - Page → app: `window.__sra_send(JSON.stringify({id, method, params}))`.
  - App → page reply: evaluate `window.__sra.receive({"id":<id>,"result":<json>})`, or `{"id":<id>,"error":"<text>"}` on failure.
  - App → page push: evaluate `window.__sra.update({"appid":<n>,"payload":<PanelPayload>})`.
  - Methods:
    - `log {level, message}` → null
    - `getPanel {shortcut}` → PanelPayload, cached data first followed by a push
    - `refreshPanel {shortcut}` → a freshly fetched PanelPayload
    - `searchGames {consoleId, query}` → `[{gameId, title, consoleName, iconURL, numAchievements}]`
    - `chooseGame {shortcut, gameId, consoleId}` → PanelPayload
    - `consoles {}` → `[{id, name}]`
    - `openSettings {}` and `openAddGames {}` → null
    - `openURL {url}` → null, allowed only when the URL starts with `https://retroachievements.org/`
    - `image {url}` → a data URL, only if Q10 found images blocked, and allowed only for `https://media.retroachievements.org/`

```swift
public struct Services: Sendable { public let ra: CachedRA; public let matcher: Matcher
  public init(credentials: RACredentials, dataDirectory: URL, transport: HTTPTransport = URLSessionTransport()) }   // DiskCache(data/cache), MatchStore(data/matches.json), RomHasher()
public struct BridgeActions: Sendable { public var openSettings, openAddGames: @Sendable () async -> Void; public var openURL: @Sendable (URL) async -> Void; public var log: @Sendable (String, String) -> Void }
public protocol BridgeHandling: Sendable { func handle(method: String, params: Data) async throws -> Data }
public final class BridgeHandler: BridgeHandling { public init(services: @escaping @Sendable () async -> Services?, actions: BridgeActions, push: @escaping @Sendable (String) async -> Void) }
public struct BridgeRouter: Sendable { public init(handler: BridgeHandling); public func respond(to payload: String) async -> String?   // JS to evaluate; nil if the payload isn't {id, method, params}
  public static func isAllowedExternalURL(_ s: String) -> Bool }
```

**`getPanel` flow:**
1. No services → `signedOut`.
2. Otherwise call `matcher.resolve`:
   - `.notEmulator` or `.noRom` → `hidden`.
   - `.notMatched` → `notMatched`.
   - `.matched`, with cached progress → reply right away with `matched(stale: true, savedAt)`, then fetch in the background and push `matched(stale: false)` through `update`.
   - `.matched`, nothing cached → fetch, then reply.
3. A failed fetch → `failed(cached:savedAt:)`.

`refreshPanel` always fetches. Replies are encoded with `JSONEncoder` using `.sortedKeys`.

- [ ] **Step 1:** Write the failing tests:

```swift
@Test func routesAndWrapsResult() async   // fake handler echoes params → respond(to: #"{"id":7,"method":"x","params":{"a":1}}"#) == #"window.__sra.receive({"id":7,"result":{"a":1}})"#
@Test func wrapsErrors() async            // handler throws → the JS contains "\"id\":7" and "\"error\""
@Test func ignoresMalformed() async       // respond(to: "nope") == nil
@Test func onlyRetroAchievementsURLs()    // "https://retroachievements.org/game/1" → true; "https://evil.example/" → false; "javascript:alert(1)" → false
@Test func fetchFailureFallsBackToCache() async
// Services(credentials:dataDirectory: temp, transport: one that returns 500 for every request)
// pre-fill DiskCache with gamelist-7 = [smbEntry] and progress-1446
// getPanel {shortcut: smb()} → payload.updatedText starts with "Last updated"
```

- [ ] **Step 2:** Run `swift test --filter BridgeTests`. Expected: fails.
- [ ] **Step 3:** Implement, and wire `AppModel`: `openSettings` → `show(.settings)`, `openAddGames` → `show(.addGames)`, `openURL` → `NSWorkspace.shared.open`, `log` → `Log`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.

### Task 11: Desktop panel in Steam

**Files:**
- Modify: `steam/inject.js` (replace the placeholder, keeping `listShortcuts` and `addShortcuts` from Task 9)
- Create: `THIRD_PARTY_NOTICES.md` (MIT notices for rcheevos and achievement-companion)

**Interfaces:**
- Consumes: `docs/steam-internals.md` Q2–Q4 and Q7–Q10; the bridge protocol (Task 10); the `PanelPayload` fields (Task 6).
- Produces: `window.__sra = { receive, update, dispose, listShortcuts, addShortcuts }`.
- Produces: one module object `steamUI` in `inject.js` that holds every Steam-specific lookup (window document, route, stores, `findClass`, insertion points). Task 12 adds Big Picture lookups to it.

**Behavior:**
- **Start:** call `window.__sra?.dispose?.()` first. `dispose()` clears timers, unregisters the lifetime callback, and removes every `[data-sra]` node, including the style tag.
- **Calling the app:** `call(method, params)` returns a Promise with a 20 s timeout. On timeout, leave the screen as it is and log.
- **Every 500 ms:**
  - Read the appid (Q3).
  - If it changed: remove the panel. If the app is a shortcut (`app_type` `1073741824`), read its exe and launch options (Q4) and `call("getPanel", {shortcut})`.
  - If it's unchanged and the panel node is missing: re-insert the last payload.
- **Stale replies:** ignore any reply or `update` whose appid isn't the current one.
- **Drawing, by `state`:**
  - `hidden` → draw nothing.
  - `signedOut` → the message, plus a button `Open Steam RetroAchievements` that calls `openSettings`.
  - `notMatched` → the message, plus a button `Choose game`.
  - `error` → the message.
  - `noSet` → the game header, details, and message.
  - `matched`:
    - Game header with icon and title, plus a `View on RetroAchievements` link that calls `openURL` with `raURL`.
    - The notice, if there is one.
    - The summary: text, a progress bar at `percent`, `pointsText`, and `hardcoreText`.
    - Up to 10 badges, then a `+N` overflow. Hovering a badge shows a card with title, description, points, `unlockedText`, and `rarityText`.
    - Button `View all achievements`, link `Wrong game?`, the details list, and `updatedText`.
- **`View all achievements`:** an overlay listing every row. Locked badges are greyed out and hardcore rows get a gold border. It has a `Close` button and also closes with Esc.
- **`Choose game` / `Wrong game?`:** an overlay with:
  - A console `<select>` filled from `consoles`, preselecting the payload's `consoleId`.
  - A search box that calls `searchGames` 300 ms after typing stops.
  - Result rows showing icon, title, and `<N> achievements`. Clicking a row calls `chooseGame` and draws the returned payload.
- **After a game quits (Q7):** when a shortcut stops running and it's the current appid, wait 10 s, then `call("refreshPanel", {shortcut})`.
- **Add Games button:** add `Add Games` at the Q8 library location; it calls `openAddGames`.
- **Style:**
  - One `<style data-sra>` tag, using Steam's font and colors from Q9.
  - Adapt the panel CSS from achievement-companion's `frontend/styles/panelCss.ts`, after the user approves fetching that one file, and keep its MIT notice in a comment.
  - If Q10 found images blocked, load every image through `call("image", {url})`.
- **Errors:** every timer, callback, handler, and `__sra` function goes through `safe(fn)`, which reports errors through `log`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `bash scripts/build-app.sh` and open the test shortcut from Task 1. Expected: a Super Mario Bros. (NES) panel with the notice `Can't find this game's ROM file.` and the RA achievements listed.
- [ ] **Step 3:** Create `~/ROMs/nes/Super Mario Bros. (World).nes` as a 40 KiB file with an iNES header and random bytes. Navigate away from the page and back. Expected: the notice now reads `RetroAchievements doesn't recognize this ROM version, so RetroArch won't unlock these achievements.`
- [ ] **Step 4:** Hover a badge. Expected: a card with rarity. Open `View all achievements`. Expected: the full list, closed by Esc. Open `Wrong game?`, search `mario`, and pick another game. Expected: the panel switches to that game, and it's still there after Steam restarts.
- [ ] **Step 5 (re-render and race check):**
  - Add a second test shortcut, `Zzz Unknown Game`, using the same exe and a made-up ROM path.
  - Open a Steam game's page, then go back.
  - Switch between the two test shortcuts 5 times quickly.
  - Expected: each page shows only its own panel. The second shortcut shows `Choose game`.
- [ ] **Step 6 (double-injection check):** quit and reopen the app. Then run `node scripts/steam-eval.mjs` with the Q2 document expression and `.querySelectorAll('[data-sra-panel]').length`. Expected: `1`.
- [ ] **Step 7 (break check):** quit the app. Expected: Steam keeps working, with no error dialogs, and pages still open.

### Task 12: Big Picture panel

**Files:**
- Modify: `steam/inject.js`

**Interfaces:**
- Consumes: `docs/steam-internals.md` Q12; the `steamUI` module and the `getPanel` flow from Task 11.

**Behavior (spec "Big Picture mode"):**
- When the Q12 Big Picture document is present, run the same heartbeat against its route.
- Draw one scrollable block on the Q12 insertion point: game header, notice, summary, details, and every row from the full list, all inline.
- No overlays and no buttons there.
- Use the same `data-sra` cleanup and `safe()` rules as Task 11.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build. Open Big Picture and the test shortcut's game page. Expected: the block shows the same data as the desktop panel, with no extra buttons.
- [ ] **Step 3:** Leave Big Picture. Expected: the desktop panel still works. Re-run Task 11 Steps 5–7.

### Task 13: README, acceptance with the user, commit

**Files:**
- Create: `README.md`

**README contents:**
- What the app does, and which emulators it supports.
- Requirements: sign in to RetroAchievements inside each emulator you use.
- The three ways to add games, including the exact Launch Options for "Add a Non-Steam Game". For RetroArch: `-L "/Users/<you>/Library/Application Support/RetroArch/cores/<core>_libretro.dylib" "/Users/<you>/ROMs/<console>/<game file>"`. For each standalone emulator, its `launchOptions` form.
- Keep ROMs in `~/ROMs`.
- After a Steam update, use `Restart Steam` from the menu.
- Uninstall from Settings.
- Rebuild with `scripts/build-app.sh` (for the builder only).

**Acceptance.** Each step names the spec's "Done means" number it checks:

- [ ] **Step 1:** Ask the user's approval to install RetroArch, and whichever standalone emulators they want, from their official sites. For each one:
  - Confirm the Emulator table's launch form by opening a ROM from the command line. Fix the table and its tests if one differs.
  - Confirm the RetroArch cores folder.
  - **User:** sign in to RetroAchievements inside each emulator, and download cores in RetroArch's Online Updater.
- [ ] **Step 2:** Find a free homebrew game with an RA set: an `API_GetGameList` title starting with `~Homebrew~` whose developer offers a free download. Ask approval to download it into `~/ROMs/<console>/`.
- [ ] **Step 3 (Done 1, 2):** Add the game three ways:
  - Through the Add Games window.
  - Through Steam ROM Manager, if the user wants it installed. Skip this way if they don't.
  - Through "Add a Non-Steam Game" with the README's launch options.
  
  Expected: each page shows the panel with no notice, meaning a verified match. Counts, points, and dates match retroachievements.org.
- [ ] **Step 4 (Done 3):** **User:** play the game from Steam, earn one achievement, and quit. Expected: within about 10 s, the panel shows it unlocked.
- [ ] **Step 5 (Done 4):** quit and reopen Steam. Expected: the panel returns. Then log out of the Mac and back in, or reboot. Expected: the app starts by itself and the panel returns.
- [ ] **Step 6 (Done 5):** quit the app. Expected: Steam works normally.
- [ ] **Step 7 (Done 6, 7):**
  - `uninstallRemovesEverything` passes.
  - Run the real Uninstall only if the user wants to; reinstall afterwards with `scripts/build-app.sh`.
  - Confirm every user step in this task used windows only.
- [ ] **Step 8:** Remove the test shortcuts (`Super Mario Bros.`, `Zzz Unknown Game`) and the fake ROM.
- [ ] **Step 9:** Run `swift test`. Expected: all pass. Then make the single commit: `git add -A && git commit -m "feat: RetroAchievements in the macOS Steam client"`, with the attribution line.
