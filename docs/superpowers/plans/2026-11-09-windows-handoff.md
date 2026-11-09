# Windows handoff: what's new since v0.1.12

**For:** the Claude agent on the Windows PC, which already knows this project and has a working build of v0.1.12 (`2baf69d`).
**Goal:** bring in the five new features below, run the tests, check each feature in real Steam, fix what's broken on Windows, and report back. All of this was written on a Mac and has **never been built or run on Windows**. It's on the branch `feat/app-gaps`, not merged and not version-bumped.

## Rules that came with this work

- **Never read, print, log or commit an API key.** `Sources/RACore/SteamGridDBKey.swift` must have `masked: [UInt8] = []` in anything committed. If a key has to be entered, the user types it themselves; don't ask for it in chat.
- **Don't click Update Now until a release built from this work is the latest on GitHub** (see "Update Now" below).

## Get the code

- **Branch:** check out `feat/app-gaps`. The **Windows build** workflow, run on that branch with an empty tag, produces a build that already contains the key: `gh workflow run windows.yml --ref feat/app-gaps`, then download the `steam-retroachievements-windows` artifact.
- **Patch:** if the user copied over `windows-handoff.patch`, apply it to a clean tree at `70a31e0` or `2baf69d` (they differ only in README screenshots) with `git apply --whitespace=nowarn path\to\windows-handoff.patch`. If it fails on line endings, use a checkout made with `core.autocrlf=false`.

If the build says `cannot find 'sevenzip_init' in scope`, delete the build folder and rebuild: stale module caches don't pick up the new C headers.

## What changed and what was decided

**1. Artwork in Add Games, from SteamGridDB** (`SteamGridDB.swift`, `SteamGridDBKey.swift`, `addArtwork` in `inject.js`)
- After adding games, the app fetches portrait, banner, hero, logo and icon. `SetCustomArtworkForApp` applies the first four, and `SetShortcutIcon` applies the icon from a saved file in the app's data folder under `icons\<appid>.png`.
- It's deliberately built directly. Bundling Steam ROM Manager was rejected: it's GPL-3.0, 37–92 MB, and closes Steam.
- Only games added from now on get art. It takes the first search hit by title, and the first error (rate limit, no network) ends the run without affecting the add. There's no art picker.
- `HTTPTransport.get` now takes `headers:`.
- **Key handling:** the key is the `STEAMGRIDDB_API_KEY` GitHub secret, already set. `scripts/embed-sgdb-key.sh` writes it, XOR-masked, into `SteamGridDBKey.swift` at build time, in a new CI step after the tests. It's sent only as an `Authorization` header to `www.steamgriddb.com` and never reaches Steam's page. Masking only keeps it out of plain text. A build without the key works but adds no art.
- To test art from a local build, the user sets the key in their own terminal and runs the embed script:
  ```powershell
  $env:STEAMGRIDDB_API_KEY = Read-Host -MaskInput 'SteamGridDB key'
  bash scripts/embed-sgdb-key.sh
  ```
  After building, immediately restore the empty file:
  ```powershell
  Set-Content Sources\RACore\SteamGridDBKey.swift "enum SteamGridDBKey {`n    static let masked: [UInt8] = []`n}"
  Remove-Item Env:STEAMGRIDDB_API_KEY
  ```

**2. Missable tags and beaten/mastered status** (`RAModels.swift`, `RAClient.swift`, `PanelPayload.swift`, `inject.js`)
- The progress request now sends `a=1`. API fields were confirmed from RetroAchievements' docs and source. The ribbon and percentage are unchanged.
- Own views show a **Missable** tag, with a "!" on icons too small for the word. Steam's own views get a `Missable: ` description prefix.

