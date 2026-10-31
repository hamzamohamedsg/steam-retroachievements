# Steam RetroAchievements

A macOS menu bar app that shows your [RetroAchievements](https://retroachievements.org) inside the Steam client. Open a retro game's page in your Steam library and you see its achievements, your progress, and the game's details, styled like Steam's own achievements. It works in the normal desktop library and in Big Picture mode.

It supports every RetroAchievements emulator that runs on a Mac: RetroArch, DuckStation (PS1), PCSX2 (PS2), PPSSPP (PSP), Dolphin (GameCube/Wii), Flycast (Dreamcast), and SkyEmu (Game Boy family).

## How it works

- The app turns on Steam's built-in developer switch: an empty file named `.cef-enable-remote-debugging` inside Steam's app bundle. With it, Steam lets local programs talk to its interface on `127.0.0.1:8080`.
- The app adds one small script to Steam's interface. The script draws the panel, and the app does everything else:
  - fingerprints your ROMs with RetroAchievements' own code (rcheevos)
  - talks to the RetroAchievements API
  - keeps your Web API key in the macOS Keychain, so Steam never sees it
- The app opens no network ports and never changes anything in your Steam account. It only adds library shortcuts when you ask it to.

## Setup

1. Open **Steam RetroAchievements** from your Applications folder.
2. Enter your RetroAchievements username and Web API key. The key is on [retroachievements.org/settings](https://retroachievements.org/settings). Click **Sign In**.
3. If the menu bar shows **Restart Steam to finish setup**, click **Restart Steam**. Steam only reads the developer switch when it starts.
4. Sign in to RetroAchievements inside each emulator you play with. The emulator is what unlocks achievements; this app only shows them.

Keep your ROMs in the `ROMs` folder in your home folder (`~/ROMs`). macOS stops background apps from reading the Desktop, Documents, Downloads, iCloud Drive, and external drives without extra permission.

## Adding games to Steam

You can add games any of these ways:

- **Add Games window:** from the menu bar icon, or the **Add Games** button next to Steam's own "Add a Game". It scans a folder, using one subfolder per console (`snes`, `psx`, `gba`, …), picks an installed emulator for each game, and adds the games to Steam in one go.
- **Steam ROM Manager:** shortcuts it creates work as they are.
- **Steam's "Add a Non-Steam Game":** pick the emulator app, then open the shortcut's **Properties**:
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
- **Panel gone after a Steam update:** use **Restart Steam** from the menu bar. If it's still missing, Steam changed something inside and the app needs an update.
- **Log file:** `~/Library/Logs/steam-retroachievements.log`.

## Uninstalling

Open Settings, click **Uninstall…**, and confirm. This removes:
- the developer switch
- your saved sign-in
- cached data and the log
- the login item

It then moves the app to the Trash. Restart Steam afterwards. Games the app added stay in your library.

## Building (for developers)

You need Apple's Command Line Tools (no Xcode required).

```bash
scripts/test.sh          # run the tests
scripts/build-app.sh     # build, sign ad-hoc, install to ~/Applications and open
node scripts/steam-eval.mjs 'MainWindowBrowserManager.m_lastLocation'   # poke at Steam's UI
```

`docs/steam-internals.md` records what was verified about Steam's interface on macOS. Read it first when a Steam update breaks something.
