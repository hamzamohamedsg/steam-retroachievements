# RetroAchievements in the macOS Steam client: design

Date: 2026-10-30
Status: approved 2026-10-30, then amended at the user's request: a GUI app instead of Terminal steps
Working name: `steam-retroachievements` (the "helper")

## Intent

The user has a RetroAchievements (RA) account and will play retro games on their Mac through RetroArch, launched from the Steam desktop client as non-Steam game shortcuts. They want each of those games' Steam library pages to show the RA game details and achievements so it looks like a native Steam game with achievements, in Steam's own UI. Emuchievements does this on the Steam Deck.

No Mac solution exists today (recon, 2026-10-30):

- Decky Loader (Emuchievements' host) runs only on the Steam Deck and Linux.
- Millennium (Steam plugin loader) officially supports Windows and Linux only. Mac support shipped once in v3.0.0, then broke. The fix, PR SteamClientHomebrew/Millennium#841, is open and unmerged, and maintainers say Mac won't be officially supported because it must be reapplied after every Steam update. There is no Mac build to download.
- The Millennium plugin `otowm/achievement-companion` (MIT) already draws RA achievements on non-Steam game pages, on Windows.

The user chose my recommendation: a small standalone Mac helper that injects into Steam itself and doesn't depend on Millennium. The user accepts that Steam updates will sometimes break the display until it gets fixed.

## Goals

1. On the Steam desktop library page of any RetroArch shortcut, show the RA achievements and game details, styled like Steam's own achievements UI.
2. Work no matter how the game got into Steam: through the helper's own "add games" flow, through Steam ROM Manager, or through Steam's "Add a Non-Steam Game".
3. Let the helper add RetroArch games to Steam from a ROM folder, with Steam still running.
4. Match every game to its RA entry. Use RA's official ROM fingerprint for every console RA supports, fall back to name matching, then to a one-time manual pick that is remembered.
5. Start at login, wait for Steam, and reconnect by itself when Steam restarts.
6. Refresh when a game page opens and shortly after a game quits, so new unlocks appear without restarting Steam.
7. Support every RetroAchievements emulator that has a macOS build and loads ROM files (user's decision: "all emulators that retroachievements support"; list taken from RA's emulator support page on 2026-10-31):
   - RetroArch: all its consoles.
   - DuckStation: PlayStation.
   - PCSX2: PlayStation 2.
   - PPSSPP: PSP.
   - Dolphin: GameCube and Wii.
   - Flycast: Dreamcast and NAOMI/Atomiswave arcade.
   - SkyEmu: Game Boy, Game Boy Color, and Game Boy Advance.
8. Show the panel in Big Picture mode too. The user removed Big Picture from the non-goals. It gets built last, after the desktop panel works (my call on order).

## Non-goals

- Unlocking achievements. RetroArch does that once the user signs in to RA inside RetroArch.
- In-game unlock popups. RetroArch shows its own.
- Windows and Linux.
- Artwork for games the helper adds. Steam ROM Manager handles artwork.
- RA emulators with no macOS build: the RA-branded Windows emulators (RAVBA, RANes, RASnes9x, RAMeka, RAppleWin, RAQUASI88, RAProject64), WinArcadia, Luna's Project64, Linkboy, and the Android, iOS, and Xbox ports. Also Playback, which reads real cartridges through GB Operator hardware instead of ROM files.

## Anti-goals (failure even if it technically works)

- Breaking Steam. If any part of the helper fails, Steam must look and work exactly as it does without the helper: no blank pages, errors, or freezes. The panel just doesn't appear.
- Touching anything beyond the screen and library shortcuts: no account, purchase, friends, or cloud actions.
- Looking bolted on, with fonts, colors, or layout that don't match Steam.
- Showing name-matched achievements as if RetroArch will award them when the ROM's fingerprint isn't one RA recognizes. RetroArch won't unlock anything for an unrecognized ROM, so the page must say so. The opposite is also a failure: warning that achievements won't unlock when the helper simply couldn't check the ROM.
- Keeping the API key in plain text, in Steam's web storage, or anywhere Steam's page code can read it.
- Opening a network port on the Mac.
- Making the user open Terminal for anything. Setup, sign-in, restarting Steam, adding games, and uninstalling all happen in the app's windows (user's decision).

## Constraints and verified facts

### This Mac (checked 2026-10-30)

