# Steam internals on macOS (verified 2026-10-31)

Steam client build 1792618285, macOS 27.0.1, arm64. All expressions run in `SharedJSContext` (`node scripts/steam-eval.mjs '<expr>'`).

## Open
- None.

## Q1 Bundle id, port, target
- `osascript -e 'id of app "Steam"'` → `com.valvesoftware.steam`
- With the marker present, Steam Helper starts with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=8080`. `http://127.0.0.1:8080/json` answered 4 s after `open -a Steam`, with a `page` target titled `SharedJSContext` that has a `webSocketDebuggerUrl`.

## Q2 Desktop window document
- `g_PopupManager.GetExistingPopup("SP Desktop_uid0").m_popup.document` → title `"Steam"`.
- Other popups (from `g_PopupManager.m_mapPopups`): `friendslist_uid0` and `contextmenu_N_uid0`.
- `g_PopupManager.AddPopupCreatedCallback` exists, but the heartbeat re-reads `GetExistingPopup` instead.

## Q3 Route
- `MainWindowBrowserManager.m_lastLocation.pathname` → `/library/home`, or `/library/app/2903182577` on a game page.
- Navigating for tests: `MainWindowBrowserManager.m_history.push("/library/app/<id>")`.

## Q4 Shortcut detection and details
- `appStore.GetAppOverviewByAppID(id)` → `{display_name, app_type: 1073741824}` for shortcuts.
- `appDetailsStore.GetAppDetails(id)` returns **null** for a shortcut until something subscribes. Use the subscription instead:

```js
new Promise(res => { const h = SteamClient.Apps.RegisterForAppDetails(id, d => { res(d); h?.unregister?.(); }); setTimeout(() => res(null), 3000); })
```

- The details have `strShortcutExe` (quoted, e.g. `"\"/Applications/RetroArch.app/Contents/MacOS/RetroArch\""`), `strShortcutStartDir`, `strShortcutLaunchOptions` (same as `strLaunchOptions`), and `bShortcutIsVR`.

## Q5 All shortcuts
- `[...appStore.m_mapApps.values()].filter(a => a.app_type === 1073741824).map(a => ({appid: a.appid, name: a.display_name}))`. Read exe and launch options for each one through Q4's subscription.

## Q6 Adding and removing shortcuts
- `await SteamClient.Apps.AddShortcut(name, exe, "", "")` resolves to the new appid (e.g. `2903182577`).
  - **It rejects with `{result: 2}` when the exe file doesn't exist.**
  - **It ignores `name`:** the new shortcut is named after the app.
- After adding, set every field explicitly:
  - `SteamClient.Apps.SetShortcutName(id, name)`
  - `SetShortcutExe(id, "\"<exe>\"")`, which accepts a path that doesn't exist yet
  - `SetShortcutStartDir(id, "\"<dir>/\"")`
  - `SetShortcutLaunchOptions(id, opts)`
- To remove: `SteamClient.Apps.RemoveShortcut(id)`.
- Test shortcut kept for later tasks: appid **2903182577**, name `Super Mario Bros.`, exe `"/Applications/RetroArch.app/Contents/MacOS/RetroArch"`, start dir `"/Applications/RetroArch.app/Contents/MacOS/"`, launch options `-L "/Users/mmtechstore/Library/Application Support/RetroArch/cores/fceumm_libretro.dylib" "/Users/mmtechstore/ROMs/nes/Super Mario Bros. (World).nes"`. It was created from `/System/Applications/Calculator.app` and then re-pointed with the setters.

## Q7 Lifetime notifications
- `SteamClient.GameSessions.RegisterForAppLifetimeNotifications(cb)` returns `{unregister}`.
- The callback shape (`unAppID`, `bRunning`) is unconfirmed until an emulator can actually launch. Check it in Task 13.

## Q8 Class maps and insertion points
- Webpack runtime: `webpackChunksteamui.push([[Math.random()], {}, r => { req = r }])`. It has no `req.c`. Call `req(id)` inside try/catch for each key of `req.m`. 499 modules export class maps (objects whose values are all strings).
- `findClass(key)`: build `key → Set(first hash of value)` across every map, then `document.querySelector([...set].map(h => "." + CSS.escape(h)).join(","))`. Keys repeat across maps, so always use the set.
- Game page keys seen: `AppDetailsMain`, `AppDetailsOverviewPanel`, `ColumnContainer`, `LeftColumn`, `RightColumn`, `RightColumnSection`, `SectionHeader`, `AppDetailsSection`, `PlayBar`.
  - **Panel goes at the top of `RightColumn`.**
  - Steam's own achievements keys for styling reference: `RightAchievementSection`, `AchievementProgress`, `AchievementProgressContainer`, `AchievementCarouselItem`, `AchievementHoverContainer`.
- Library "Add a Game" button: key `AddGameButton`, text `Add a Game`. Our button goes right after it.

## Q9 Steam styles
- Font: `"Motiva Sans", Arial, Helvetica, sans-serif`.
- Section header: 14px, `rgb(148, 161, 166)`, uppercase, letter-spacing 1px, padding-left 10px.
- Body text: `rgb(150, 150, 150)`. Section corner radius 2px. Backgrounds are transparent over the page's dark gradient.

## Q10 Images
- `https://media.retroachievements.org/Badge/250336.png` loads in the desktop document (`naturalWidth` 64). **Not blocked**, so the `image` bridge method isn't needed.

## Q11 Binding
- `node scripts/steam-eval.mjs --binding-test` → `ok`.

## Extra
- `SP_REACT` is **undefined** on this client. The panel uses plain DOM, not Steam's React.

## Q12 Big Picture (verified 2026-10-31)
- To enter: `SteamClient.UI.SetUIMode(4)`. To go back to desktop: `SetUIMode(7)`. Read the current mode with `await SteamClient.UI.GetUIMode()`.
- Window: `g_PopupManager.GetExistingPopup("SP BPM_uid0").m_popup.document`, titled `Steam Big Picture Mode`. While Big Picture is on, it's the only popup.
- Route: `SteamUIStore.GetFocusedWindowInstance().m_history.location.pathname` → `/library/app/<id>`. To navigate: `SteamUIStore.Navigate(path)`.
- Insertion point: class key `AppDetailsContent`, the tab content under ACTIVITY / YOUR STUFF / COMMUNITY / GAME INFO. The block goes at its top.