**3. `.7z` and GameCube `.rvz` fingerprinting** (`Vendor/lzma-sdk-26.06`, `Sources/CHDReader/rvz_reader.c`, `sevenzip_reader.c`, `utf8_file.h`, `RomHasher.swift`)
- Not done, on purpose: Wii `.rvz` needs a hash tree and AES rebuild that can't be checked against real data, so it keeps name matching. MS-DOS `.7z` and bzip2 RVZ stay unsupported.
- Decoding is capped at 512 MiB. RVZ fixtures come from reading the spec; no real Dolphin-made file has been tried.

**4. One-click updates** (`Sources/RACore/Updater.swift`, `AppModel.swift`, `Tray.swift`, `App.swift`, Steam dialog)
- Flow: pick this platform's asset, verify GitHub's `sha256:` digest, extract into a private folder beside the install, run the new copy with `--version`, swap by renames with undo, relaunch. Any failure keeps the old copy and opens the release page.
- On Windows the running exe and DLLs are renamed to `*.sra-old-*`, and `removeLeftovers` deletes them on next start. The new copy takes over from the old one through the existing replace-running-copy logic.
- Every future release must keep answering `--version`. Users on v0.1.12 have to install the next release by hand, once.

**5. Open Log and Copy Diagnostics** (`Sources/RACore/Diagnostics.swift`, `BridgeHandler.swift`, `AppModel.swift`, a Troubleshooting section in the `inject.js` settings dialog)
- The app scrubs the text before the page gets it: no username, API key or URL query strings, and the home folder becomes `~`. `openLog` takes no input, so the page can't choose a file.
- Known limit: after sign-out the username is unknown, so older log lines lose it only inside query strings.
- Clipboard tries `navigator.clipboard`, then `execCommand`, then shows the text selected in the dialog.

## Tests

Run the suite. On macOS the only failure is `messageOverTheLimitEndsTheConnection` in `DevToolsSocketTests`, which also fails on `2baf69d`. Report every Windows failure by name. New suites: `ArtworkTests`, `RomFormatTests`, `UpdaterTests` (uses `tar.exe`) and `DiagnosticsTests`, plus additions to `RAClientTests`, `PanelPayloadTests` and `RomHasherTests`.

Also confirm the new build answers `--version` with exit code 0, without a console or second tray icon.

## Check in real Steam

So far these have only been tested with fakes. Report pass, fail or couldn't test for each.

| # | Check | Pass looks like |
|---|---|---|
| 1 | Add one test game through **Add Games** | All art appears without restarting Steam, **each image in the right slot**. Asset types 0 (portrait), 3 (banner), 1 (hero) and 2 (logo) came from memory and are unconfirmed on any client |
| 2 | Same game | The icon file exists and shows in the library list |
| 3 | A game with a missable achievement | Tag, description prefix and "!" all look right. Their layout hasn't been seen on any platform |
| 4 | A game with an award | **Mastered**, **Completed**, **Beaten (Hardcore)** or **Beaten** by the progress summary |
| 5 | Scan a `.7z` ROM and a real GameCube `.rvz` | No "Couldn't check this ROM version", and the right game matches. Include a path with non-ASCII characters |
| 6 | **Open Log** | The log opens in the default app |
| 7 | **Copy Diagnostics**, paste into Notepad | Version, OS and emulators are present. No username, key, query string or `C:\Users\<name>` anywhere. Clipboard in Steam's CEF is untested |

### Update Now

The latest public release, v0.1.12, doesn't understand `--version`. The updater would launch it as a normal program, which would hang the update and could replace the running copy. So only test this once a release built from this work is the latest:

1. Make a scratch build with `UpdateChecker.currentVersion` lowered by one version, in a throwaway folder. Don't commit that change.
2. Start it, and choose **Update Now** from the tray.
3. Pass: every file is replaced, `--version` reports the new version, one tray icon is running, and `*.sra-old-*` files are gone after the next start.
4. Repeat with the folder read-only. Pass: the old copy keeps running and the release page opens.

If no such release exists yet, report this as not tested.

## Report back

In under 300 words: the test result, the Steam table, each fix and why it was needed, and exactly what remains untested. Don't say something works unless you saw it work.