- macOS 27.0.1, Apple Silicon (arm64).
- Command Line Tools only, no full Xcode. Swift 6.3 and Node 22 are available. Everything must build without Xcode.
- Steam is installed at the standard location (`/Applications/Steam.app`, data in `~/Library/Application Support/Steam/`).
- RetroArch isn't installed yet and there are no ROMs yet.
- This project folder is on the Desktop, which macOS protects, so the helper must not run from here (see Install).

### Steam's debug switch (the hook everything depends on)

- An empty marker file `.cef-enable-remote-debugging` placed beside the Steam executable, at `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging`, makes Steam serve the Chrome DevTools Protocol (CDP) on `127.0.0.1` (default port 8080). `http://127.0.0.1:8080/json` lists targets. The target titled `SharedJSContext` runs Steam's UI code. Source: Millennium's macOS launcher in PR #841.
- **Not yet tested on this Mac.** The first build task is to create the file, restart Steam, and confirm the port answers. If it doesn't, stop and come back to the user.
- The marker sits inside Steam's app bundle, which a Steam update may replace. The helper must check for it, recreate it if missing, and show "Restart Steam to finish setup" in its menu bar menu and Settings window, with a Restart Steam button. It quits and reopens Steam only when the user clicks that button and confirms, since restarting could kill a running game (my call).

### Steam UI internals

These come from `achievement-companion` on Windows. They may differ on Mac, so verify each one.

- The desktop window is a popup named `SP Desktop_uid0`. Millennium's `AddWindowCreateHook` finds it there, and the helper needs its own equivalent, such as Steam's popup manager in `SharedJSContext` or the window's own CDP target.
- The current route is `MainWindowBrowserManager.m_lastLocation`. Game pages match `/library/app/<appid>`.
- `appStore.GetAppOverviewByAppID(id)` returns `display_name`, and `app_type === 1073741824` marks a non-Steam shortcut.
- Steam's React is exposed as `SP_REACT` / `SP_REACTDOM` (`createRoot`), which can mount components into Steam's DOM.
- Steam's CSS class names are hashed and change between Steam updates. `achievement-companion` hard-codes them; avoid that where possible.
- A shortcut's exe, launch options, and start folder are readable from Steam's client stores. Shortcuts can be added live through `SteamClient.Apps.AddShortcut(...)` and its setters. Confirm the exact calls on the current client.

### RetroAchievements Web API

Documented at api-docs.retroachievements.org. Every call needs `y=<web API key>`.

- `API_GetGameList.php?i=<consoleId>&h=1`: every game for one console, with its supported ROM hashes. This is both the fingerprint lookup table and the name-matching list. Cache it per console.
- `API_GetGameInfoAndUserProgress.php?g=<gameId>&u=<user>`: game details (`Publisher`, `Developer`, `Genre`, `Released`, `ImageIcon`, `ImageBoxArt`, `NumDistinctPlayers`) and achievements (`Title`, `Description`, `Points`, `BadgeName`, `type`, `NumAwarded`, `NumAwardedHardcore`, `DateEarned`, `DateEarnedHardcore`), plus `UserCompletion` / `UserCompletionHardcore`.
- `API_GetUserProfile.php?u=<user>`: checks that credentials work.
- Badge images are at `https://media.retroachievements.org/Badge/<BadgeName>.png`, and the locked look is `<BadgeName>_lock.png`.
- RA has two unlock modes, hardcore and softcore. Both count as unlocked, and hardcore unlocks are marked.

### ROM fingerprints

- Use `rcheevos`, RA's official C library (MIT), which RetroArch itself uses. It has an iterator API (`rc_hash_initialize_iterator`, `rc_hash_iterate`, `rc_hash_generate`) and a default CD reader for `.cue`/`.bin`, `.iso`, and `.gdi`. Console IDs are its `RC_CONSOLE_*` constants, the same numbers the RA API uses.
- rcheevos has **no CHD support** built in.
- Arcade (MAME/FBNeo) fingerprints come from the file name, not the contents. Let rcheevos handle that rule and don't unzip arcade ROMs.

### macOS file permissions

