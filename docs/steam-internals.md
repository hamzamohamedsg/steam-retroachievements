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

## Q13 Steam's achievements UI, reused (verified 2026-11-01)
The panel, its hover card and the View My Achievements page are built from Steam's own class names, so they look like a Steam game's. `steamUI.classes(...keys)` returns the class-map module that has all the given keys (module ids change per build; keys don't). Modules, by the keys that pick them:
- Section shell: `SectionHeader, PadLeft, LabelText` (heading) and `AppDetailsSectionContainer, AppDetailsSectionHasLabel, RightColumnSection` (`AppDetailsSection`, `Highlight`, `Body`).
- Right-column achievements: `RightAchievementSection, UnachievedSection`: `HighlightDiv, UnlockedLabel, UnlockedLabelPercent, AchievementProgressContainer, AchievementProgress, Achieved, Featured, AchievementHoverContainer, Icon, TextSection, Name, Desc, ShowDivider, Label, Additional, AdditionalItem, NotAchieved, RemainderContainer, Remainder, RemainderText`, plus the hover card's `Hover, TopSection, TopSectionAchievementIcon, Unlocked`. Icons: `AchievementIconWrapper, Icon`. Button: `AppDetailsButton, BottomRight` with the global `DialogButton _DialogLayout Secondary Focusable`.
- Hover card: `HoverPositionOuter, HoverPosition` (`Ready`; the outer node is a `popover="manual"` shown with `showPopover()`), `AppDetailsHover, BlurContainer` (`Background`).
- Achievements page (Steam's route `/library/app/<id>/achievements/my/individual`, mounted inside `AppDetailsMain`): `AchievementsOverlayContainer, AchievementsPageContainer, CloseButton`; `GamepadPage, Flexed, OverflowHidden`; `HeaderContainer, AchievementTabs, MyAchievementsHeader` (`Page, Background, Blur, HeaderImage, Container, List`); `StatsBlock, BigStat, AchievementSearchHeader` (`Title, GameIcon, Stat, StatLabelAndValue, ProgressLabel, Label, Progress, LeftContent, SearchField`); `GamepadTabbedPage, TabRow, TabTitle` (`Tab, Selected, RightAddon, TabContents, TabContentsScroll`); `AchievementListItemBase, AchievementTitle, UnlockDate` (rows); `GreyBackground, Visibility, Visible` (images).
- Progress bars: `ProgressBar, Percent, Indeterminate, TimeRemaining`. `ProgressBar, Percent` alone matches the achievement-list module first and draws nothing. Steam sets the fill colour inline: `background: var(--gpColor-Blue, #1a9fff)`.
- Unlisted helpers recreated in our CSS: the heading's reset (`margin: 0; font: unset` under `:where`) and the icon row's flex wrapper.
- A non-Steam game's left column holds a dashed notice: `AppDetailsSection` containing `Body` of the module with `OfflineButton, InnerContainer, Body`. The Details section replaces it (hidden, restored when the panel goes).

## Q14 Big Picture game page, native markup (verified 2026-11-01)
- Route: `SteamUIStore.WindowStore.GamepadUIMainWindowInstance.m_history` (`GetFocusedWindowInstance()` is null while another app has focus). Tabs show in the path: `/library/app/<id>/tab/WhatsNew` (ACTIVITY), `/tab/YourStuff`.
- Both tabs render into `AppDetailsContent > SeekTarget`. A shortcut's SeekTarget is empty on ACTIVITY and holds Media and Notes on YOUR STUFF; our sections go at its top.
- YOUR STUFF Achievements: section shell (Q13) + `Highlight HighlightDiv`, then `Body` + `BodyStopJiggle BasicAppDetailsAchievementsSectionBody` (module `RightAchievementSection, UnachievedSection`). Rows are `BoxCarousel, BoxCarouselContents, ListElement` carousels (inline: wrapper `margin: 0 -10px`, contents `padding/scroll-padding: 0 10px`, list and items `display: contents`), items `AchievementCarouselItem` > `Achieved|NotAchieved` > `AchievementHoverContainer` > `AchievementIconWrapper Icon CarouselIcon [Prioritized]`. The **focused** item gets `Detailed` plus `AchivementCarouselItemDetails` (`Name, Description, Achieved`). Labels: `h3.LockedAchievementsLabel`.
- ACTIVITY: `AppDetailsSection ActivityFeedContainer` > `Body InnerContainer` > `AppActivityDay` (`h4.AppActivityDate` + `Rule`) > `Event` > `EventHeadline` (`EventActorAvatar` with `avatarHolder/avatarStatus/avatar`, `SpanEvent > ActorName > playerName`) + `EventBody` > carousel `ActivityAchievementUnlocked` of `PrimaryAchievement Achieved Featured` (`TextSection Name Desc`). Modules: `AppActivityDay, EventHeadline`; `ActivityFeedContainer, Rollup, FetchMoreContainer`; `avatarHolder, avatarStatus, avatarFrame`; `playerName, statusAndName`.
- Own persona: `friendStore.m_FriendsUIFriendStore.self.persona` (`m_strPlayerName`, `avatar_url_full`).
- Controller: nav nodes take `actionDescriptionMap` (`{1: "View My Achievements"}` puts that on the footer's A). Buttons (`OK 1, CANCEL 2, BUMPER_LEFT 5, BUMPER_RIGHT 6, DIR_UP 9 … DIR_RIGHT 12`) reach the focused element as `vgp_onbuttondown` (`detail.button`), then `vgp_onok`/`vgp_oncancel`; `stopPropagation()+preventDefault()` claims one. Steam's focus ring comes from its React Focusable, not the nav tree, so our items style `:focus` themselves. Children are ordered by Steam (DOM/geometry), not registration order.
- Testing without a controller: `FocusNavController.DispatchVirtualGamepad("vgp_onbuttondown", {button, source: 1})` then `"vgp_onbuttonup"`; the focused node is `context.m_LastActiveNavTree.GetLastFocusedNode()`. Screenshots: CDP `Page.captureScreenshot` on the "Steam Big Picture Mode" target (only while the window is visible).
- Desktop game page: the same Activity section sits in `LeftColumn > SeekTarget`. No carousel: `ActivityAchievementUnlocked Panel` with inline `grid-template-columns: repeat(auto-fit, [col-start] minmax(49%, 260px) [col-end])`, items wrapped in `role=listitem` `display: contents`. The name is blue through the global `online` class on `ActorName`.
