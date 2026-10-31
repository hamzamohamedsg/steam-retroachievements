<img src="docs/icon.png" width="128" alt="">

# Steam RetroAchievements

An app for macOS, Linux and Windows that shows your [RetroAchievements](https://retroachievements.org) inside the Steam client. Open a retro game's page in your Steam library and you see its achievements, your progress, and the game's details, styled like Steam's own achievements. It works in the normal desktop library and in Big Picture mode.

It supports RetroArch, DuckStation (PS1), PCSX2 (PS2), PPSSPP (PSP), Dolphin (GameCube/Wii), Flycast (Dreamcast), and SkyEmu (Game Boy family). On macOS it's a menu bar app; on Linux and Windows it's a background program with no window. Signing in and adding games happen inside Steam on every platform.

> Linux and Windows support is new: both are built, but neither has been run on a Linux or Windows machine yet.

## How it works

- The app turns on Steam's built-in developer switch: an empty file named `.cef-enable-remote-debugging` in Steam's install folder (inside Steam's app bundle on macOS, `~/.steam/steam` on Linux, the folder with `steam.exe` on Windows). With it, Steam lets local programs talk to its interface on `127.0.0.1:8080`.
- The app adds one small script to Steam's interface. The script draws the panel, and the app does everything else:
  - fingerprints your ROMs with RetroAchievements' own code (rcheevos)
  - talks to the RetroAchievements API
  - keeps your Web API key: in the macOS Keychain, or on Linux and Windows in a file only your user account can read. You type the key into a dialog inside Steam, so Steam's interface sees it once while you sign in.
- The app opens no network ports and never changes anything in your Steam account. It only adds library shortcuts when you ask it to.

## Setup

1. Start the app:
   - **macOS:** open **Steam RetroAchievements** from your Applications folder.
   - **Linux:** unpack `steam-retroachievements-linux.tar.gz` and run `./steam-retroachievements` from a terminal. Keep `inject.js` and `icon.png` next to it. On a Steam Deck, do this in Desktop Mode. The first run also adds **Steam RetroAchievements** to your app menu, so after that you can start it from there.
   - **Windows:** unzip `steam-retroachievements-windows.zip` from the [latest release](../../releases/latest) and run `SteamRetroAchievements.exe`. It has no window; keep all the files in the folder together. If SmartScreen warns, choose **More info → Run anyway** (the program isn't signed).
2. Restart Steam if asked. Steam only reads the developer switch when it starts. On macOS, the menu bar shows **Restart Steam to finish setup** with a button. On Linux the terminal and the log say so, on Windows the log; quit Steam and open it again yourself.
3. When Steam connects, a **Steam RetroAchievements** dialog opens in Steam's library. Enter your RetroAchievements username and Web API key; the key is on [retroachievements.org/settings](https://retroachievements.org/settings). Click **Sign In**. Signing in also turns on **Open at login**: a login item on macOS, a systemd user service on Linux (it runs in Steam Deck's Game Mode too), a Run registry entry on Windows.
4. Sign in to RetroAchievements inside each emulator you play with. The emulator is what unlocks achievements; this app only shows them.

You can open the dialog again from the **RetroAchievements** button at the bottom of Steam's library, next to **Add a Game**.

Keep your ROMs in the `ROMs` folder in your home folder (`~/ROMs`), or EmuDeck's `~/Emulation/roms`. On macOS, background apps can't read the Desktop, Documents, Downloads, iCloud Drive, or external drives without extra permission.

## Adding games to Steam

You can add games any of these ways:

- **Add Games dialog:** click the **Add Games** button next to Steam's own "Add a Game" (or **Add Games…** in the macOS menu bar). It scans a folder, using one subfolder per console (`snes`, `psx`, `gba`, …), picks an installed emulator for each game, and adds the games to Steam in one go.
  - On Linux it finds emulators on your `PATH` (`retroarch`, `duckstation-qt`, `pcsx2-qt`, `PPSSPPSDL`, `dolphin-emu`, `flycast`, `SkyEmu`) and Flathub installs. It doesn't find AppImages unless they're on your `PATH` under those names.
  - On Windows it looks on your `PATH`, in `C:\RetroArch-Win64`, and in `Program Files` / `AppData\Local\Programs\<emulator>`.
- **Steam ROM Manager:** shortcuts it creates work as they are, as long as they launch the emulator directly rather than through a wrapper script. On macOS, with Steam ROM Manager closed, `scripts/srm-parsers.py` sets it up with one parser per console, reading the same `~/ROMs/<console>` folders and pulling artwork from SteamGridDB. Re-run it after downloading new RetroArch cores.
- **Steam's "Add a Non-Steam Game" (macOS):** pick the emulator app, then open the shortcut's **Properties**:
  - Set **Target** to `"/usr/bin/arch"`. Steam on macOS starts games as Intel apps, which can't load Apple Silicon cores; `arch -arm64` keeps the emulator native.
  - Set **Launch Options** to `-arm64 "<emulator executable>"` followed by the emulator's arguments:

  | Emulator | Launch Options |
  |---|---|
  | RetroArch | `-arm64 "/Applications/RetroArch.app/Contents/MacOS/RetroArch" -L "/Users/<you>/Library/Application Support/RetroArch/cores/<core>_libretro.dylib" "/Users/<you>/ROMs/<console>/<game file>"` |
  | DuckStation, PCSX2 | `-arm64 "<emulator executable>" -batch -- "/Users/<you>/ROMs/<console>/<game file>"` |
  | Dolphin | `-arm64 "<emulator executable>" -b -e "/Users/<you>/ROMs/<console>/<game file>"` |
  | PPSSPP, Flycast, SkyEmu | `-arm64 "<emulator executable>" "/Users/<you>/ROMs/<console>/<game file>"` |

  The emulator executable is inside its app, for example `/Applications/DuckStation.app/Contents/MacOS/DuckStation`.

A shortcut with no ROM in its launch options just opens the emulator's menu, so it gets no panel.

## When something looks wrong

- **"Couldn't check this ROM version":** the app can't fingerprint `.chd` or `.7z` files yet. It matched the game by name. Your emulator can still unlock achievements.
- **"RetroAchievements doesn't recognize this ROM version":** this exact ROM isn't one RetroAchievements supports, so the emulator won't unlock achievements for it.
- **Wrong game:** click **Wrong game?** on the panel and pick the right one. The app remembers your choice.
- **Panel gone after a Steam update:** restart Steam (macOS: **Restart Steam** in the menu bar). If it's still missing, Steam changed something inside and the app needs an update.
- **Log file:** `~/Library/Logs/steam-retroachievements.log` on macOS, `~/.local/share/steam-retroachievements/steam-retroachievements.log` on Linux, `%LOCALAPPDATA%\steam-retroachievements\steam-retroachievements.log` on Windows.

## Uninstalling

In Steam, open the **RetroAchievements** dialog, click **Uninstall…**, and confirm. This removes:
- the developer switch
- your saved sign-in
- cached data and the log
- open at login
- the app-menu entry (Linux)

On macOS it then moves the app to the Trash; on Linux and Windows, delete the program's folder yourself. Restart Steam afterwards. Games the app added stay in your library.

## Building (for developers)

You need Apple's Command Line Tools (no Xcode required).

```bash
scripts/test.sh          # run the tests
scripts/build-app.sh     # build, sign ad-hoc, install to ~/Applications and open
scripts/build-linux.sh   # cross-build build/steam-retroachievements-linux.tar.gz (x86_64)
node scripts/steam-eval.mjs 'MainWindowBrowserManager.m_lastLocation'   # poke at Steam's UI
```

`build-linux.sh` needs the swift.org toolchain from [swiftly](https://www.swift.org/install/macos/) and the matching Static Linux SDK (`swift sdk install <bundle URL> --checksum <sum>`, both listed on swift.org). For ARM Linux, run it with `SDK=aarch64-swift-linux-musl`.

**Windows:** `.github/workflows/windows.yml` builds the zip on GitHub's Windows machines and attaches it to each published release (or run it by hand with a tag). To build on Windows yourself with the Swift toolchain: The linker flags make it a windowless program, so no console opens at login:

```bash
rc.exe /fo .build\AppIcon.res Resources\AppIcon.rc
swift build -c release --product SteamRetroAchievements -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup -Xlinker .build\AppIcon.res
```

`rc.exe` comes with the Windows SDK that the Swift toolchain already needs; the first line puts the icon on the `.exe`.

Copy `.build\release\SteamRetroAchievements.exe` and `steam\inject.js` into one folder.

The icons come from `scripts/make-icon.swift` (`swift scripts/make-icon.swift`), which writes the macOS `.icns`, the Windows `.ico` and `docs/icon.png`.

`docs/steam-internals.md` records what was verified about Steam's interface on macOS. Read it first when a Steam update breaks something.