- macOS blocks background programs from reading the Desktop, Documents, Downloads, iCloud Drive, external drives, and network drives until the user grants access. A grant is tied to the program's code signature. An ad-hoc signed binary gets a new signature on every rebuild, so file grants and Keychain access can be lost after each rebuild.
- Rebuilds are expected whenever a Steam update needs a fix. The app is signed ad-hoc, so after a rebuild macOS may ask once to allow Keychain access again. That's acceptable for v1 (my call). There are no file-access prompts, since ROMs live in `~/ROMs`.
- ROMs live in a `ROMs` folder directly in the user's home folder (`~/ROMs`), which macOS doesn't protect, so no file permission is needed (user's decision). The add-games folder picker opens there by default. If a shortcut's ROM is somewhere macOS blocks, the panel says so and suggests moving it to `~/ROMs`. v1 asks for no file permissions (my call).

## How it works

The user decided these: a standalone helper, not Millennium; RetroArch; all consoles; both ways of adding games; Steam's own look.

### Pieces

**1. The helper.** A Mac menu bar app instead of a Terminal tool (user's decision). The rest of this list is my call.

- `Steam RetroAchievements.app`: a menu bar icon and no Dock icon. It's written in Swift and SwiftUI as a Swift Package that builds with `swift build` under Command Line Tools. A script wraps the binary into the app, and rcheevos compiles in as a C target.
- It's installed to `~/Applications/` and starts at login through macOS Login Items (`SMAppService.mainApp`), with a toggle in its Settings window.
- Its jobs:
  - Make sure the marker file exists.
  - Every few seconds, check `http://127.0.0.1:8080/json` until Steam is up, then open a WebSocket to `SharedJSContext` and inject the Steam-side script. When Steam quits or its web helper restarts, go back to waiting and inject again.
  - Bridge requests from the Steam-side script with `Runtime.addBinding`: the page calls a named function and the helper answers by evaluating a callback in the page. This opens no port.
  - Read ROM files and compute fingerprints with rcheevos.
  - Make all RA API calls itself, so the key never reaches Steam's page code. Cache responses on disk in `~/Library/Application Support/steam-retroachievements/`.
  - Keep the RA username and Web API key in the macOS Keychain.
  - Keep remembered matches in a JSON file in that same folder.
  - Show its Settings and Add RetroArch Games windows.
  - Write a log to `~/Library/Logs/steam-retroachievements.log`.

**2. The Steam-side script.** It runs inside `SharedJSContext`, finds the desktop library window, watches navigation to `/library/app/<appid>`, decides whether the app is a RetroArch shortcut, asks the helper for data, and draws the panels with Steam's React and Steam's styles. It catches every one of its own errors, so a failure skips drawing and logs instead of reaching Steam's code. All Steam-specific lookups (window, route, stores, classes, insertion points) live in one module, so fixing a Steam update means editing one place. Language and build step are the builder's call. If `achievement-companion`'s TSX components are reused, a single esbuild bundle step using the installed Node is fine.

### Recognizing a RetroArch shortcut

- A shortcut counts if its exe or launch options point at RetroArch, for example `/Applications/RetroArch.app/Contents/MacOS/RetroArch …` or `open -a RetroArch --args …`. Check what Steam ROM Manager actually writes on Mac and support that format too.
- Pull the core (`-L <core path>`) and the ROM path from the launch options. Handle quotes and spaces.
- Work out the console from the core name using a core-to-console table (for example `snes9x_libretro` → SNES). If the core is unknown, use the ROM's extension. If that's still ambiguous, let rcheevos' iterator try each console that uses that extension.
- Standalone emulators (Goal 7) are recognized the same way, by their app path in the exe or launch options. The console comes from the emulator's own console list, narrowed by the ROM's extension through rcheevos when the emulator covers several consoles (for example Dolphin: GameCube or Wii). Each emulator's command-line form for opening a ROM is confirmed once it's installed.
- A RetroArch shortcut with no ROM path just opens RetroArch's menu, so it gets no panel. To add a game through "Add a Non-Steam Game", the user picks RetroArch and puts `-L "<core>" "<rom>"` in the shortcut's Launch Options. The README shows the exact form, and the helper's own add button is the easy route (my call).

### Matching a game to RA (in order)

1. **Remembered link**: a previous successful match or manual pick, keyed by ROM path. Store the fingerprint with it and recompute only when the file's size or modified date changes, since disc images are slow to hash.
2. **Fingerprint**: hash the ROM with rcheevos for that console and look it up in the console's cached game list. This is a *verified* match.
3. **Name**: compare the cleaned shortcut name or ROM file name (region and dump tags like `(USA)` and `[!]` removed) against the console's game titles. This is an *unverified* match, and the notice depends on why:
   - The helper fingerprinted the ROM and RA doesn't know that fingerprint: "RetroAchievements doesn't recognize this ROM version, so RetroArch won't unlock these achievements."
   - The helper couldn't fingerprint the format (`.chd`, `.7z`): "Couldn't check this ROM version." Don't claim RetroArch won't unlock them, because RetroArch can fingerprint those formats itself.
4. **Manual**: a "Choose game" control searches RA's games for that console, or all consoles if the console is unknown. The choice is remembered. Every match also gets a "Wrong game?" link to re-pick.

File types (my calls):

- `.zip` gets fingerprinted on the ROM inside, like RetroArch does, except for arcade.
- `.7z` and `.chd` get no fingerprint in v1. They go to name matching with the "Couldn't check" notice. CHD can be added later with libchdr.
- `.m3u` playlists for multi-disc games are followed to their first disc.

### What the user sees in Steam

This is on the page of a matched RetroArch game, modeled on the achievements block Steam shows for its own games.

- **Achievements panel**:
  - "You've unlocked X/Y (Z%)" with a progress bar, plus points earned out of total and the hardcore count.
  - A row of earned badges (newest first), then locked badges, with a "+N" overflow.
  - Hovering a badge shows title, description, points, unlock date, and rarity. Rarity is the share of players who have it, from `NumAwarded / NumDistinctPlayers`.
- **"View all achievements"** opens the full list, either in the page or as an overlay (builder's call):
  - Unlocked first (newest first), then locked.
  - Each row has a badge (greyed when locked), title, description, points, unlock date, and rarity.
  - Hardcore unlocks are marked, gold-bordered like RA's site.
- **Game details**: console, developer, publisher, genre, release date, and a "View on RetroAchievements" link that opens the RA game page in the browser.
- **States**:
  - Not set up: "Open Steam RetroAchievements to sign in.", with a button that opens its Settings window.
  - Loading: show cached data at once if there is any.
  - RA unreachable: show cached data with a "last updated" time, otherwise a quiet message.
  - Unverified match: show the matching notice from the Matching section.
  - No achievements: "No achievements for this game on RetroAchievements yet."
  - Not matched: show "Choose game".
- **Look**: Steam's fonts, colors, and spacing. Where Steam's hashed classes are needed, look them up at runtime from Steam's loaded style modules by their readable names rather than hard-coding the hashes. The method is the builder's call.

Shortcuts that launch none of the supported emulators, and real Steam games, are left untouched.

**Big Picture mode** (Goal 8, my calls):
- The same data appears on the Big Picture game page as one scrollable block: summary, game details, and the full achievements list.
- Controller navigation through custom buttons is unreliable in Big Picture, so there are no overlays or buttons there. Choosing a different game happens on the desktop page.

### Adding games

- An "Add RetroArch games" button inside Steam, plus the same item in the menu bar menu. Placement inside Steam is the builder's call; I'd suggest near Steam's own "Add a Game" button at the bottom of the library. Both open the app's Add RetroArch Games window, which starts at `~/ROMs` and has a Choose… button for another folder (my call).
- Scanning:
  - Subfolders with common console names (`snes`, `psx`, `n64`, `gba`, `megadrive`, …) map to consoles.
  - Other files map by extension when it's unambiguous.
  - Otherwise ask once which console that folder holds.
  - If an `.m3u` exists, use it instead of the individual disc files.
- Cores:
  - For each console, use an installed RetroArch core chosen by a default-core table. Read cores from RetroArch's cores folder, which is `~/Library/Application Support/RetroArch/cores/` by default (confirm after install).
  - If a console has no installed core, skip those games and name the core to download in RetroArch's Online Updater.
- Emulator per console: the window has an Emulator column. It defaults to the first installed emulator in this order (my call):
  - PlayStation: DuckStation, then RetroArch.
  - PlayStation 2: PCSX2.
  - PSP: PPSSPP, then RetroArch.
  - GameCube and Wii: Dolphin.
  - Dreamcast: Flycast, then RetroArch.
  - Game Boy, Game Boy Color, and Game Boy Advance: RetroArch, then SkyEmu.
  - Everything else: RetroArch.
- The window lists what it found (game, console, core, status) with checkboxes and an "Add N Games to Steam" button. It skips ROMs already in the library (same ROM path).
- Add shortcuts live through `SteamClient`. The name is the file name with tags cleaned, the launch options are `-L "<core>" "<rom>"`, and there's no artwork.

### Install, sign-in, uninstall

The user never opens Terminal (user's decision). The details are my calls:

- **Install**: the builder runs one build script. It compiles the app, signs it ad-hoc, and copies it to `~/Applications/Steam RetroAchievements.app`, out of the project folder on the Desktop, which macOS protects.
- **First launch**: the Settings window opens by itself.
  - The user enters their RA username and Web API key. A link points to retroachievements.org/settings, where the key is shown.
  - Sign In checks the credentials with `API_GetUserProfile` and saves them to the Keychain. It also turns on "Open at login" and creates the marker file.
  - If Steam is already running, the window then shows "Restart Steam to finish setup" with a Restart Steam button.
- **Sign-in later**: the same window shows "Signed in as …" with a Sign Out button.
- **Uninstall**: an Uninstall… button in Settings, after a confirmation, removes the marker file, Keychain item, data folder, log, and login item, then moves the app to the Trash and quits. After a Steam restart, Steam is exactly as before. Shortcuts the helper added stay as ordinary library entries.

### Refresh and caching

- When a page opens, show cached progress at once, fetch fresh data in the background, and update in place.
- When a RetroArch shortcut stops running, refresh after about 10 seconds so RA's server has recorded the unlocks. Use Steam's app lifetime notifications, for example `SteamClient.GameSessions.RegisterForAppLifetimeNotifications`, and confirm the call.
- Keep per-console game lists (with hashes) for 7 days and fetch again on a miss.
- Make no RA calls while Steam sits idle (my numbers and rules).

### Security

- While the marker file exists, any program on this Mac can drive Steam's interface through the debug port. It listens on `127.0.0.1` only, and Decky Loader and Millennium carry the same risk. The risk is accepted, and uninstall removes it.
- The helper opens no ports and talks only to `retroachievements.org` and `media.retroachievements.org` over HTTPS, plus Steam's local port.
- The API key stays in the Keychain and in the helper's memory, never in the Steam-side script.

## Reuse

- `otowm/achievement-companion` (MIT):
  - Window and route detection: `frontend/index.tsx`, `frontend/steam.ts`.
  - Steam-like panel, list, game search, and CSS: `frontend/components/AchievementPanel.tsx`, `AchievementsView.tsx`, `GameSearchModal.tsx`, `frontend/styles/panelCss.ts`.
  - Its Lua backend is Millennium-specific and is replaced by the helper. Keep its MIT notice.
- `RetroAchievements/rcheevos` (MIT) for fingerprints.
- RA API docs and `RetroAchievements/api-js` for response shapes.

## Testing

- Unit tests for parsing launch options (quotes, spaces, `open -a` form), cleaning names, the core-to-console and folder-to-console tables, and match ordering.
- A fingerprint self-check: the helper's hash of a sample file equals rcheevos' own output, using rcheevos' test vectors or a generated sample. In real use, compare against `API_GetGameHashes`.
- Manual acceptance on this Mac, with Steam running, as listed below. It uses a free homebrew game that has an RA set (RA tags these titles `~Homebrew~`), downloaded only after the user approves. The user installs RetroArch, or approves the builder installing it. The user signs in to RA inside RetroArch, since the builder can't enter their password, and earns one achievement for Done #3. The plan should put these user steps at the end.

## Done means

1. After install and one Steam restart, a RetroArch shortcut's page shows the panel and details. Counts, points, and dates match retroachievements.org for that game.
2. It works for a shortcut added by the helper, one added by Steam ROM Manager, and one added by "Add a Non-Steam Game" with the ROM in its launch options.
3. After unlocking an achievement in RetroArch and quitting the game, the panel updates without restarting Steam.
4. After quitting and reopening Steam, and after rebooting the Mac, the panel comes back with no user action.
5. With the helper stopped, or with its Steam-side code failing, Steam looks and works normally.
6. After uninstall, nothing the helper made is left except the library shortcuts it added.
7. Setup, sign-in, restarting Steam, adding games, and uninstalling all work from the app's windows, with no Terminal.

## Left to the builder

- Exact Steam internals: how to find the desktop window, the route, stores, and shortcut and lifetime calls on the Mac client.
- How to find Steam's hashed classes and where to insert the panels.
- The Steam-side script's language and build step.
- Where the in-Steam "Add RetroArch games" button goes.
- What's in the console, extension, and default-core tables, and the name-matching method.
- Bundle identifier.

## Risks

- Mac Steam internals may differ from the Windows ones `achievement-companion` relies on. Nothing about them is verified on Mac yet.
- Steam updates may delete the marker file, which the helper handles, or break selectors, which needs a fix each time.
- Valve could remove the marker-file switch. The fallback is how Millennium works on Mac: start Steam through a wrapper that passes a debugging flag. That's out of scope unless it happens.
