// Steam-side script, injected into SharedJSContext by Steam RetroAchievements.
// It only draws what the app sends; every entry point is wrapped in safe() so nothing reaches Steam's code.
(() => {
  window.__sra?.dispose?.();

  // ---------------------------------------------------------------- bridge
  let nextId = 1;
  const pending = new Map();
  const call = (method, params = {}, timeoutMs = 20000) => new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    window.__sra_send(JSON.stringify({ id, method, params }));
  });
  // Something Steam changed breaks the 500 ms tick on every run: each distinct error goes to the log once a minute, not twice a second.
  const reported = new Map();  // error text → when it was last sent
  const log = (level, message) => {
    try {
      const text = String(message), now = Date.now();
      if (level === "error") {
        if (now - (reported.get(text) ?? -Infinity) < 60000) return;
        if (reported.size >= 100) reported.clear();
        reported.set(text, now);
      }
      window.__sra_send(JSON.stringify({ id: 0, method: "log", params: { level, message: text } }));
    } catch (_) {}
  };
  const safe = (fn) => (...args) => {
    try {
      const r = fn(...args);
      return r && typeof r.catch === "function" ? r.catch((e) => log("error", e?.stack ?? e)) : r;
    } catch (e) { log("error", e?.stack ?? e); }
  };

  // ---------------------------------------------------------------- Steam lookups (docs/steam-internals.md)
  const SHORTCUT = 1073741824;
  const steamUI = {
    // Big Picture has its own window and router (Q12); the desktop library otherwise (Q2, Q3).
    surface: () => {
      const bpm = g_PopupManager.GetExistingPopup("SP BPM_uid0")?.m_popup?.document;
      // The Big Picture window's own history; the focused one is null while another app has focus.
      const history = SteamUIStore.WindowStore?.GamepadUIMainWindowInstance?.m_history ?? SteamUIStore.GetFocusedWindowInstance?.()?.m_history;
      if (bpm) return { doc: bpm, bpm: true, route: history?.location?.pathname ?? "" };
      const doc = g_PopupManager.GetExistingPopup("SP Desktop_uid0")?.m_popup?.document;
      return doc ? { doc, bpm: false, route: window.MainWindowBrowserManager?.m_lastLocation?.pathname ?? "" } : null;
    },
    doc: () => steamUI.surface()?.doc ?? null,
    appid: (surface) => Number(/^\/library\/app\/(\d+)/.exec(surface?.route ?? "")?.[1]) || null,
    isShortcut: (appid) => appStore.GetAppOverviewByAppID(appid)?.app_type === SHORTCUT,
    details: (appid) => new Promise((resolve) => {
      let h;
      const done = (d) => { resolve(d); try { h?.unregister?.(); } catch (_) {} };
      h = SteamClient.Apps.RegisterForAppDetails(appid, done);
      setTimeout(() => done(null), 3000);
    }),
    shortcut: async (appid) => {
      const d = await steamUI.details(appid);
      return { appid, name: appStore.GetAppOverviewByAppID(appid)?.display_name ?? "", exe: d?.strShortcutExe ?? "", launchOptions: d?.strShortcutLaunchOptions ?? "" };
    },
    classMap: null,
    // Steam's class names are hashed per build; find them through its webpack class-map modules by readable key.
    findClass: (doc, key) => {
      if (!steamUI.classMap) {
        let req;
        webpackChunksteamui.push([[Math.random()], {}, (r) => { req = r; }]);
        const map = {};
        for (const id of Object.keys(req.m)) {
          let ex;
          try { ex = req(id); } catch (_) { continue; }
          if (!ex || typeof ex !== "object") continue;
          const entries = Object.entries(ex);
          if (entries.length > 2 && entries.every(([, v]) => typeof v === "string")) {
            for (const [k, v] of entries) (map[k] ??= new Set()).add(v.split(" ")[0]);
          }
        }
        steamUI.classMap = map;
      }
      const hashes = steamUI.classMap[key];
      return hashes ? doc.querySelector([...hashes].map((h) => "." + CSS.escape(h)).join(",")) : null;
    },
    // A whole class-map module, picked by keys only it has, so shared names like "Name" or "Container" resolve to the right component.
    modules: null,
    classes: (...keys) => {
      if (!steamUI.modules) {
        let req;
        webpackChunksteamui.push([[Math.random()], {}, (r) => { req = r; }]);
        steamUI.modules = [];
        for (const id of Object.keys(req.m)) {
          let ex;
          try { ex = req(id); } catch (_) { continue; }
          if (ex && typeof ex === "object" && Object.values(ex).filter((v) => typeof v === "string").length > 2) steamUI.modules.push(ex);
        }
      }
      return steamUI.modules.find((m) => keys.every((k) => typeof m[k] === "string")) ?? {};
    },
    // The store behind Steam's own achievements views (the overlay's Achievements window), found by the map only it has (Q16).
    achStore: undefined,
    achievementStore: () => {
      if (steamUI.achStore === undefined) steamUI.achStore = steamUI.findExport((v) => v && typeof v === "object" && "m_mapMyAchievements" in v);
      return steamUI.achStore;
    },
    // Steam's react-query client: every achievements view reads its cache (docs/steam-internals.md Q20).
    queries: undefined,
    queryClient: () => {
      if (steamUI.queries === undefined) steamUI.queries = steamUI.findExport((v) => v && typeof v === "object" && typeof v.getQueryCache === "function" && typeof v.defaultQueryOptions === "function");
      return steamUI.queries;
    },
    // Steam's MobX `observable` (export names change per build; its shape doesn't).
    mobxObservable: undefined,
    observable: () => {
      if (steamUI.mobxObservable === undefined) steamUI.mobxObservable = steamUI.findExport((v) => typeof v === "function" && v.box && v.map && v.array);
      return steamUI.mobxObservable;
    },
    findExport: (test) => {
      let req;
      webpackChunksteamui.push([[Math.random()], {}, (r) => { req = r; }]);
      for (const id of Object.keys(req.m)) {
        let ex;
        try { ex = req(id); } catch (_) { continue; }
        const hit = ex && typeof ex === "object" && Object.values(ex).find(test);
        if (hit) return hit;
      }
      return null;
    },
    panelHost: (doc, bpm) => steamUI.findClass(doc, bpm ? "AppDetailsContent" : "RightColumn"),
    addGameButton: (doc) => steamUI.findClass(doc, "AddGameButton"),
  };

  // ---------------------------------------------------------------- shortcuts (Task 9)
  const listShortcuts = safe(async () => {
    const apps = [...appStore.m_mapApps.values()].filter((a) => a.app_type === SHORTCUT);
    return Promise.all(apps.map((a) => steamUI.shortcut(a.appid)));
  });

  // AddShortcut ignores the name, so every field is set afterwards.
  const addShortcuts = safe(async (items) => {
    const out = [];
    for (const it of items) {
      try {
        // macOS Steam only accepts an existing .app bundle here; the real executable is set right after.
        const exe = it.bundle ?? it.exe.replace(/^"|"$/g, "");
        const appid = await SteamClient.Apps.AddShortcut(it.name, exe.includes(".app/") ? exe.slice(0, exe.indexOf(".app/") + 4) : exe, "", "");
        SteamClient.Apps.SetShortcutName(appid, it.name);
        SteamClient.Apps.SetShortcutExe(appid, it.exe);
        SteamClient.Apps.SetShortcutStartDir(appid, it.startDir);
        SteamClient.Apps.SetShortcutLaunchOptions(appid, it.launchOptions);
        out.push({ name: it.name, appid });
      } catch (e) {
        out.push({ name: it.name, error: e?.message || JSON.stringify(e) });
      }
    }
    return out;
  });

  // SteamGridDB art for new shortcuts. The app fetches it and only images come here. One game failing doesn't stop the others;
  // a rate limit, rejected key or no network (which every game would hit too) ends the run.
  const applyArt = async (appid, art) => {
    await Promise.all(art.images.map((i) => SteamClient.Apps.SetCustomArtworkForApp(appid, i.data, i.ext, i.assetType)));
    if (art.iconPath) SteamClient.Apps.SetShortcutIcon(appid, art.iconPath);
  };
  const addArtwork = safe(async (added) => {
    // 3 games at a time, each fetching its 5 kinds at once: fast without tripping SteamGridDB's rate limit.
    const queue = [...added];
    let stop = false;
    const worker = async () => {
      for (let g; !stop && (g = queue.shift());) {
        try {
          await applyArt(g.appid, await call("artwork", { title: g.name, appid: g.appid }, 120000));
        } catch (e) {
          log("error", `artwork for ${g.name}: ${e?.message ?? e}`);
          if (/network|http\((401|403|429|5\d\d)\)|timed out/.test(String(e?.message ?? e))) stop = true;
        }
      }
    };
    await Promise.all([worker(), worker(), worker()]);
  });

  // ---------------------------------------------------------------- drawing helpers
  const CSS_TEXT = `
  .sra-head { font-size: 14px; color: rgb(148, 161, 166); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 10px; }
  .sra-muted { color: #8b929b; font-size: 12px; }
  .sra-link { color: #67c1f5; cursor: pointer; background: none; border: 0; padding: 0; font: inherit; font-size: 12px; }
  .sra-link:hover { color: #fff; }
  .sra-notice { background: rgba(255, 196, 0, 0.12); border-left: 3px solid #e5b50d; color: #e8d9a8; padding: 6px 8px; margin: 0 0 10px; font-size: 12px; }
  .sra-actions { display: flex; gap: 14px; margin: 8px 0; align-items: center; }
  .sra-btn { background: rgba(255, 255, 255, 0.1); color: #fff; border: 0; border-radius: 2px; padding: 6px 12px; font: inherit; cursor: pointer; }
  .sra-btn:hover { background: #1a9fff; }
  .sra-subset { cursor: pointer; }
  .sra-details { display: grid; grid-template-columns: auto 1fr; gap: 2px 12px; margin-top: 8px; font-size: 12px; }
  .sra-details dt { color: #8b929b; } .sra-details dd { margin: 0; color: #c6d4df; }
  .sra-overlay { position: fixed; inset: 0; z-index: 9999; background: rgba(0, 0, 0, 0.6); display: flex; align-items: center; justify-content: center; }
  .sra-dialog { width: min(680px, 90vw); max-height: 80vh; display: flex; flex-direction: column; background: #1b2838; border-radius: 3px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5); font-family: "Motiva Sans", Arial, sans-serif; color: #c6d4df; font-size: 13px; }
  .sra-dialog-head { display: flex; justify-content: space-between; align-items: center; padding: 14px 16px; border-bottom: 1px solid rgba(255, 255, 255, 0.08); color: #fff; font-size: 16px; }
  .sra-dialog-body { overflow: auto; padding: 8px 16px 16px; }
  .sra-row { display: flex; gap: 12px; align-items: center; padding: 8px; border-radius: 2px; background: rgba(255, 255, 255, 0.04); margin-top: 6px; }
  .sra-row img { width: 48px; height: 48px; border-radius: 2px; flex: none; }
  .sra-row.sra-hc img { box-shadow: 0 0 0 2px #e5b50d; }
  .sra-row.sra-locked { opacity: 0.6; }
  .sra-row-main { flex: 1; min-width: 0; } .sra-row-title { color: #fff; } .sra-row-side { text-align: right; flex: none; font-size: 12px; color: #8b929b; }
  .sra-pick { cursor: pointer; } .sra-pick:hover { background: rgba(26, 159, 255, 0.25); }
  .sra-search { display: flex; gap: 8px; padding: 12px 16px 0; }
  .sra-search select, .sra-search input { background: #0e141b; color: #fff; border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 2px; padding: 6px 8px; font: inherit; }
  .sra-search input { flex: 1; }
  .sra-folders { padding: 0 16px; }
  .sra-btn:disabled, .sra-btn:disabled:hover { opacity: 0.5; cursor: default; background: rgba(255, 255, 255, 0.1); }
  .sra-btn.sra-danger:hover { background: #c4302b; }
  .sra-input { background: #0e141b; color: #fff; border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 2px; padding: 6px 8px; font: inherit; }
  .sra-form label { display: flex; flex-direction: column; gap: 4px; margin: 8px 0; }
  .sra-form .sra-head { margin: 18px 0 8px; }
  .sra-diagnostics { width: 100%; box-sizing: border-box; font: 11px monospace; }
  .sra-form label.sra-check { flex-direction: row; align-items: center; gap: 8px; }
  .sra-error { color: #ff7b7b; font-size: 12px; }
  .sra-footer { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 16px; border-top: 1px solid rgba(255, 255, 255, 0.08); }
  .sra-footer .sra-muted { white-space: pre-line; }
  .sra-row select { max-width: 170px; }
  /* Steam-classed panel: only what Steam's classes leave to unlisted helpers (docs/steam-internals.md Q13). */
  :where(.sra-h2) { margin: 0; font: unset; }
  .sra-hc img { outline: 2px solid #e5b143; outline-offset: -2px; }  /* RetroAchievements' gold frame for hardcore unlocks (the img is positioned, so it'd cover its wrapper's outline) */
  .sra-info { display: flex; flex-direction: column; gap: 12px; padding: 16px; font-size: 13px; color: #c6d4df; }
  .sra-info dl { display: grid; grid-template-columns: max-content 1fr; gap: 6px 24px; margin: 0; }
  .sra-info dt { color: #8b929b; } .sra-info dd { margin: 0; color: #fff; }
  .sra-info .sra-notice { margin: 0; }
  .sra-info .sra-actions { margin: 0; }
  .sra-message { padding: 16px; display: flex; flex-direction: column; gap: 12px; align-items: flex-start; }
  .sra-stat { cursor: pointer; }
  .sra-btn.sra-addgames { margin-left: 8px; background: none; color: #8b929b; font-size: 12px; padding: 4px 6px; }
  .sra-btn.sra-addgames:hover { background: none; color: #fff; }
  /* Steam's focus ring comes from its React Focusable, which our items don't have; this stands in for it. */
  .sra-carousel .sra-item { cursor: pointer; } .sra-item:focus { outline: 2px solid rgba(255, 255, 255, 0.6); outline-offset: -2px; }
  /* Steam's own achievements views: hardcore unlocks (marked by feedSteam). */
  img[src$="#hardcore"] { outline: 2px solid #e5b143; outline-offset: -2px; }
  /* Steam's own menu classes draw the rest; it sits inside the tab, so it has to cover the window itself. */
  .sra-menu[data-sra] { position: fixed; inset: 0; z-index: 1000; background: rgba(0, 0, 0, 0.7); }
  .sra-missable { display: inline-block; margin-right: 6px; padding: 0 5px; border-radius: 2px; background: rgba(229, 181, 13, 0.18); color: #e5b50d; font-size: 11px; line-height: 16px; }
  :has(> .sra-missable-mark) { position: relative; }
  .sra-dialog.sra-art-dialog { width: min(960px, 94vw); height: 80vh; }
  .sra-art-dialog .sra-dialog-body { flex: 1; min-height: 0; }
  .sra-art-tag { margin-left: 8px; padding: 0 5px; border-radius: 2px; background: rgba(26, 159, 255, 0.2); color: #67c1f5; font-size: 11px; line-height: 16px; }
  .sra-art-tabs { display: flex; gap: 6px; align-items: center; margin: 8px 0 12px; }
  .sra-art-tabs .sra-link { margin-left: auto; }
  .sra-art-tab { background: rgba(255, 255, 255, 0.08); color: #c6d4df; border: 0; border-radius: 2px; padding: 5px 12px; font: inherit; cursor: pointer; }
  .sra-art-tab:hover { background: rgba(255, 255, 255, 0.16); } .sra-art-tab.sra-art-on { background: #1a9fff; color: #fff; }
  .sra-art-grid { display: grid; gap: 10px; grid-template-columns: repeat(auto-fill, minmax(var(--w, 150px), 1fr)); align-items: start; }
  .sra-art-grid > .sra-muted { grid-column: 1 / -1; }
  .sra-art-k-grid { --w: 140px; } .sra-art-k-wide { --w: 300px; } .sra-art-k-hero { --w: 300px; } .sra-art-k-logo { --w: 200px; } .sra-art-k-icon { --w: 96px; }
  .sra-art-thumb { position: relative; cursor: pointer; border-radius: 2px; background: #0e141b; outline: 2px solid transparent; outline-offset: -2px; overflow: hidden; }
  .sra-art-thumb img { display: block; width: 100%; height: 100%; object-fit: cover; }
  .sra-art-k-grid .sra-art-thumb { aspect-ratio: 2 / 3; } .sra-art-k-wide .sra-art-thumb { aspect-ratio: 460 / 215; } .sra-art-k-hero .sra-art-thumb { aspect-ratio: 96 / 31; }
  .sra-art-k-logo .sra-art-thumb { aspect-ratio: 2 / 1; } .sra-art-k-icon .sra-art-thumb { aspect-ratio: 1; }
  .sra-art-k-logo .sra-art-thumb, .sra-art-k-icon .sra-art-thumb { background: conic-gradient(#1c1c1c 25%, #2a2a2a 0 50%, #1c1c1c 0 75%, #2a2a2a 0) 0 0 / 16px 16px; }
  .sra-art-k-logo .sra-art-thumb img, .sra-art-k-icon .sra-art-thumb img { object-fit: contain; }
  .sra-art-thumb:hover { outline-color: rgba(26, 159, 255, 0.6); } .sra-art-thumb.sra-art-on { outline-color: #1a9fff; }
  .sra-art-check { display: none; position: absolute; top: 4px; right: 4px; width: 18px; height: 18px; border-radius: 50%; background: #1a9fff; color: #fff; font-size: 12px; line-height: 18px; text-align: center; }
  .sra-art-thumb.sra-art-on .sra-art-check { display: block; }
  .sra-missable-mark { position: absolute; top: 0; right: 0; width: 14px; height: 14px; border-radius: 0 0 0 3px; background: #e5b50d; color: #000; font-size: 11px; font-weight: 700; line-height: 14px; text-align: center; }
  /* Leaderboards: Steam's dark panels, its blue for you, RetroAchievements' gold, silver and bronze for the top three. */
  .sra-lb-kind { display: inline-flex; flex: none; width: 32px; height: 32px; border-radius: 3px; align-items: center; justify-content: center; background: rgba(103, 193, 245, 0.12); color: #67c1f5; }
  .sra-lb-kind svg { width: 18px; height: 18px; }
  .sra-lb-kind.sra-lb-score { background: rgba(229, 177, 67, 0.12); color: #e5b143; }
  .sra-lb-kind.sra-lb-kind-big { width: 48px; height: 48px; } .sra-lb-kind-big svg { width: 26px; height: 26px; }
  .sra-lb-body { display: flex; flex-direction: column; gap: 10px; }
  .sra-lb-summary { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; font-size: 13px; color: #8b929b; }
  .sra-lb-summary strong, .sra-lb-summary-main { color: #c6d4df; font-weight: 500; } .sra-lb-summary strong { color: #fff; }
  .sra-lb-accent { color: #67c1f5; }
  .sra-lb-rows { display: flex; flex-direction: column; gap: 2px; }
  .sra-lb-row { display: flex; align-items: center; gap: 12px; padding: 8px 10px; border-radius: 3px; background: rgba(255, 255, 255, 0.03); cursor: pointer; transition: background 120ms ease, transform 120ms ease; }
  .sra-lb-row:hover, .sra-lb-row:focus-visible { background: rgba(255, 255, 255, 0.09); outline: none; }
  .sra-lb-row:active { transform: scale(0.995); }
  .sra-lb-row-main { flex: 1; min-width: 0; }
  .sra-lb-row-title { color: #fff; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sra-lb-row-sub { color: #8b929b; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sra-lb-row-side { flex: none; text-align: right; max-width: 45%; }
  .sra-lb-rank { color: #67c1f5; font-weight: 700; font-size: 15px; font-variant-numeric: tabular-nums; }
  .sra-lb-rank.sra-lb-big { font-size: 28px; line-height: 1.1; }
  .sra-lb-record { color: #c6d4df; font-size: 14px; font-variant-numeric: tabular-nums; }
  .sra-lb-card { display: flex; flex-direction: column; gap: 6px; width: 220px; flex: none; padding: 12px; margin: 4px; border-radius: 4px; background: rgba(255, 255, 255, 0.05); box-sizing: border-box; }
  .sra-lb-card.sra-lb-ranked { background: linear-gradient(135deg, rgba(26, 159, 255, 0.18), rgba(255, 255, 255, 0.04)); }
  .sra-lb-card-head { display: flex; justify-content: space-between; align-items: center; }
  .sra-lb-card:focus { outline: 2px solid rgba(255, 255, 255, 0.8); outline-offset: 0; }
  .sra-dialog.sra-lb-dialog { width: min(1120px, 95vw); height: min(820px, 88vh); max-height: none; }
  .sra-lb-dialog-title { display: flex; align-items: center; gap: 12px; } .sra-lb-dialog-title img { width: 36px; height: 36px; border-radius: 3px; }
  .sra-lb-dialog-title .sra-muted { font-size: 12px; }
  .sra-lb-layout { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(240px, 320px) 1fr; }
  .sra-lb-side { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid rgba(255, 255, 255, 0.08); background: rgba(0, 0, 0, 0.15); }
  .sra-lb-side-top { display: flex; flex-direction: column; gap: 8px; padding: 12px; }
  .sra-lb-tabs { display: flex; gap: 4px; }
  .sra-lb-tab { flex: 1; display: flex; justify-content: center; gap: 6px; padding: 6px 8px; border: 0; border-radius: 2px; background: rgba(255, 255, 255, 0.05); color: #8b929b; font: inherit; font-size: 12px; cursor: pointer; }
  .sra-lb-tab:hover { color: #fff; } .sra-lb-tab.sra-lb-on { background: rgba(26, 159, 255, 0.25); color: #fff; }
  .sra-lb-count { opacity: 0.7; font-variant-numeric: tabular-nums; }
  .sra-lb-list { flex: 1; overflow: auto; padding: 0 8px 12px; outline: none; }
  .sra-lb-group { padding: 12px 6px 6px; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; color: #8b929b; }
  .sra-lb-item { display: flex; align-items: center; gap: 10px; padding: 8px; border-radius: 3px; cursor: pointer; border-left: 2px solid transparent; }
  .sra-lb-item:hover { background: rgba(255, 255, 255, 0.06); }
  .sra-lb-item.sra-lb-on { background: rgba(26, 159, 255, 0.16); border-left-color: #1a9fff; }
  .sra-lb-list:focus-visible .sra-lb-on { outline: 1px solid rgba(255, 255, 255, 0.5); }
  .sra-lb-empty { padding: 24px 12px; text-align: center; }
  .sra-lb-main { overflow: auto; padding: 20px 24px 24px; display: flex; flex-direction: column; gap: 16px; min-width: 0; }
  .sra-lb-head { display: flex; gap: 16px; align-items: flex-start; }
  .sra-lb-head-main { flex: 1; min-width: 0; }
  .sra-lb-title { color: #fff; font-size: 20px; font-weight: 500; }
  .sra-lb-desc { color: #c6d4df; margin-top: 2px; }
  .sra-lb-meta { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 8px; }
  .sra-lb-meta span { padding: 2px 8px; border-radius: 10px; background: rgba(255, 255, 255, 0.07); color: #8b929b; font-size: 11px; }
  .sra-lb-you-card { display: flex; align-items: center; gap: 16px; padding: 14px 16px; border-radius: 4px; background: linear-gradient(120deg, rgba(26, 159, 255, 0.22), rgba(26, 159, 255, 0.04) 70%); border: 1px solid rgba(26, 159, 255, 0.3); }
  .sra-lb-you-card.sra-lb-none { background: rgba(255, 255, 255, 0.04); border-color: rgba(255, 255, 255, 0.08); }
  .sra-lb-you-card .sra-lb-avatar { border-radius: 50%; box-shadow: 0 0 0 2px #1a9fff; }
  .sra-lb-you-main { flex: 1; min-width: 0; }
  .sra-lb-you-label { color: #8b929b; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; }
  .sra-lb-you-score { color: #fff; font-size: 24px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .sra-lb-you-rank { text-align: right; min-width: 140px; }
  .sra-lb-meter { height: 4px; margin-top: 6px; border-radius: 2px; background: rgba(255, 255, 255, 0.1); overflow: hidden; }
  .sra-lb-meter div { height: 100%; background: linear-gradient(90deg, #1465cf, #1a9fff); border-radius: 2px; animation: sra-lb-grow 600ms cubic-bezier(0.2, 0.8, 0.2, 1); transform-origin: left; }
  @keyframes sra-lb-grow { from { transform: scaleX(0); } }
  .sra-lb-podium { display: grid; grid-template-columns: 1fr 1.15fr 1fr; gap: 12px; align-items: end; }
  .sra-lb-step { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 14px 8px 12px; border-radius: 4px 4px 2px 2px; background: rgba(255, 255, 255, 0.04); position: relative; min-width: 0;
    --medal: #c0c8d0; border-top: 3px solid var(--medal); animation: sra-lb-rise 420ms cubic-bezier(0.2, 0.8, 0.2, 1) both; }
  .sra-lb-step.sra-lb-top1 { --medal: #e5b143; padding-top: 22px; background: linear-gradient(180deg, rgba(229, 177, 67, 0.14), rgba(255, 255, 255, 0.03)); animation-delay: 60ms; }
  .sra-lb-step.sra-lb-top3 { --medal: #cd8a4f; animation-delay: 120ms; }
  @keyframes sra-lb-rise { from { opacity: 0; transform: translateY(8px); } }
  .sra-lb-step .sra-lb-avatar { border-radius: 50%; box-shadow: 0 0 0 2px var(--medal); }
  .sra-lb-step.sra-lb-me .sra-lb-avatar { box-shadow: 0 0 0 2px var(--medal), 0 0 0 4px #1a9fff; }
  .sra-lb-medal { position: absolute; top: 6px; left: 8px; width: 20px; height: 20px; border-radius: 50%; background: var(--medal); color: #1b2838; font-weight: 700; font-size: 12px; line-height: 20px; text-align: center; }
  .sra-lb-step-user { color: #fff; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sra-lb-step-score { color: var(--medal); font-weight: 600; font-variant-numeric: tabular-nums; }
  .sra-lb-thead, .sra-lb-tr { display: grid; grid-template-columns: 84px 1fr minmax(90px, auto) 120px; gap: 12px; align-items: center; padding: 0 12px; }
  .sra-lb-thead { color: #8b929b; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; padding-bottom: 6px; border-bottom: 1px solid rgba(255, 255, 255, 0.08); margin-bottom: -12px; position: sticky; top: -20px; background: #1b2838; z-index: 1; padding-top: 8px; }
  .sra-lb-table { display: flex; flex-direction: column; }
  .sra-lb-tr { min-height: 40px; border-radius: 2px; font-variant-numeric: tabular-nums; }
  .sra-lb-tr:nth-child(odd) { background: rgba(255, 255, 255, 0.025); }
  .sra-lb-tr:hover { background: rgba(255, 255, 255, 0.07); }
  .sra-lb-td-rank { color: #8b929b; font-weight: 600; }
  .sra-lb-top1 .sra-lb-td-rank { color: #e5b143; } .sra-lb-top2 .sra-lb-td-rank { color: #c0c8d0; } .sra-lb-top3 .sra-lb-td-rank { color: #cd8a4f; }
  .sra-lb-td-user { display: flex; align-items: center; gap: 10px; min-width: 0; color: #fff; }
  .sra-lb-td-user span:first-of-type { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sra-lb-td-user .sra-lb-avatar { border-radius: 50%; flex: none; }
  .sra-lb-td-score { color: #fff; text-align: right; }
  .sra-lb-td-date { color: #8b929b; font-size: 12px; text-align: right; }
  .sra-lb-tr.sra-lb-me { background: rgba(26, 159, 255, 0.2); box-shadow: inset 3px 0 0 #1a9fff; }
  .sra-lb-tr.sra-lb-me .sra-lb-td-rank { color: #67c1f5; }
  .sra-lb-you { padding: 0 6px; border-radius: 2px; background: #1a9fff; color: #fff; font-size: 10px; font-weight: 700; letter-spacing: 0.5px; text-transform: uppercase; line-height: 16px; }
  .sra-lb-flash { animation: sra-lb-flash 1.2s ease-out; }
  @keyframes sra-lb-flash { 0%, 30% { background: rgba(26, 159, 255, 0.55); } }
  .sra-lb-gap { padding: 10px; text-align: center; color: #8b929b; font-size: 12px; letter-spacing: 2px; }
  .sra-lb-gap::before, .sra-lb-gap::after { content: " ⋯ "; }
  .sra-lb-loading { padding: 24px; text-align: center; }
  .sra-lb-strip { display: flex; flex-direction: column; gap: 12px; margin: 8px 0 24px; padding: 16px; border-radius: 4px; background: rgba(14, 20, 27, 0.72); backdrop-filter: blur(8px); font-family: "Motiva Sans", Arial, sans-serif; }
  .sra-lb-strip-head { display: flex; align-items: baseline; gap: 16px; flex-wrap: wrap; }
  .sra-lb-strip-title { color: #fff; font-size: 16px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase; }
  .sra-lb-strip-head .sra-lb-summary { flex: 1; }
  .sra-lb-strip .sra-lb-card { transition: transform 120ms ease, background 120ms ease; }
  .sra-lb-strip .sra-lb-card:focus { transform: scale(1.04); background: rgba(26, 159, 255, 0.28); outline: 2px solid #fff; }
  .sra-lb-detail { display: flex; flex-direction: column; gap: 10px; padding: 14px 16px; border-radius: 4px; background: rgba(255, 255, 255, 0.04); min-height: 96px; }
  .sra-lb-detail-head { display: flex; gap: 16px; align-items: flex-start; }
  .sra-lb-detail-title { font-size: 18px; white-space: normal; }
  .sra-lb-detail .sra-lb-row-sub { white-space: normal; }
  .sra-lb-next { color: #c6d4df; font-size: 14px; font-variant-numeric: tabular-nums; }
  .sra-lb-next .sra-lb-you-label { margin-right: 6px; color: #67c1f5; }
  .sra-lb-standing { display: flex; flex-direction: column; gap: 8px; animation: sra-lb-rise 240ms ease both; }
  @media (max-width: 760px) { .sra-lb-layout { grid-template-columns: 1fr; } .sra-lb-side { max-height: 34%; border-right: 0; border-bottom: 1px solid rgba(255, 255, 255, 0.08); }
    .sra-lb-thead, .sra-lb-tr { grid-template-columns: 64px 1fr auto; } .sra-lb-td-date, .sra-lb-thead > :last-child { display: none; } }
  @media (prefers-reduced-motion: reduce) { .sra-lb-step, .sra-lb-meter div, .sra-lb-flash { animation: none; } .sra-lb-row { transition: none; } }
  `;

  const el = (doc, tag, props = {}, ...children) => {
    const n = doc.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") n.className = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), safe(v));
      else if (v !== undefined && v !== null) n.setAttribute(k, v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) n.append(typeof c === "string" ? doc.createTextNode(c) : c);
    n.setAttribute("data-sra", "");
    return n;
  };

  const ensureStyle = (doc) => {
    if (doc.querySelector("style[data-sra]")) return;
    const s = doc.createElement("style");
    s.setAttribute("data-sra", "");
    s.textContent = CSS_TEXT;
    doc.head.append(s);
  };

  // ---------------------------------------------------------------- panel (built from Steam's own classes: docs/steam-internals.md Q13)
  let current = null;        // { appid, shortcut, payload, nodes }
  let hoverCard = null;
  const c = (mod, ...keys) => keys.map((k) => mod[k] ?? "").join(" ");
  const K = {
    section: () => steamUI.classes("SectionHeader", "PadLeft", "LabelText"),
    details: () => steamUI.classes("AppDetailsSectionContainer", "AppDetailsSectionHasLabel", "RightColumnSection"),
    ach: () => steamUI.classes("RightAchievementSection", "UnachievedSection"),
    icon: () => steamUI.classes("AchievementIconWrapper", "Icon"),
    button: () => steamUI.classes("AppDetailsButton", "BottomRight"),
    hover: () => steamUI.classes("HoverPositionOuter", "HoverPosition"),
    hoverBg: () => steamUI.classes("AppDetailsHover", "BlurContainer"),
    notice: () => steamUI.classes("OfflineButton", "InnerContainer", "Body"),
    bar: () => steamUI.classes("CompletedCallout", "Unlocked", "Dimmed"),
    award: () => steamUI.classes("GroupAchievementRibbon", "CompletionAward"),
    // Steam's design-system atoms, which take their values from inline CSS variables.
    flex: () => steamUI.classes("Flex", "Direction", "Gap"),
    grid: () => steamUI.classes("Grid", "Columns", "Areas"),
    box: () => steamUI.classes("Width", "MinHeight", "ZIndex"),
    text: () => steamUI.classes("Text", "TextSize-2", "Truncate"),
  };
  const steamButton = "DialogButton _DialogLayout Secondary Focusable";
  // RetroAchievements counts hardcore and softcore unlocks apart: each unlock says which, and hardcore icons get RA's gold frame.
  const mode = (r) => r?.unlocked && r.hardcore !== undefined ? (r.hardcore ? "Hardcore" : "Softcore") : null;
  const hc = (r) => r?.unlocked && r.hardcore ? " sra-hc" : "";
  const missableTag = (doc, r) => r?.missable && el(doc, "span", { class: "sra-missable" }, "Missable");
  // Icon rows have no room for the word: a mark on the icon, and the hover card or focused card says it.
  const missableMark = (doc, r) => r?.missable && el(doc, "span", { class: "sra-missable-mark", role: "img", "aria-label": "Missable" }, "!");
  const achievementURL = (r) => `https://retroachievements.org/achievement/${r.id}`;
  // Big Picture (and the Deck's Game Mode) gets Steam's own browser: a desktop browser opened by the app wouldn't show there.
  const openRA = safe((url) => current?.bpm ? SteamClient.URL.ExecuteSteamURL(`steam://openurl/${url}`) : call("openURL", { url }));

  // The game's own set, then its subsets: Steam's achievement sets (Q20). A subset counts toward the totals once something in it
  // is unlocked, the way a Steam DLC set only counts for players who have the DLC: mastering the game alone still reads 100%.
  const setsOf = (p) => [p, ...(p.subsets ?? []).filter((sp) => sp.state === "matched")];
  const earnedIn = (sp) => sp.achievements.filter((r) => r.unlocked).length;
  const counted = (p) => setsOf(p).filter((sp, i) => i === 0 || earnedIn(sp) > 0);
  const percent = (n, of) => !of ? 0 : n === of ? 100 : Math.min(99, Math.round(n * 100 / of));
  // Steam's own achievements page (View My Achievements), which draws what feedSteam gave it.
  const openPage = safe(() => {
    if (!current) return;
    hideCard();
    const path = `/library/app/${current.appid}/achievements/my/individual`;
    current.bpm ? SteamUIStore.Navigate(path) : MainWindowBrowserManager.m_history.push(path);
  });

  const showCard = (doc, target, row) => {
    hideCard();
    const A = K.ach(), I = K.icon(), H = K.hover(), B = K.hoverBg();
    const points = [`${row.points} points`, mode(row)].filter(Boolean).join(" · ");
    const pos = el(doc, "div", { class: c(H, "HoverPosition", "Ready") },
      el(doc, "div", {}, el(doc, "div", { class: c(B, "AppDetailsHover") + " " + c(A, "Hover") + (row.unlocked ? " " + c(A, "Achieved") : "") },
        el(doc, "div", { class: c(B, "Background") }, el(doc, "div", { class: c(B, "BlurContainer") }, el(doc, "img", { src: row.badgeURL, alt: "" }))),
        el(doc, "div", { class: c(A, "TopSection") },
          el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "TopSectionAchievementIcon", "Icon") + hc(row) }, el(doc, "img", { class: c(I, "Icon"), src: row.badgeURL, alt: "" })),
          el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, row.title), el(doc, "div", { class: c(A, "Desc") }, missableTag(doc, row), row.description))),
        el(doc, "div", { class: c(A, "Unlocked") }, row.unlockedText && el(doc, "div", {}, row.unlockedText), el(doc, "div", {}, points),
          row.rarityText && el(doc, "div", {}, row.rarityText)))));
    hoverCard = el(doc, "div", { class: c(H, "HoverPositionOuter"), popover: "manual" }, pos);
    doc.body.append(hoverCard);
    try { hoverCard.showPopover(); } catch (_) {}   // top layer, above Steam's own stacking contexts
    hoverCard.style.display = "block";
    const r = target.getBoundingClientRect(), w = pos.getBoundingClientRect().width || 320;
    pos.style.left = `${Math.max(8, Math.min(r.left, doc.defaultView.innerWidth - w - 8))}px`;
    pos.style.top = `${r.bottom + 8}px`;
  };
  const hideCard = () => { hoverCard?.remove(); hoverCard = null; };

  // Big Picture's controller navigation only reaches elements registered in Steam's focus tree (what its own Focusable component does):
  // a node under the nearest registered ancestor, then the element. A failure just leaves the items mouse/touch-only.
  let navCleanups = [];
  const FLOW_COLUMN = 1, FLOW_ROW = 2;  // Steam's layout enum: NONE, COLUMN, ROW, ...
  const BTN = { OK: 1, CANCEL: 2, SECONDARY: 3, BUMPER_LEFT: 5, BUMPER_RIGHT: 6, DIR_UP: 9, DIR_DOWN: 10, DIR_LEFT: 11, DIR_RIGHT: 12 };  // Steam's gamepad buttons
  const handled = (e) => { e.stopPropagation(); e.preventDefault(); };  // how Steam's own handlers claim a button
  // Each .sra-carousel is a row (left/right) and each .sra-column a column (up/down) of .sra-item; returns the items' nodes in order.
  const navNodeFor = (doc, root) => {
    const context = FocusNavController.m_rgAllContexts.find((x) => x.m_rootWindow === doc.defaultView);
    const deepest = (node) => node.m_rgChildren.reduce((best, ch) => deepest(ch) ?? best, node.m_element?.contains(root) ? node : null);
    let parent = null;
    for (const tree of context?.m_rgGamepadNavigationTrees ?? []) parent = deepest(tree.m_Root) ?? parent;
    return parent;
  };
  const registerNav = (doc, root, cleanups = navCleanups, actions = { [BTN.OK]: "View My Achievements" }) => {
    try {
      const parent = navNodeFor(doc, root);
      if (!parent) return [];
      const add = (under, element, props) => {
        const node = under.Tree.CreateNode(under, undefined);
        node.SetProperties(props);
        cleanups.push(under.Tree.RegisterNavigationItem(node, element));
        return node;
      };
      return [...root.querySelectorAll(".sra-carousel, .sra-column")].flatMap((group) => {
        // A group: focus goes to its items, not to it.
        const groupNode = add(parent, group, { focusable: false, layout: group.classList.contains("sra-carousel") ? FLOW_ROW : FLOW_COLUMN });
        return [...group.querySelectorAll(".sra-item")].map((item) => {
          // Steam delivers its gamepad buttons to the element as DOM events (what Focusable's onOKButton listens for).
          item.addEventListener("vgp_onok", (e) => { handled(e); item.click(); });
          // X (□ on PlayStation) opens the item's RetroAchievements page, when it has one.
          if (item.sraURL) item.addEventListener("vgp_onbuttondown", (e) => { if (e.detail?.button === BTN.SECONDARY) { handled(e); openRA(item.sraURL); } });
          return (item.sraNode = add(groupNode, item, { focusable: true,
            actionDescriptionMap: item.sraURL ? { ...actions, [BTN.SECONDARY]: "View on RetroAchievements" } : actions }));
        });
      });
    } catch (e) { log("error", `controller focus unavailable: ${e?.message ?? e}`); return []; }
  };
  const takeFocus = (node) => { try { node?.BTakeFocus(); } catch (_) {} };

  const removePanel = () => {
    navCleanups.reverse().forEach((fn) => { try { fn(); } catch (_) {} });  // children before their group
    navCleanups = [];
    hideCard();
    const doc = steamUI.doc();
    doc?.querySelectorAll("[data-sra-panel]").forEach((n) => n.remove());
    doc?.querySelectorAll("[data-sra-hid]").forEach((n) => { n.style.display = ""; n.removeAttribute("data-sra-hid"); });
  };

  // A Steam library section: uppercase heading over a panel.
  const section = (doc, title, containerKeys, ...content) => {
    const S = K.section(), D = K.details();
    return el(doc, "div", { class: c(D, "AppDetailsSection") + " Panel", "data-sra-panel": "" },
      el(doc, "h2", { class: c(S, "SectionHeader", "PadLeft") + " sra-h2" }, el(doc, "div", { class: c(S, "Label") }, el(doc, "div", { class: c(S, "LabelText") }, title))),
      el(doc, "div", { class: c(D, "AppDetailsSectionContainer", ...containerKeys) + " Panel" }, ...content));
  };

  const iconOf = (doc, row, extra = "") => el(doc, "div", { class: c(K.icon(), "AchievementIconWrapper") + " " + extra + " sra-stat" + hc(row),
      onmouseenter: (e) => showCard(doc, e.currentTarget, row), onmouseleave: hideCard, onclick: () => openRA(achievementURL(row)) },
    el(doc, "img", { class: c(K.icon(), "Icon"), src: row.badgeURL, alt: "" }), missableMark(doc, row));

  // Steam's icon row: as many icons as fit on one line, the rest as a "+ N" tile (filled in once it's on screen and has a width).
  const ICON = 48, ICON_GAP = 4;  // Steam's --icon-size here, and --spacing-1
  const iconGrid = (doc) => el(doc, "div", { class: c(K.grid(), "Columns", "Rows", "Gap", "Grid") + " " + c(K.ach(), "IconRow") + " sra-iconrow",
    style: `--grid-columns: repeat(auto-fill, var(--icon-size)); --grid-rows: repeat(1, var(--icon-size)); --grid-gap: var(--spacing-1); --icon-size: ${ICON}px;` });
  const iconRow = (doc, rows) => {
    const X = K.box(), F = K.flex(), T = K.text(), row = iconGrid(doc);
    const more = (n) => el(doc, "div", { class: c(X, "Width", "Height", "FlexShrink", "Border", "BorderColor", "TextAlign") + " " + c(F, "Direction", "Justify", "Flex") + " sra-stat", onclick: openPage,
        style: "--width: var(--icon-size); --height: var(--icon-size); --flex-shrink: 0; --border-color: var(--color-dull-9); --text-align: center; --direction: column; --justify: space-around;" },
      el(doc, "span", { class: c(T, "TextWeight", "TextSize-4", "Text"), style: "--text-weight: var(--font-weight-heavy); --text-color: var(--color-text-body-title);" }, `+ ${n}`));
    row.sraFit = () => {
      const fit = Math.max(1, Math.floor((row.clientWidth + ICON_GAP) / (ICON + ICON_GAP)));
      row.replaceChildren(...(rows.length > fit ? [...rows.slice(0, fit - 1).map((r) => iconOf(doc, r)), more(rows.length - fit + 1)] : rows.map((r) => iconOf(doc, r))));
    };
    return row;
  };

  // One icon per subset (RetroAchievements lists each as its own game). A started one is an achievement set on Steam's page;
  // Steam lists nothing for one that isn't, so that icon opens the subset on RetroAchievements.
  const subsetName = (sp) => /\[Subset - ([^\]]+)\]/.exec(sp.game?.title ?? "")?.[1] ?? sp.game?.title ?? "Subset";
  const subsetRow = (doc, p) => {
    const I = K.icon(), row = iconGrid(doc);
    row.append(...p.subsets.map((sp) => el(doc, "div", { class: c(I, "AchievementIconWrapper") + " sra-stat", title: `${subsetName(sp)}: ${earnedIn(sp)} of ${sp.achievements.length}`, onclick: () => earnedIn(sp) ? openPage() : openRA(sp.game.raURL) },
      el(doc, "img", { class: c(I, "Icon"), src: sp.game.iconURL, alt: "" }))));
    return row;
  };

  // Steam's "set complete" trophy.
  const AWARD_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 24" fill="none"><defs><linearGradient id="sra-award" x1="7.8579" y1="14.3641" x2="7.8579" y2="25.1901" gradientUnits="userSpaceOnUse"><stop offset="0.168269" stop-color="#1A9FFF"></stop><stop offset="1" stop-color="#1465CF"></stop></linearGradient></defs><g><path fill-rule="evenodd" clip-rule="evenodd" fill="url(#sra-award)" d="M13.48 23.2439V23.8926H2.23582V23.2439H13.48ZM12.637 22.3516H3.07869V23.2439H12.637V22.3516ZM9.24241 21.1553H11.0107L13.0475 16.1082H11.3176L9.24241 17.4056L9.24348 21.1553L9.24241 21.1553Z"></path><path fill="url(#sra-award)" d="M6.47385 21.1553H4.70556L2.66825 16.1082H4.80856L6.47385 17.4056V21.1553Z"></path><path fill-rule="evenodd" clip-rule="evenodd" fill="#1A9FFF" d="M10.0846 2.33648H13.3393V5.59121L15.5688 7.89135L13.3393 10.1915V13.4462H10.0846L7.78442 15.6758L5.48428 13.4462H2.22955V10.1915L0 7.89135L2.22955 5.59121V2.33648H5.48428L7.78442 0.106934L10.0846 2.33648ZM9.06155 4.80929C8.45205 4.55683 7.78095 4.49061 7.1339 4.61924C6.48675 4.74797 5.89221 5.066 5.42563 5.53257C4.95906 5.99914 4.64104 6.59368 4.51231 7.24084C4.38367 7.88789 4.4499 8.55898 4.70236 9.16848C4.95484 9.77777 5.38229 10.2985 5.93062 10.665C6.47925 11.0316 7.12458 11.2275 7.78442 11.2275C8.2228 11.2285 8.65743 11.1429 9.06263 10.9756C9.46772 10.8083 9.83546 10.5622 10.1454 10.2523C10.4553 9.94239 10.7013 9.57465 10.8686 9.16957C11.036 8.76436 11.1216 8.32974 11.1206 7.89135C11.1206 7.23152 10.9246 6.58619 10.558 6.03756C10.1916 5.48922 9.67084 5.06177 9.06155 4.80929Z"></path></g></svg>';

  // "You've unlocked 3/35 (9%)" over Steam's progress bar: a segment per set, and a trophy for each set completed (up to 3, like Steam).
  const progressHighlight = (doc, p) => {
    const A = K.ach(), D = K.details(), F = K.flex(), X = K.box(), W = K.award(), s = p.summary;
    const sets = s ? counted(p) : [], total = sets.reduce((n, sp) => n + sp.achievements.length, 0), earned = sets.reduce((n, sp) => n + earnedIn(sp), 0);
    const complete = sets.filter((sp) => earnedIn(sp) === sp.achievements.length).length;
    const award = (i) => { const n = el(doc, "span", { class: c(W, "CompletionAward", ...(i ? ["Stacked"] : [])), style: `--shine-index: ${i};` }); n.innerHTML = AWARD_SVG; return n; };
    return el(doc, "div", { class: c(D, "Highlight") + " " + c(A, "HighlightDiv") },
      el(doc, "div", { class: c(A, "UnlockedLabel") }, s ? [el(doc, "span", {}, `You've unlocked ${earned === total ? "all achievements! " : ""}${earned}/${total}`), " ",
        el(doc, "span", { class: c(A, "UnlockedLabelPercent") }, `(${percent(earned, total)}%)`), s.awardText && ` · ${s.awardText}`] : el(doc, "span", {}, p.message)),
      s && el(doc, "div", { class: c(A, "ProgressRow") },
        complete > 0 && el(doc, "div", { class: c(F, "Direction", "Align", "Gap", "Flex"), style: "--direction: row; --align: center; --gap: var(--spacing-0);" },
          el(doc, "span", { class: c(W, "CompletionAwardStack"), style: "--award-base: 32px;" }, Array.from({ length: Math.min(complete, 3) }, (_, i) => award(i)))),
        el(doc, "div", { class: c(A, "ProgressBar") }, el(doc, "div", { class: c(X, "Height", "Radius-lg", "Background", "Overflow") + " " + c(K.grid(), "Columns", "Grid"),
            style: `--height: 10px; --background: var(--color-dull-1); --overflow: hidden; --grid-columns: ${[...sets.map(earnedIn), total - earned].map((n) => `${n}fr`).join(" ")};` },
          sets.map(() => el(doc, "div", { class: c(K.bar(), "Unlocked") })), el(doc, "div", {})))));
  };

  const achievementsSection = (doc, p) => {
    const A = K.ach(), D = K.details(), s = p.summary;
    const unlocked = p.achievements.filter((r) => r.unlocked), locked = p.achievements.filter((r) => !r.unlocked);
    const labelled = (label, row, divider) => el(doc, "div", { class: c(A, "UnachievedSection") + (divider ? " " + c(A, "ShowDivider") : "") }, el(doc, "div", { class: c(A, "Label") }, label), row);
    const rows = [];
    if (unlocked.length) {
      const r = unlocked[0];  // most recent first (PanelBuilder sorts)
      rows.push(el(doc, "div", { class: c(A, "Featured", "RightAchievementSection") + " Panel" }, iconOf(doc, r, c(A, "Icon")),
        el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, r.title), el(doc, "div", { class: c(A, "Desc") }, r.description))));
    }
    if (unlocked.length > 1) rows.push(iconRow(doc, unlocked.slice(1)));
    if (locked.length) rows.push(labelled("Locked Achievements", iconRow(doc, locked), unlocked.length > 0));
    if (p.subsets?.length) rows.push(labelled("Subsets", subsetRow(doc, p), unlocked.length > 0 || locked.length > 0));
    const body = s && el(doc, "div", { class: c(D, "Body") }, rows,
      el(doc, "button", { class: c(K.button(), "AppDetailsButton", "BottomRight") + " " + steamButton, onclick: openPage }, "View My Achievements"));
    return section(doc, "RetroAchievements", ["AppDetailsSectionHasLabel", "RightColumnSection"], progressHighlight(doc, p), body);
  };


  const pointsText = (p) => [p.summary.pointsText, p.summary.hardcoreText].filter(Boolean).join(" · ");

  // Big Picture's YOUR STUFF: the game's details as a section.
  const detailsSection = (doc, p) => {
    const g = p.game;
    return section(doc, "Details", ["AppDetailsSectionHasLabel", "RightColumnSection"], el(doc, "div", { class: c(K.details(), "Body") + " sra-info" },
      p.notice && el(doc, "div", { class: "sra-notice" }, p.notice),
      el(doc, "dl", {}, el(doc, "dt", {}, "Game"), el(doc, "dd", {}, g.title), g.details.flatMap((d) => [el(doc, "dt", {}, d.label), el(doc, "dd", {}, d.value)]),
        p.summary && [el(doc, "dt", {}, "Points"), el(doc, "dd", {}, pointsText(p))]),
      p.updatedText && el(doc, "div", { class: "sra-muted" }, p.updatedText)));
  };

  // Desktop: the (i) button beside settings, controller and favourite, opening the game-details panel under the play bar, like a Steam game's.
  const INFO_SVG = '<svg xmlns="http://www.w3.org/2000/svg" class="SVGIcon_Button SVGIcon_Information" width="256px" height="256px" viewBox="0 0 256 256"><polyline class="I" points="86.883,110.957 152.894,110.957 152.894,181.406 177.117,181.406 177.117,202.485 86.883,202.485 86.883,181.775 109.441,181.775 109.441,130.372 86.883,130.372 "></polyline><circle class="I" cx="128.47" cy="67.607" r="25.517"></circle><circle fill="none" stroke="#000000" stroke-width="14" stroke-miterlimit="10" cx="128" cy="128" r="116.833"></circle></svg>';
  const gameInfo = (doc, p) => {
    const B = steamUI.classes("GameStatsSection", "MiniAchievements", "AchievementProgressRow");
    const G = steamUI.classes("AppGameInfoContainer", "AppDetailsCollapsed"), N = steamUI.classes("AssociationList", "GameDescription", "Portrait");
    const IM = steamUI.classes("GreyBackground", "Visibility", "Visible");
    if (!B.AppButtonsContainer || !G.AppGameInfoContainer || !N.Portrait) return [];
    const play = [...doc.querySelectorAll(sel(B.Container))].find((n) => n.matches(sel(B.InPage)));
    const bars = [...doc.querySelectorAll(sel(B.AppButtonsContainer))];  // the in-page play bar and its sticky copy
    if (!play || !bars.length) return [];
    const g = p.game;
    // The shortcut's own portrait capsule (jpg or png), else the game's RetroAchievements icon.
    const art = [...(appStore.GetCustomVerticalCapsuleURLs?.(appStore.GetAppOverviewByAppID(current.appid)) ?? []), g.iconURL];
    let at = 0;
    const img = el(doc, "img", { class: c(IM, "Image", "Visibility", "Visible"), src: art[0], alt: "", onerror: () => { if (++at < art.length) img.src = art[at]; } });
    const row = (label, value) => el(doc, "div", { class: c(N, "AssociationList") }, el(doc, "div", { class: c(N, "Label") }, `${label}:`),
      el(doc, "div", { class: c(N, "Association") }, el(doc, "span", { class: c(N, "Name") }, value)));
    const panel = el(doc, "div", { "data-sra-panel": "" }, el(doc, "div", { class: c(N, "Container") }, el(doc, "div", { class: c(N, "InnerContainer") },
      el(doc, "div", { class: c(N, "Portrait") }, el(doc, "div", { class: c(IM, "Container", "GreyBackground") + " " + c(N, "PortraitImage", "BoxArt") }, img)),
      el(doc, "div", { class: c(N, "Description", "SectionContainer") + " sra-info" },
        p.notice && el(doc, "div", { class: "sra-notice" }, p.notice),
        el(doc, "div", { class: "sra-actions" },
          el(doc, "button", { class: "sra-link", onclick: () => call("openURL", { url: g.raURL }) }, "View on RetroAchievements"),
          el(doc, "button", { class: "sra-link", onclick: () => openChooser(p.consoleId) }, "Wrong game?"),
          !current.bpm && el(doc, "button", { class: "sra-link", onclick: () => openArtwork(current.appid, appStore.GetAppOverviewByAppID(current.appid)?.display_name) }, "Choose artwork")),
        p.updatedText && el(doc, "div", { class: "sra-muted" }, p.updatedText)),
      el(doc, "div", { class: c(N, "Stats", "SectionContainer") }, g.details.map((d) => row(d.label, d.value)), p.summary && row("Points", pointsText(p))))));
    const buttons = bars.map((bar) => {
      const b = el(doc, "div", { class: c(B, "MenuButton") + " Focusable", "data-sra-panel": "", onclick: () => toggle(!current.infoOpen) });
      b.innerHTML = `<div class="${c(B, "DotDotDot")}">${INFO_SVG}</div>`;
      bar.insertBefore(b, bar.querySelector(sel(B.FavoriteButton)));
      return b;
    });
    const toggle = (open) => {
      current.infoOpen = open;
      panel.className = c(G, "AppGameInfoContainer", open ? "AppDetailsExpanded" : "AppDetailsCollapsed", "Glassy");
      panel.style.height = open ? `${panel.firstElementChild.offsetHeight}px` : "0px";
      for (const b of buttons) { b.classList.toggle((B.MenuActive ?? "sra-active").split(" ")[0], open); b.title = open ? "Hide game details" : "Show game details"; }
    };
    play.after(panel);
    toggle(!!current.infoOpen);  // stays open across re-renders of the same page
    return [panel, ...buttons];
  };

  const sel = (cls) => "." + CSS.escape((cls ?? "").split(" ")[0]);

  // Signing in and choosing the game happen on the desktop library page; Big Picture only says so.
  const messageSection = (doc, p) => section(doc, current?.bpm ? "Achievements" : "RetroAchievements", ["AppDetailsSectionHasLabel", "RightColumnSection"],
    el(doc, "div", { class: c(K.details(), "Body") + " sra-message" },
      el(doc, "div", {}, current?.bpm && (p.state === "signedOut" || p.state === "notMatched") ? `${p.message} Do this on the desktop library page.` : p.message),
      !current?.bpm && p.state === "signedOut" && el(doc, "button", { class: steamButton, onclick: () => openSettings() }, "Sign In"),
      !current?.bpm && p.state === "notMatched" && el(doc, "button", { class: steamButton, onclick: () => openChooser(p.consoleId) }, "Choose game"),
      !current?.bpm && el(doc, "button", { class: "sra-link", onclick: () => openArtwork(current.appid, appStore.GetAppOverviewByAppID(current.appid)?.display_name) }, "Choose artwork")));

  const render = (payload) => {
    const doc = steamUI.doc();
    if (!doc || !current) return;
    current.payload = payload;
    feedSteam(current.appid, payload);
    if (payload.game) ensureLeaderboards(payload);
    const refocus = current.bpm && current.tab === bpmTab(doc) ? [...doc.querySelectorAll("[data-sra-panel] .sra-item")].indexOf(doc.activeElement) : -1;
    removePanel();
    current.nodes = [];
    if (payload.state === "hidden") return;
    const host = steamUI.panelHost(doc, current.bpm);
    if (!host) return;
    ensureStyle(doc);
    if (current.bpm) {
      // Like a Steam game: unlocks in the ACTIVITY feed, the achievements section and details under YOUR STUFF.
      const tab = bpmTab(doc), p = payload, S = steamUI.classes("SeekTarget", "SpotlightLeftColumn").SeekTarget;
      const nodes = (tab === 0 ? [p.game ? activitySection(doc, p) : messageSection(doc, p)]
        : tab === 1 ? [p.summary ? bpmStuff(doc, p) : messageSection(doc, p), current.lb?.sets?.length && bpmLeaderboards(doc, current.lb.sets), p.game && detailsSection(doc, p)] : []).filter(Boolean);
      ((S && host.querySelector(sel(S))) ?? host).prepend(...nodes);
      current.nodes.push(...nodes);
      current.tab = tab;
      const items = nodes.flatMap((n) => registerNav(doc, n, navCleanups, n.querySelector(".sra-lb-card") ? { [BTN.OK]: "View Leaderboard" } : undefined));
      if (refocus >= 0) takeFocus(items[refocus]);  // the update rebuilt the item that had focus
      return;
    }

    const p = payload, main = p.game ? achievementsSection(doc, p) : messageSection(doc, p);
    host.prepend(main);
    current.nodes.push(main);
    if (current.lb?.sets?.length) { const lb = leaderboardsSection(doc, current.lb.sets); main.after(lb); current.nodes.push(lb); }
    main.querySelectorAll(".sra-iconrow").forEach((w) => w.sraFit?.());  // the subset row shows every icon
    const left = p.game && steamUI.findClass(doc, "LeftColumn");
    if (left) {
      const notice = K.notice().Body && left.querySelector("." + CSS.escape(K.notice().Body.split(" ")[0]));
      const box = notice?.closest("." + CSS.escape(c(K.details(), "AppDetailsSection").split(" ")[0]));
      if (box) { box.style.display = "none"; box.setAttribute("data-sra-hid", ""); }
      const activity = activitySection(doc, p);
      if (activity) { left.prepend(activity); current.nodes.push(activity); }
    }
    if (p.game) current.nodes.push(...gameInfo(doc, p));
  };

  // ---------------------------------------------------------------- Big Picture (Steam's own game-page markup: docs/steam-internals.md Q14)
  // Selected tab of Big Picture's game page (0 ACTIVITY, 1 YOUR STUFF, ...); the achievements page's own tabs don't count.
  const bpmTab = (doc) => {
    const T = steamUI.classes("GamepadTabbedPage", "TabRow", "TabTitle");
    if (!T.Tab || !T.Selected) return 0;
    const tabs = [...doc.querySelectorAll(sel(T.Tab))].filter((t) => !t.hasAttribute("data-sra") && t.querySelector(sel(T.TabTitle)));
    return Math.max(0, tabs.findIndex((t) => t.classList.contains(T.Selected.split(" ")[0])));
  };

  // A row of items that scrolls sideways (Steam's BoxCarousel, with the inline styles Steam gives it).
  const carousel = (doc, items, extraClass = "") => {
    const C = steamUI.classes("BoxCarousel", "BoxCarouselContents", "ListElement");
    return el(doc, "div", { style: "margin: 0 -10px" }, el(doc, "div", { class: "Panel sra-carousel" },
      el(doc, "div", { class: c(steamUI.classes("FocusRingRoot", "FocusRing"), "FocusRingRoot") }),
      el(doc, "div", { class: c(C, "BoxCarousel") + " " + extraClass },
        el(doc, "div", { class: c(C, "BoxCarouselContents"), style: "padding: 0 10px; scroll-padding: 0 10px" },
          el(doc, "div", { class: c(C, "ListElement"), role: "list", style: "display: contents" }, items.map((i) => el(doc, "div", { role: "listitem", style: "display: contents" }, i)))))));
  };

  // The focused icon opens into a card with its name, description and rarity, like Steam's; one per carousel.
  const detail = (item) => {
    const A = K.ach(), r = item.sraRow;
    for (const n of item.closest(".sra-carousel").querySelectorAll(".sra-item")) { n.classList.remove(...c(A, "Detailed").split(" ").filter(Boolean)); n.querySelector(".sra-card")?.remove(); }
    item.classList.add(...c(A, "Detailed").split(" ").filter(Boolean));
    item.append(el(item.ownerDocument, "div", { class: c(A, "AchivementCarouselItemDetails") + " sra-card" }, el(item.ownerDocument, "div", { class: c(A, "Name") }, r.title),
      el(item.ownerDocument, "div", { class: c(A, "Description") }, missableTag(item.ownerDocument, r), r.description), el(item.ownerDocument, "div", { class: c(A, "Achieved") }, [mode(r), r.rarityText].filter(Boolean).join(" · "))));
  };
  const carouselItem = (doc, r, open, big, url) => {
    const A = K.ach(), I = K.icon();
    const item = el(doc, "div", { class: c(A, "AchievementCarouselItem") + " Panel Focusable sra-item", role: "button", tabindex: "0", "aria-label": r.title, onclick: open,
        onfocus: () => { detail(item); item.scrollIntoView({ block: "nearest", inline: "nearest" }); } },
      el(doc, "div", { class: c(A, r.unlocked ? "Achieved" : "NotAchieved") + " Panel" }, el(doc, "div", { class: c(A, "AchievementHoverContainer") + " Panel" },
        el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "Icon", "CarouselIcon", ...(big ? ["Prioritized"] : [])) + hc(r) }, el(doc, "img", { class: c(I, "Icon"), src: r.badgeURL, alt: "" })), missableMark(doc, r))));
    item.sraRow = r;
    item.sraURL = url;
    return item;
  };

  // YOUR STUFF: Steam's Achievements section; unlocked icons, then locked, then one icon per subset. A opens the achievements page.
  const bpmStuff = (doc, p) => {
    const A = K.ach(), D = K.details(), open = openPage;
    const unlocked = p.achievements.filter((r) => r.unlocked), locked = p.achievements.filter((r) => !r.unlocked);
    const label = (text) => el(doc, "h3", { class: c(A, "LockedAchievementsLabel") + " sra-h2" }, text);
    const parts = [];
    if (unlocked.length) parts.push(carousel(doc, unlocked.map((r) => carouselItem(doc, r, open, true, achievementURL(r)))));
    if (locked.length) parts.push(label("Locked Achievements"), carousel(doc, locked.map((r) => carouselItem(doc, r, open, false, achievementURL(r)))));
    if (p.subsets?.length) parts.push(label("Subsets"), carousel(doc, p.subsets.map((sp) => carouselItem(doc, { title: subsetName(sp), description: sp.game?.title ?? "",
      badgeURL: sp.game?.iconURL, unlocked: true, rarityText: sp.summary?.text ?? sp.message }, () => earnedIn(sp) ? open() : openRA(sp.game?.raURL), true, sp.game?.raURL))));
    const first = parts[0].querySelector(".sra-item");
    if (first) detail(first);  // the most recent unlock, before anything has focus
    return section(doc, "Achievements", ["AppDetailsSectionHasLabel", "RightColumnSection"], progressHighlight(doc, p),
      el(doc, "div", { class: c(D, "Body") + " " + c(A, "BodyStopJiggle", "BasicAppDetailsAchievementsSectionBody") }, parts));
  };

  // "<you> achieved" events, one per day with unlocks, newest first, in Steam's activity feed markup:
  // Big Picture's ACTIVITY tab (each event a focusable carousel) or the desktop page's left column (a plain grid).
  const activitySection = (doc, p) => {
    const unlocked = p.achievements.filter((r) => r.unlocked);
    if (!unlocked.length) return null;
    const ACT = steamUI.classes("AppActivityDay", "EventHeadline"), F = steamUI.classes("ActivityFeedContainer", "Rollup", "FetchMoreContainer");
    const AV = steamUI.classes("avatarHolder", "avatarStatus", "avatarFrame"), N = steamUI.classes("playerName", "statusAndName");
    const A = K.ach(), I = K.icon(), me = window.friendStore?.m_FriendsUIFriendStore?.self?.persona, open = openPage;
    const days = [];
    for (const r of unlocked) { const last = days.at(-1); last && last.day === r.unlockedDay ? last.rows.push(r) : days.push({ day: r.unlockedDay, rows: [r] }); }
    // Big Picture: A opens the achievements page and X the achievement's web page; a desktop click opens the web page.
    const item = (r) => Object.assign(el(doc, "div", { class: c(ACT, "PrimaryAchievement") + " " + c(A, "Achieved", "Featured") + (current.bpm ? " Panel Focusable sra-item" : " Panel sra-stat"),
        tabindex: current.bpm ? "0" : undefined, onclick: current.bpm ? open : () => openRA(achievementURL(r)), onfocus: (e) => e.currentTarget.scrollIntoView({ block: "nearest", inline: "nearest" }) },
      el(doc, "div", { class: c(A, "AchievementHoverContainer") + " Panel" }, el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "Icon") + hc(r) }, el(doc, "img", { class: c(I, "Icon"), src: r.badgeURL, alt: "" }))),
      el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, r.title), el(doc, "div", { class: c(A, "Desc") }, r.description))), { sraURL: achievementURL(r) });
    const event = (rows) => el(doc, "div", { class: c(ACT, "Event", "NoCommentSupport") + " Panel" },
      el(doc, "div", { class: c(ACT, "EventHeadline") + " Panel" },
        el(doc, "div", { class: c(ACT, "EventActorAvatar") + " Panel" }, el(doc, "div", { class: c(AV, "avatarHolder") + " avatarHolder no-drag FillArea online" },
          el(doc, "div", { class: c(AV, "avatarStatus") + " avatarStatus right" }), me?.avatar_url_full && el(doc, "img", { class: c(AV, "avatar") + " avatar", src: me.avatar_url_full, alt: "" }))),
        el(doc, "span", { class: c(ACT, "SpanEvent") }, el(doc, "span", { class: c(ACT, "ActorName") + " online" }, el(doc, "span", { class: c(N, "playerName") }, me?.m_strPlayerName ?? "You")), " ", el(doc, "span", {}, "achieved"))),
      el(doc, "div", { class: c(ACT, "EventBody") }, current.bpm ? carousel(doc, rows.map(item), c(ACT, "ActivityAchievementUnlocked"))
        : el(doc, "div", { class: c(ACT, "ActivityAchievementUnlocked") + " Panel", style: "grid-template-columns: repeat(auto-fit, [col-start] minmax(49%, 260px) [col-end])" },
          rows.map((r) => el(doc, "div", { role: "listitem", style: "display: contents" }, item(r))))));
    const node = section(doc, "Activity", ["AppDetailsSectionHasLabel"], el(doc, "div", { class: c(K.details(), "Body") + " " + c(F, "InnerContainer") },
      el(doc, "div", { class: "Panel" }, days.map((d) => el(doc, "div", { class: c(ACT, "AppActivityDay") },
        el(doc, "h4", { class: c(ACT, "AppActivityDate") + " sra-h2" }, d.day ?? "", el(doc, "div", { class: c(ACT, "Rule") })), el(doc, "div", {}, event(d.rows)))))));
    node.classList.add(...c(F, "ActivityFeedContainer").split(" ").filter(Boolean));
    return node;
  };

  // ---------------------------------------------------------------- leaderboards
  // RetroAchievements' leaderboards for the game and its subsets: a section on the game page (YOUR STUFF in Big Picture)
  // and, on the desktop, a full view with every board's standings. Fetched once per game page; the panel never waits for them.
  const LB_TIME_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M9 1h6v2H9zM12 4a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm0 2a7 7 0 1 1 0 14 7 7 0 0 1 0-14zm-1 2v5.4l4.3 2.6 1-1.7-3.3-2V8z"/><path d="M18.3 4.3l1.4-1.4 1.8 1.8-1.4 1.4z"/></svg>';
  const LB_SCORE_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M6 2h12v2h3v3a5 5 0 0 1-4.6 5A6 6 0 0 1 13 15.9V19h4v3H7v-3h4v-3.1A6 6 0 0 1 7.6 12 5 5 0 0 1 3 7V4h3zm0 4H5v1a3 3 0 0 0 1.3 2.5A6 6 0 0 1 6 8zm12 0v2a6 6 0 0 1-.3 1.5A3 3 0 0 0 19 7V6z"/></svg>';
  const lbIcon = (doc, kind, extra = "") => { const n = el(doc, "span", { class: `sra-lb-kind sra-lb-${kind} ${extra}` }); n.innerHTML = kind === "time" ? LB_TIME_SVG : LB_SCORE_SVG; return n; };
  const num = (n) => Number(n).toLocaleString();
  const rankText = (r) => r ? `#${num(r)}` : "";
  const winsText = (b) => b.kind === "time" ? (b.lowerIsBetter ? "Fastest time wins" : "Longest time wins") : (b.lowerIsBetter ? "Lowest score wins" : "Highest score wins");
  // Best placings first (by share of the board, else rank), then boards without a score, in RetroAchievements' order.
  const placing = (b) => b.mine ? (b.topPercent ?? 100) * 1e7 + (b.mine.rank ?? 0) : Infinity;
  const lbGameIds = (p) => [p.game.id, ...(p.subsets ?? []).map((sp) => sp.game?.id)].filter((id, i, all) => id && all.indexOf(id) === i);
  const lbSetName = (p, gameId) => gameId === p.game.id ? "Base Game" : subsetName((p.subsets ?? []).find((sp) => sp.game?.id === gameId) ?? {});

  // Once per game page and game: render() draws the section from current.lb when it arrives.
  const lbFresh = new Set();  // appids with a new score since their leaderboards were fetched
  const ensureLeaderboards = (p) => {
    if (!current || !p.game) return;
    const key = lbGameIds(p).join(",");
    if (current.lb?.key === key) return;
    const appid = current.appid, lb = current.lb = { key, sets: null };
    const fresh = lbFresh.delete(appid);
    call("leaderboards", { gameIds: lbGameIds(p), fresh }, 90000).then(safe((sets) => {
      if (current?.appid !== appid || current.lb !== lb) return;
      lb.sets = sets.map((s) => ({ ...s, name: lbSetName(p, s.gameId) })).filter((s) => s.boards.length);
      if (current.payload) render(current.payload);
    }), (e) => log("error", `leaderboards: ${e?.message ?? e}`));
  };
  const allBoards = (sets) => sets.flatMap((s) => s.boards.map((b) => ({ ...b, setName: s.name, gameId: s.gameId })));

  const lbSummary = (doc, boards) => {
    const ranked = boards.filter((b) => b.mine), best = [...ranked].sort((a, b) => placing(a) - placing(b))[0];
    return el(doc, "div", { class: "sra-lb-summary" },
      el(doc, "div", { class: "sra-lb-summary-main" }, ranked.length
        ? [el(doc, "strong", {}, `Ranked on ${ranked.length}`), ` of ${num(boards.length)} leaderboard${boards.length === 1 ? "" : "s"}`]
        : `${num(boards.length)} leaderboard${boards.length === 1 ? "" : "s"} · set a score in the game to get ranked`),
      best && el(doc, "div", { class: "sra-lb-summary-best" }, "Best: ", el(doc, "span", { class: "sra-lb-accent" }, best.topPercent ? `Top ${best.topPercent}%` : rankText(best.mine.rank)),
        ` on ${best.title}`));
  };

  // Desktop: a Steam section under the achievements, the best placings first, then the full view.
  const LB_ROWS = 4;
  const leaderboardsSection = (doc, sets) => {
    const D = K.details(), boards = allBoards(sets).sort((a, b) => placing(a) - placing(b));
    const row = (b) => el(doc, "div", { class: "sra-lb-row" + (b.mine ? " sra-lb-ranked" : ""), role: "button", tabindex: "0", title: b.description,
        onclick: () => openLeaderboards(b.id), onkeydown: (e) => { if (e.key === "Enter") openLeaderboards(b.id); } },
      lbIcon(doc, b.kind),
      el(doc, "div", { class: "sra-lb-row-main" }, el(doc, "div", { class: "sra-lb-row-title" }, b.title),
        el(doc, "div", { class: "sra-lb-row-sub" }, sets.length > 1 ? `${b.setName} · ${b.description}` : b.description)),
      b.mine
        ? el(doc, "div", { class: "sra-lb-row-side" }, el(doc, "div", { class: "sra-lb-rank" }, rankText(b.mine.rank)),
          el(doc, "div", { class: "sra-lb-row-sub" }, [b.mine.score, b.topPercent && `Top ${b.topPercent}%`].filter(Boolean).join(" · ")))
        : el(doc, "div", { class: "sra-lb-row-side" }, el(doc, "div", { class: "sra-lb-record" }, b.top?.score ?? "No entries"),
          b.top && el(doc, "div", { class: "sra-lb-row-sub" }, `Record · ${b.top.user}`)));
    return section(doc, "Leaderboards", ["AppDetailsSectionHasLabel", "RightColumnSection"],
      el(doc, "div", { class: c(D, "Body") + " sra-lb-body" }, lbSummary(doc, boards), el(doc, "div", { class: "sra-lb-rows" }, boards.slice(0, LB_ROWS).map(row)),
        el(doc, "button", { class: c(K.button(), "AppDetailsButton", "BottomRight") + " " + steamButton, onclick: () => openLeaderboards() },
          boards.length > LB_ROWS ? `View All ${num(boards.length)} Leaderboards` : "View Leaderboards")));
  };

  // Big Picture: a row of board cards; A or X opens the board on RetroAchievements in Steam's browser.
  // A board as a card for controller rows (Big Picture's YOUR STUFF, the achievements page in Big Picture and Game Mode).
  const lbCard = (doc, b, open) => Object.assign(el(doc, "div", { class: "Panel Focusable sra-item sra-lb-card" + (b.mine ? " sra-lb-ranked" : ""), role: "button", tabindex: "0",
      "aria-label": b.title, onclick: open, onfocus: (e) => e.currentTarget.scrollIntoView({ block: "nearest", inline: "nearest" }) },
    el(doc, "div", { class: "sra-lb-card-head" }, lbIcon(doc, b.kind), b.mine && el(doc, "span", { class: "sra-lb-rank" }, rankText(b.mine.rank))),
    el(doc, "div", { class: "sra-lb-row-title" }, b.title),
    el(doc, "div", { class: "sra-lb-row-sub" }, b.mine ? [b.mine.score, b.topPercent && `Top ${b.topPercent}%`].filter(Boolean).join(" · ") : b.top ? `Record ${b.top.score} · ${b.top.user}` : "No entries yet")), { sraURL: b.url, sraBoard: b });
  const bpmLeaderboards = (doc, sets) => {
    const D = K.details(), boards = allBoards(sets).sort((a, b) => placing(a) - placing(b));
    return section(doc, "Leaderboards", ["AppDetailsSectionHasLabel", "RightColumnSection"],
      el(doc, "div", { class: c(D, "Body") + " sra-lb-body" }, lbSummary(doc, boards), carousel(doc, boards.map((b) => lbCard(doc, b, () => openRA(b.url))))));
  };

  // Steam's achievements page in Big Picture, and the same page in Game Mode's in-game menu: a strip of boards under the
  // summary, and under it the focused board's standings: your score, the place above yours, the top three and your neighbours.
  const stripData = new Map();  // appid → { sets } once loaded, {} while loading
  const strip = { node: null, cleanups: [], appid: null };
  const steamBrowser = (url) => SteamClient.URL.ExecuteSteamURL(`steam://openurl/${url}`);
  const removeStrip = () => {
    strip.cleanups.reverse().forEach((fn) => { try { fn(); } catch (_) {} });
    strip.cleanups = [];
    strip.node?.remove();
    strip.node = null;
  };
  const stripSets = (appid) => {
    if (current?.appid === appid && current.lb?.sets) return current.lb.sets;
    const hit = stripData.get(appid);
    if (hit) return hit.sets;
    stripData.set(appid, {});
    (async () => {
      const shortcut = await steamUI.shortcut(appid);
      if (!shortcut.exe) return stripData.delete(appid);  // details not in yet: next tick asks again
      const panel = await call("getPanel", { shortcut }, 180000);
      if (panel?.state !== "matched") return stripData.set(appid, { sets: [] });
      const sets = await call("leaderboards", { gameIds: lbGameIds(panel), fresh: lbFresh.delete(appid) }, 90000);
      stripData.set(appid, { sets: sets.map((s) => ({ ...s, name: lbSetName(panel, s.gameId) })).filter((s) => s.boards.length) });
    })().catch((e) => { stripData.delete(appid); log("error", `leaderboards strip: ${e?.message ?? e}`); });
    return undefined;
  };
  const standingRow = (doc, e) => el(doc, "div", { class: "sra-lb-tr" + (e.isMe ? " sra-lb-me" : "") + (e.rank <= 3 ? ` sra-lb-top${e.rank}` : "") },
    el(doc, "div", { class: "sra-lb-td-rank" }, rankText(e.rank)),
    el(doc, "div", { class: "sra-lb-td-user" }, el(doc, "img", { class: "sra-lb-avatar", src: e.avatarURL, alt: "", width: "28", height: "28" }), el(doc, "span", {}, e.user),
      e.isMe && el(doc, "span", { class: "sra-lb-you" }, "You")),
    el(doc, "div", { class: "sra-lb-td-score" }, e.score), el(doc, "div", { class: "sra-lb-td-date" }, e.dateText ?? ""));
  let standingSeq = 0;
  const showStanding = safe(async (doc, detail, b) => {
    const mine = ++standingSeq;
    detail.replaceChildren(
      el(doc, "div", { class: "sra-lb-detail-head" },
        el(doc, "div", { class: "sra-lb-head-main" }, el(doc, "div", { class: "sra-lb-row-title sra-lb-detail-title" }, b.title), el(doc, "div", { class: "sra-lb-row-sub" }, `${b.description} · ${winsText(b)}`)),
        b.mine && el(doc, "div", { class: "sra-lb-you-rank" }, el(doc, "div", { class: "sra-lb-rank sra-lb-big" }, rankText(b.mine.rank)),
          el(doc, "div", { class: "sra-lb-row-sub" }, [b.mine.score, b.total && `of ${num(b.total)}`, b.topPercent && `Top ${b.topPercent}%`].filter(Boolean).join(" · ")))),
      el(doc, "div", { class: "sra-muted sra-lb-loading" }, "Loading standings…"));
    const rank = b.mine?.rank;
    let top, around;
    try {
      [top, around] = await Promise.all([call("leaderboardEntries", { id: b.id, offset: 0, count: rank && rank <= 8 ? 8 : 3 }, 30000),
        rank > 8 ? call("leaderboardEntries", { id: b.id, offset: rank - 4, count: 7 }, 30000) : null]);
    } catch (e) {
      if (mine === standingSeq && detail.isConnected) detail.lastElementChild.replaceWith(el(doc, "div", { class: "sra-error sra-lb-loading" },
        /429/.test(e?.message) ? "RetroAchievements is busy right now. Press A to try again in a moment." : "Couldn't load the standings. Press A to try again."));
      throw e;
    }
    if (mine !== standingSeq || !detail.isConnected) return;
    // The nearest score above yours: what it takes to move up a place.
    const ahead = [...top.entries, ...(around?.entries ?? [])].filter((e) => rank && e.rank < rank && !e.isMe).sort((x, y) => y.rank - x.rank)[0];
    detail.lastElementChild.replaceWith(el(doc, "div", { class: "sra-lb-standing" },
      ahead && el(doc, "div", { class: "sra-lb-next" }, el(doc, "span", { class: "sra-lb-you-label" }, "Next place up"), ` ${rankText(ahead.rank)} · ${ahead.score} by ${ahead.user}`),
      !rank && el(doc, "div", { class: "sra-lb-next" }, el(doc, "span", { class: "sra-lb-you-label" }, "No score yet"), " Your emulator submits it when you finish this challenge."),
      el(doc, "div", { class: "sra-lb-table" }, top.entries.map((e) => standingRow(doc, e)),
        around && el(doc, "div", { class: "sra-lb-gap" }, `${num(Math.max(0, around.entries[0]?.rank - top.entries.length - 1))} more`),
        around?.entries.map((e) => standingRow(doc, e)))));
  });
  const ensureStrip = (doc, appid) => {
    if (strip.node?.isConnected && strip.appid === appid && strip.node.ownerDocument === doc) return;
    removeStrip();
    const sets = stripSets(appid);
    if (!sets?.length) return;
    // Steam's page column: the header, then the toggles and the list; the strip goes between them.
    const toggle = [...doc.querySelectorAll("span, div")].find((n) => n.childElementCount === 0 && n.textContent.trim() === "Show Global Stats");
    const heading = steamUI.findClass(doc, "SummaryHeading");
    let anchor = toggle;
    while (anchor?.parentElement && heading && !anchor.parentElement.contains(heading)) anchor = anchor.parentElement;
    if (!anchor?.parentElement || !heading) return;
    ensureStyle(doc);
    const boards = allBoards(sets).sort((a, b) => placing(a) - placing(b));
    const detail = el(doc, "div", { class: "sra-lb-detail" });
    const cards = boards.map((b) => {
      const card = lbCard(doc, b, () => showStanding(doc, detail, b));
      card.addEventListener("focus", safe(() => { if (detail.sraBoard !== b) { detail.sraBoard = b; showStanding(doc, detail, b); } }));
      return card;
    });
    strip.node = el(doc, "div", { class: "sra-lb-strip", "data-sra-lbstrip": "" },
      el(doc, "div", { class: "sra-lb-strip-head" }, el(doc, "span", { class: "sra-lb-strip-title" }, `Leaderboards (${num(boards.length)})`), lbSummary(doc, boards)),
      carousel(doc, cards), detail);
    strip.appid = appid;
    anchor.before(strip.node);
    detail.sraBoard = boards[0];
    showStanding(doc, detail, boards[0]);
    // X opens the board in Steam's browser, which shows over the game in Game Mode.
    cards.forEach((card) => card.addEventListener("vgp_onbuttondown", (e) => { if (e.detail?.button === BTN.SECONDARY) { handled(e); steamBrowser(card.sraURL); } }, true));
    registerNav(doc, strip.node, strip.cleanups, { [BTN.OK]: "Show Standings" });
  };

  // The full view: boards down the left, the chosen board's standings on the right.
  const LB_PAGE = 50;
  const openLeaderboards = safe(async (selectId) => {
    const doc = desktopDoc();
    const sets = current?.lb?.sets, p = current?.payload;
    if (!doc || !sets?.length || !p?.game) return;
    ensureStyle(doc);
    const boards = allBoards(sets), cache = new Map();  // board id → { total, rows: Map(offset → entries) }
    const st = { filter: "all", query: "", selected: boards.find((b) => b.id === selectId) ?? [...boards].sort((a, b) => placing(a) - placing(b))[0], seq: 0 };
    const search = el(doc, "input", { class: "sra-input", type: "search", placeholder: "Search leaderboards", spellcheck: "false" });
    const tabs = el(doc, "div", { class: "sra-lb-tabs", role: "tablist" });
    const list = el(doc, "div", { class: "sra-lb-list", role: "listbox", tabindex: "0", "aria-label": "Leaderboards" });
    const main = el(doc, "div", { class: "sra-lb-main" });
    const visible = () => boards.filter((b) => (st.filter === "all" || b.mine) && (!st.query || `${b.title} ${b.description}`.toLowerCase().includes(st.query)));

    const drawTabs = () => tabs.replaceChildren(...[["all", "All", boards.length], ["ranked", "Ranked", boards.filter((b) => b.mine).length]].map(([id, label, n]) =>
      el(doc, "button", { class: "sra-lb-tab" + (st.filter === id ? " sra-lb-on" : ""), role: "tab", "aria-selected": String(st.filter === id), onclick: () => { st.filter = id; drawTabs(); drawList(); } },
        label, el(doc, "span", { class: "sra-lb-count" }, num(n)))));
    const drawList = () => {
      const shown = visible(), groups = sets.length > 1 ? sets.map((s) => [s.name, shown.filter((b) => b.gameId === s.gameId)]) : [[null, shown]];
      list.replaceChildren(...groups.flatMap(([name, bs]) => bs.length ? [name && el(doc, "div", { class: "sra-lb-group" }, name), ...bs.map((b) =>
        el(doc, "div", { class: "sra-lb-item" + (b === st.selected ? " sra-lb-on" : ""), role: "option", "aria-selected": String(b === st.selected), onclick: () => select(b) },
          lbIcon(doc, b.kind), el(doc, "div", { class: "sra-lb-row-main" }, el(doc, "div", { class: "sra-lb-row-title" }, b.title),
            el(doc, "div", { class: "sra-lb-row-sub" }, b.mine ? [rankText(b.mine.rank), b.topPercent && `Top ${b.topPercent}%`].filter(Boolean).join(" · ") : b.top ? `Record ${b.top.score}` : "No entries"))))] : []),
        shown.length ? null : el(doc, "div", { class: "sra-muted sra-lb-empty" }, st.filter === "ranked" && !st.query ? "You haven't set a score on any of these yet." : "No leaderboards match."));
      list.querySelector(".sra-lb-on")?.scrollIntoView({ block: "nearest" });
    };
    const select = (b) => { if (!b) return; st.selected = b; drawList(); drawBoard(); };
    // Up and down move through the list, as in Steam's own lists.
    list.addEventListener("keydown", safe((e) => {
      if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
      e.preventDefault();
      const shown = visible(), i = shown.indexOf(st.selected);
      select(shown[Math.max(0, Math.min(shown.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))]);
    }));
    let timer = null;
    search.addEventListener("input", safe(() => { clearTimeout(timer); timer = setTimeout(safe(() => { st.query = search.value.trim().toLowerCase(); drawList(); }), 120); }));

    const page = async (b, offset) => {
      const c = cache.get(b.id) ?? cache.set(b.id, { total: b.total ?? null, rows: new Map() }).get(b.id);
      if (!c.rows.has(offset)) {
        const r = await call("leaderboardEntries", { id: b.id, offset, count: LB_PAGE }, 30000);
        c.total = r.total;
        c.rows.set(offset, r.entries);
      }
      return { total: c.total, entries: c.rows.get(offset) };
    };
    const avatar = (e, size) => el(doc, "img", { class: "sra-lb-avatar", src: e.avatarURL, alt: "", loading: "lazy", width: String(size), height: String(size),
      onerror: (ev) => { ev.currentTarget.style.visibility = "hidden"; } });
    const tableRow = (e) => el(doc, "div", { class: "sra-lb-tr" + (e.isMe ? " sra-lb-me" : "") + (e.rank <= 3 ? ` sra-lb-top${e.rank}` : ""), role: "row" },
      el(doc, "div", { class: "sra-lb-td-rank" }, rankText(e.rank)),
      el(doc, "div", { class: "sra-lb-td-user" }, avatar(e, 28), el(doc, "span", {}, e.user), e.isMe && el(doc, "span", { class: "sra-lb-you" }, "You")),
      el(doc, "div", { class: "sra-lb-td-score" }, e.score),
      el(doc, "div", { class: "sra-lb-td-date" }, e.dateText ?? ""));
    const podium = (entries) => {
      const top = entries.slice(0, 3);
      if (top.length < 3) return null;
      return el(doc, "div", { class: "sra-lb-podium" }, [top[1], top[0], top[2]].map((e) => el(doc, "div", { class: `sra-lb-step sra-lb-top${e.rank}` + (e.isMe ? " sra-lb-me" : "") },
        el(doc, "div", { class: "sra-lb-medal" }, String(e.rank)), avatar(e, e.rank === 1 ? 64 : 52),
        el(doc, "div", { class: "sra-lb-step-user" }, e.user), el(doc, "div", { class: "sra-lb-step-score" }, e.score))));
    };

    const drawBoard = safe(async () => {
      const b = st.selected, mine = ++st.seq;
      if (!b) { main.replaceChildren(el(doc, "div", { class: "sra-muted sra-lb-empty" }, "This game has no leaderboards.")); return; }
      const table = el(doc, "div", { class: "sra-lb-table", role: "table" });
      const meta = el(doc, "div", { class: "sra-lb-meta" }, el(doc, "span", {}, winsText(b)), b.total != null && el(doc, "span", {}, `${num(b.total)} entries`));
      const you = b.mine
        ? el(doc, "div", { class: "sra-lb-you-card" },
          avatar(b.mine, 56),
          el(doc, "div", { class: "sra-lb-you-main" },
            el(doc, "div", { class: "sra-lb-you-label" }, "Your best"),
            el(doc, "div", { class: "sra-lb-you-score" }, b.mine.score),
            el(doc, "div", { class: "sra-lb-row-sub" }, [b.mine.dateText && `Set ${b.mine.dateText}`].filter(Boolean).join(""))),
          el(doc, "div", { class: "sra-lb-you-rank" },
            el(doc, "div", { class: "sra-lb-rank sra-lb-big" }, rankText(b.mine.rank)),
            el(doc, "div", { class: "sra-lb-row-sub" }, b.total ? `of ${num(b.total)}${b.topPercent ? ` · Top ${b.topPercent}%` : ""}` : ""),
            // How far up the board you are: full at first place.
            b.topPercent && el(doc, "div", { class: "sra-lb-meter", role: "img", "aria-label": `Top ${b.topPercent}%` }, el(doc, "div", { style: `width: ${Math.max(2, 100 - b.topPercent + 1)}%` }))),
          el(doc, "button", { class: "sra-btn", onclick: () => jump() }, "Jump to My Rank"))
        : el(doc, "div", { class: "sra-lb-you-card sra-lb-none" }, lbIcon(doc, b.kind, "sra-lb-kind-big"),
          el(doc, "div", { class: "sra-lb-you-main" }, el(doc, "div", { class: "sra-lb-you-label" }, "No score yet"),
            el(doc, "div", { class: "sra-lb-row-sub" }, `${b.description} Your emulator submits it when you do.`)));
      main.replaceChildren(
        el(doc, "div", { class: "sra-lb-head" }, lbIcon(doc, b.kind, "sra-lb-kind-big"),
          el(doc, "div", { class: "sra-lb-head-main" }, el(doc, "div", { class: "sra-lb-title" }, b.title), el(doc, "div", { class: "sra-lb-desc" }, b.description), meta),
          el(doc, "button", { class: "sra-link", onclick: () => openRA(b.url) }, "View on RetroAchievements")),
        you, el(doc, "div", { class: "sra-lb-podium-slot" }),
        el(doc, "div", { class: "sra-lb-thead", role: "row" }, ["Rank", "Player", b.kind === "time" ? "Time" : "Score", "Date"].map((h) => el(doc, "div", { role: "columnheader" }, h))),
        table);
      table.replaceChildren(el(doc, "div", { class: "sra-muted sra-lb-loading" }, "Loading standings…"));
      let first;
      try { first = await page(b, 0); } catch (e) {
        if (mine === st.seq) table.replaceChildren(el(doc, "div", { class: "sra-error sra-lb-loading" }, "Couldn't reach RetroAchievements. Try again in a moment."));
        throw e;
      }
      if (mine !== st.seq) return;
      if (b.total == null) meta.append(el(doc, "span", {}, `${num(first.total)} entries`));
      main.querySelector(".sra-lb-podium-slot").replaceWith(podium(first.entries) ?? el(doc, "div"));
      table.replaceChildren();
      // Pages load as the list scrolls; a jump to your rank skips ahead to the page around it, with a marker for the rows in between.
      let next = 0, loading = false;
      const more = safe(async () => {
        if (loading || next >= first.total || mine !== st.seq) return;
        loading = true;
        try {
          const r = await page(b, next);
          if (mine !== st.seq) return;
          table.append(...r.entries.map(tableRow));
          next += LB_PAGE;
        } finally { loading = false; }
      });
      await more();
      main.onscroll = safe(() => { if (main.scrollTop + main.clientHeight > main.scrollHeight - 400) more(); });
      jump = safe(async () => {
        if (!b.mine?.rank) return;
        const offset = Math.floor((b.mine.rank - 1) / LB_PAGE) * LB_PAGE;
        if (offset >= next) {
          const r = await page(b, offset);
          if (mine !== st.seq) return;
          table.append(el(doc, "div", { class: "sra-lb-gap" }, `${num(offset - next)} more`), ...r.entries.map(tableRow));
          next = offset + LB_PAGE;
        }
        const me = table.querySelector(".sra-lb-me");
        me?.scrollIntoView({ block: "center", behavior: "smooth" });
        me?.classList.remove("sra-lb-flash"); void me?.offsetWidth; me?.classList.add("sra-lb-flash");
      });
    });
    let jump = () => {};

    const node = overlay(doc, el(doc, "div", { class: "sra-lb-dialog-title" }, el(doc, "img", { src: p.game.iconURL, alt: "" }),
      el(doc, "div", {}, el(doc, "div", {}, "Leaderboards"), el(doc, "div", { class: "sra-muted" }, p.game.title))),
      el(doc, "div", { class: "sra-lb-layout" }, el(doc, "div", { class: "sra-lb-side" }, el(doc, "div", { class: "sra-lb-side-top" }, search, tabs), list), main));
    node.firstElementChild.classList.add("sra-lb-dialog");
    drawTabs();
    drawList();
    drawBoard();
    list.focus();
  });

  // ---------------------------------------------------------------- overlays
  let closeOverlay = null;
  const overlay = (doc, title, ...body) => {
    closeOverlay?.();
    const onKey = safe((e) => { if (e.key === "Escape") close(); });
    const node = el(doc, "div", { class: "sra-overlay", onclick: (e) => { if (e.target === node) close(); } },
      el(doc, "div", { class: "sra-dialog" },
        el(doc, "div", { class: "sra-dialog-head" }, title, el(doc, "button", { class: "sra-btn", onclick: () => close() }, "Close")),
        ...body));
    const close = () => { node.remove(); doc.removeEventListener("keydown", onKey, true); closeOverlay = null; };
    doc.addEventListener("keydown", onKey, true);
    doc.body.append(node);
    closeOverlay = close;
    return node;
  };

  const openChooser = async (consoleId) => {
    const doc = steamUI.doc();
    if (!doc || !current) return;
    const appid = current.appid, shortcut = current.shortcut;
    const consoles = await call("consoles");
    const select = el(doc, "select", {}, el(doc, "option", { value: "" }, "Choose a console"),
      consoles.map((c) => el(doc, "option", { value: String(c.id) }, c.name)));
    if (consoleId) select.value = String(consoleId);
    const input = el(doc, "input", { type: "search", placeholder: "Search games" });
    const results = el(doc, "div", { class: "sra-dialog-body" });
    let timer = null, seq = 0;
    const search = safe(async () => {
      const mine = ++seq;
      results.replaceChildren();
      if (!select.value) return;
      const hits = await call("searchGames", { consoleId: Number(select.value), query: input.value });
      if (mine !== seq) return;
      results.replaceChildren(...hits.map((g) => el(doc, "div", { class: "sra-row sra-pick", onclick: async () => {
        let payload;
        try {
          payload = await call("chooseGame", { shortcut, gameId: g.gameId, consoleId: Number(select.value) });
        } catch (e) {
          log("error", `chooseGame: ${e?.message ?? e}`);
          results.replaceChildren(el(doc, "div", { class: "sra-error" }, "Couldn't save your choice. Try again."));
          return;
        }
        closeOverlay?.();
        if (current?.appid === appid) render(payload);
      } }, el(doc, "img", { src: g.iconURL, alt: "" }),
        el(doc, "div", { class: "sra-row-main" }, el(doc, "div", { class: "sra-row-title" }, g.title)),
        el(doc, "div", { class: "sra-row-side" }, `${g.numAchievements} achievements`))));
    });
    input.addEventListener("input", safe(() => { clearTimeout(timer); timer = setTimeout(search, 300); }));
    select.addEventListener("change", search);
    overlay(doc, "Choose game", el(doc, "div", { class: "sra-search" }, select, input), results);
    input.focus();
    search();
  };

  // "Choose artwork": pick the SteamGridDB game, then the exact images; each click applies at once (Steam asset types: 0 cover, 3 wide, 1 hero, 2 logo).
  const ART_KINDS = [["grid", "Cover"], ["wide", "Wide Cover"], ["hero", "Hero"], ["logo", "Logo"], ["icon", "Icon"]];
  const openArtwork = safe(async (appid, name) => {
    const doc = steamUI.doc();
    if (!doc) return;
    const input = el(doc, "input", { class: "sra-input", type: "search", placeholder: "Search SteamGridDB", value: name ?? "", spellcheck: "false" });
    const body = el(doc, "div", { class: "sra-dialog-body" });
    const status = el(doc, "div", { class: "sra-muted" });
    const useAll = el(doc, "button", { class: "sra-btn", style: "display: none" }, "Use All Best");
    let seq = 0, gameId = null, kind = "grid", applied = {};
    const say = (text, bad) => { status.className = bad ? "sra-error" : "sra-muted"; status.textContent = text; };
    const fail = (what, e) => { log("error", `${what}: ${e?.message ?? e}`); say(`${what} failed (${e?.message ?? e}). Try again.`, true); };

    const showGames = async () => {
      const mine = ++seq;
      gameId = null;
      useAll.style.display = "none";
      body.replaceChildren(el(doc, "div", { class: "sra-muted" }, "Searching…"));
      let hits;
      try { hits = await call("artworkSearch", { query: input.value }, 30000); } catch (e) { fail("Search", e); body.replaceChildren(); return; }
      if (mine !== seq) return;
      say("");
      body.replaceChildren(...(hits.length ? hits : [null]).map((g) => !g ? el(doc, "div", { class: "sra-muted" }, "No games found.")
        : el(doc, "div", { class: "sra-row sra-pick", onclick: () => { gameId = g.id; applied = {}; useAll.style.display = ""; showOptions(); } },
          el(doc, "div", { class: "sra-row-main" }, el(doc, "span", { class: "sra-row-title" }, g.name), g.verified && el(doc, "span", { class: "sra-art-tag" }, "Verified")),
          el(doc, "div", { class: "sra-row-side" }, g.year ? String(g.year) : ""))));
    };

    const showOptions = async () => {
      const mine = ++seq, k = kind;
      const grid = el(doc, "div", { class: `sra-art-grid sra-art-k-${k}` }, el(doc, "div", { class: "sra-muted" }, "Loading…"));
      body.replaceChildren(el(doc, "div", { class: "sra-art-tabs" },
        ART_KINDS.map(([id, label]) => el(doc, "button", { class: "sra-art-tab" + (id === k ? " sra-art-on" : ""), onclick: () => { kind = id; showOptions(); } }, label)),
        el(doc, "button", { class: "sra-link", onclick: () => showGames() }, "Other games")), grid);
      let options;
      try { options = await call("artworkOptions", { gameId, kind: k }, 30000); } catch (e) { fail("Loading images", e); grid.replaceChildren(); return; }
      if (mine !== seq) return;
      grid.replaceChildren(...(options.length ? options : [null]).map((o) => !o ? el(doc, "div", { class: "sra-muted" }, "No images for this game.") : el(doc, "div", {
        class: "sra-art-thumb" + (applied[k] === o.url ? " sra-art-on" : ""),
        title: [o.style, o.width && `${o.width}x${o.height}`, o.author && `by ${o.author}`].filter(Boolean).join(" · "),
        onclick: async (e) => {
          const tile = e.currentTarget;
          say("Applying…");
          try {
            const r = await call("applyArtwork", { appid, kind: k, url: o.url }, 60000);
            await applyArt(appid, { images: r.image ? [r.image] : [], iconPath: r.iconPath });
            applied[k] = o.url;
            for (const t of tile.parentNode?.children ?? []) t.classList.toggle("sra-art-on", t === tile);
            say("Applied");
          } catch (err) { fail("Applying", err); }
        } }, el(doc, "img", { src: o.thumb, loading: "lazy", alt: "" }), el(doc, "span", { class: "sra-art-check" }, "✓"))));
    };

    useAll.addEventListener("click", safe(async () => {
      useAll.disabled = true;
      say("Applying…");
      try {
        await applyArt(appid, await call("autoArtwork", { appid, gameId }, 120000));
        applied = {};
        say("Applied the best of each kind");
      } catch (e) { fail("Applying", e); }
      useAll.disabled = false;
    }));
    const go = el(doc, "button", { class: "sra-btn", onclick: () => showGames() }, "Search");
    input.addEventListener("keydown", safe((e) => { if (e.key === "Enter") showGames(); }));
    const node = overlay(doc, "Choose artwork", el(doc, "div", { class: "sra-search" }, input, go), body, el(doc, "div", { class: "sra-footer" }, status, useAll));
    node.firstElementChild.classList.add("sra-art-dialog");
    input.focus();
    if (input.value) showGames();
  });

  // ---------------------------------------------------------------- settings and add games (desktop library only)
  // Opened from outside (the Mac menu, first run) through pendingOpen, so tick() has settled the page and won't close them.
  let pendingOpen = null;
  const desktopDoc = () => { const s = steamUI.surface(); return s && !s.bpm ? s.doc : null; };
  const head = (doc, text) => el(doc, "div", { class: "sra-head" }, text);
  const signedInChanged = () => { syncPlaytimes(); if (current) { current.payload = null; load(current.appid, "getPanel"); } };

  // navigator.clipboard exists in Steam's desktop window (checked 2026-11-09) but needs that window focused; execCommand is the fallback.
  const copyText = async (doc, area) => {
    try { await doc.defaultView.navigator.clipboard.writeText(area.value); return true; } catch (_) {}
    try { area.focus(); area.select(); return doc.execCommand("copy"); } catch (_) { return false; }
  };

  const openSettings = safe(async () => {
    const doc = desktopDoc();
    if (!doc) { pendingOpen = openSettings; return; }
    ensureStyle(doc);
    const body = el(doc, "div", { class: "sra-dialog-body sra-form" });
    overlay(doc, "Steam RetroAchievements", body);
    const draw = safe(async () => {
      const s = await call("settings");
      const kids = [head(doc, "RetroAchievements")];
      if (s.username) {
        kids.push(el(doc, "div", { class: "sra-actions" }, `Signed in as ${s.username}`,
          el(doc, "button", { class: "sra-btn", onclick: async () => { await call("signOut"); signedInChanged(); draw(); } }, "Sign Out")));
      } else {
        const user = el(doc, "input", { class: "sra-input", placeholder: "Your RetroAchievements username", autocomplete: "off", spellcheck: "false" });
        const key = el(doc, "input", { class: "sra-input", type: "password", placeholder: "Paste your Web API key", autocomplete: "off" });
        const error = el(doc, "div", { class: "sra-error" });
        const submit = el(doc, "button", { class: "sra-btn", type: "submit" }, "Sign In");
        kids.push(el(doc, "form", { onsubmit: async (e) => {
          e.preventDefault();
          if (!user.value.trim() || !key.value.trim()) { error.textContent = "Enter your username and Web API key."; return; }
          submit.disabled = true;
          error.textContent = "";
          const r = await call("signIn", { username: user.value, apiKey: key.value }).finally(() => { submit.disabled = false; });
          if (r.error) { error.textContent = r.error; return; }
          signedInChanged();
          draw();
        } },
        el(doc, "label", {}, "Username", user), el(doc, "label", {}, "Web API key", key),
        el(doc, "button", { class: "sra-link", type: "button", onclick: () => call("openURL", { url: "https://retroachievements.org/settings?tab=applications" }) }, "Find your Web API key"),
        error, el(doc, "div", { class: "sra-actions" }, submit)));
        setTimeout(() => user.focus(), 0);
      }
      kids.push(head(doc, "Emulators"), el(doc, "dl", { class: "sra-details" },
        s.emulators.flatMap((e) => [el(doc, "dt", {}, e.name), el(doc, "dd", {}, e.installed ? "Installed" : "Not installed")])));
      const login = el(doc, "input", { type: "checkbox", onchange: async () => { login.checked = await call("setOpenAtLogin", { on: login.checked }); } });
      login.checked = s.openAtLogin;
      const port = el(doc, "input", { type: "checkbox", onchange: async () => { port.checked = await call("setKeepDebugPort", { on: port.checked }); } });
      port.checked = s.keepDebugPort;
      kids.push(head(doc, "General"), el(doc, "label", { class: "sra-check" }, login, "Open at login"),
        el(doc, "label", { class: "sra-check" }, port, "Keep Steam's debug port on after quitting"),
        el(doc, "span", { class: "sra-muted" }, "The app needs Steam's developer switch, which opens port 8080 on this computer. Turn this off to remove the switch when the app quits; Steam closes the port the next time it starts."));
      if (s.updateVersion) {
        const note = el(doc, "span", { class: "sra-muted" }, `Version ${s.updateVersion} is available.`);
        const update = el(doc, "button", { class: "sra-btn", onclick: async () => {
          update.disabled = true;
          note.textContent = "Downloading the update…";
          const r = await call("installUpdate").catch(() => ({ error: "The update couldn't be installed." }));
          if (r.error) { note.textContent = r.error; update.disabled = false; return; }
          note.textContent = "Restarting with the new version…";
        } }, "Update Now");
        kids.push(head(doc, "Update"), el(doc, "div", { class: "sra-actions" }, note, update));
      }
      const copied = el(doc, "span", { class: "sra-muted" });
      const manual = el(doc, "div");
      const copy = el(doc, "button", { class: "sra-btn", onclick: async () => {
        copy.disabled = true;
        copied.textContent = "";
        manual.replaceChildren();
        try {
          const info = await (async () => SteamClient.System.GetSystemInfo())().catch(() => null);
          const area = el(doc, "textarea", { class: "sra-input sra-diagnostics", readonly: "", rows: "10", style: "position: fixed; opacity: 0" },
            await call("diagnostics", { steamBuild: Number.isInteger(info?.nSteamVersion) ? info.nSteamVersion : undefined }));
          manual.replaceChildren(area);
          if (await copyText(doc, area)) { manual.replaceChildren(); copied.textContent = "Copied"; copy.disabled = false; copy.focus(); return; }
          area.removeAttribute("style");
          area.focus();
          area.select();
          copied.textContent = "Couldn't reach the clipboard. Copy the selected text below.";
        } catch (e) {
          copied.textContent = "Couldn't collect the diagnostics.";
          throw e;
        } finally {
          copy.disabled = false;
        }
      } }, "Copy Diagnostics");
      kids.push(head(doc, "Troubleshooting"), el(doc, "div", { class: "sra-actions" },
        el(doc, "button", { class: "sra-btn", onclick: () => call("openLog") }, "Open Log"), copy, copied), manual);
      const uninstall = el(doc, "div", { class: "sra-actions" });
      const ask = () => uninstall.replaceChildren(
        el(doc, "span", { class: "sra-muted" }, "This turns off Steam's debug switch and deletes your saved sign-in and cached data. On a Mac it also moves the app to the Trash; elsewhere, delete the program's folder afterwards. Games it added stay in your library. Restart Steam when it's done."),
        el(doc, "button", { class: "sra-btn sra-danger", onclick: async () => { await call("uninstall"); window.__sra.dispose(); } }, "Uninstall"),
        el(doc, "button", { class: "sra-link", onclick: () => reset() }, "Cancel"));
      const reset = () => uninstall.replaceChildren(el(doc, "button", { class: "sra-btn", onclick: ask }, "Uninstall…"));
      reset();
      kids.push(head(doc, "Uninstall"), uninstall);
      body.replaceChildren(...kids);
    });
    draw();
  });

  const openAddGames = safe(async () => {
    const doc = desktopDoc();
    if (!doc) { pendingOpen = openAddGames; return; }
    ensureStyle(doc);
    const consoles = await call("consoles");
    const st = { items: [], included: new Set(), consoleOverrides: {}, emulatorOverrides: {}, busy: false, added: [] };
    const folder = el(doc, "input", { class: "sra-input", placeholder: "Add a folder: type a path", spellcheck: "false", onkeydown: (e) => { if (e.key === "Enter") addFolder(folder.value); } });
    const folderList = el(doc, "div", { class: "sra-folders" });
    const list = el(doc, "div", { class: "sra-dialog-body" });
    const footer = el(doc, "div", { class: "sra-footer" });
    const chosen = () => st.items.filter((i) => i.status === "ready" && st.included.has(i.id));
    const drawFooter = (message = "") => footer.replaceChildren(el(doc, "div", { class: "sra-muted" }, message),
      el(doc, "button", { class: "sra-btn", disabled: st.busy || !chosen().length ? "" : undefined, onclick: () => add() }, `Add ${chosen().length} Games to Steam`));
    const select = (options, value, onchange) => {
      const s = el(doc, "select", { class: "sra-input", onchange: (e) => onchange(e.target.value) }, options.map(([v, label]) => el(doc, "option", { value: v }, label)));
      s.value = value;
      return s;
    };
    const drawList = () => list.replaceChildren(...st.items.map((it) => {
      const box = el(doc, "input", { type: "checkbox", onchange: () => { box.checked ? st.included.add(it.id) : st.included.delete(it.id); drawFooter(); } });
      box.checked = st.included.has(it.id);
      box.disabled = it.status !== "ready";
      const consoleCell = it.status === "chooseConsole"
        ? select([["", "Choose console…"], ...consoles.map((c) => [String(c.id), c.name])], "", (v) => { st.consoleOverrides[it.folder] = Number(v); scan(); })
        : el(doc, "div", { class: "sra-row-side" }, it.consoleName ?? "");
      // Stays up when the picked emulator can't run the game (RetroArch without the core), so the other one is still a click away.
      const emulatorCell = it.emulatorChoices.length > 1
        ? select(it.emulatorChoices.map((c) => [c.id, c.name]), it.emulator ?? st.emulatorOverrides[String(it.consoleId)], (v) => { st.emulatorOverrides[String(it.consoleId)] = v; scan(); })
        : el(doc, "div", { class: "sra-row-side" }, it.emulatorChoices.find((c) => c.id === it.emulator)?.name ?? "");
      return el(doc, "div", { class: "sra-row" }, box,
        el(doc, "div", { class: "sra-row-main" }, el(doc, "div", { class: "sra-row-title" }, it.title), el(doc, "div", { class: "sra-muted" }, it.statusText)),
        consoleCell, emulatorCell);
    }));
    const drawFolders = (folders) => folderList.replaceChildren(...folders.map((f) => el(doc, "div", { class: "sra-row" },
      el(doc, "div", { class: "sra-row-main" }, f.path), f.missing ? el(doc, "div", { class: "sra-muted" }, "Not found") : "",
      el(doc, "button", { class: "sra-link", onclick: () => removeFolder(f.path) }, "Remove"))));
    const addFolder = safe(async (path) => {
      path = path?.trim();
      if (!path) return;
      const r = await call("addRomFolder", { path });
      if (!r.error) folder.value = "";
      await scan(r.error ?? "");
    });
    const removeFolder = safe(async (path) => { await call("removeRomFolder", { path }); await scan(); });
    const browse = safe(async () => { const r = await call("chooseFolder", {}, 600000); if (r.path) await addFolder(r.path); });
    // Hashing ROMs to tell consoles apart can take a while in a big folder.
    const scan = safe(async (message = "") => {
      st.busy = true;
      drawFooter("Scanning…");
      try {
        const r = await call("scanGames", { shortcuts: [...await listShortcuts(), ...st.added],
          consoleOverrides: st.consoleOverrides, emulatorOverrides: st.emulatorOverrides }, 180000);
        drawFolders(r.folders);
        st.items = r.items;
        st.included = new Set(r.items.filter((i) => i.status === "ready").map((i) => i.id));
        drawList();
        if (!message && !r.items.length) message = "No games found in these folders.";
      } finally {
        st.busy = false;
        drawFooter(message);
      }
    });
    const add = safe(async () => {
      const items = chosen();
      st.busy = true;
      drawFooter("Adding…");
      const results = await addShortcuts(items.map((i) => i.shortcut));
      // Steam's details for a new shortcut lag behind the add: without this the scan below offers the same games again.
      st.added.push(...items.filter((_, n) => !results[n].error).map((i) => i.shortcut));
      const errors = results.filter((r) => r.error).map((r) => `${r.name}: ${r.error}`);
      await scan([`Added ${results.length - errors.length} games to Steam.`, ...errors].join("\n"));
      addArtwork(results.filter((r) => !r.error));  // not awaited: art never holds up the add
    });
    overlay(doc, "Add Games", folderList,
      el(doc, "div", { class: "sra-search" }, folder, el(doc, "button", { class: "sra-btn", onclick: () => addFolder(folder.value) }, "Add"),
        el(doc, "button", { class: "sra-btn", onclick: () => browse() }, "Browse…")), list, footer);
    scan();
  });

  // ---------------------------------------------------------------- playtime (docs/steam-internals.md Q15)
  // RA's playtime and last-played time go where Steam keeps its own games': the overview (library sorts, Recent Games)
  // and the details (the play bar's Last Played and Play Time), so Steam draws and sorts them itself.
  // Kept across Steam restarts, so a game shows its playtime straight away rather than Steam's own until the first sync answers.
  const PLAYTIMES_KEY = "sra-playtimes";
  const playtimes = new Map((() => { try { return JSON.parse(localStorage.getItem(PLAYTIMES_KEY)) ?? []; } catch (_) { return []; } })());  // appid → playtimes row
  const applyOverview = (ov) => {
    const t = playtimes.get(ov?.appid);
    if (!t) return;
    const last = Math.max(t.lastPlayed, ov.rt_last_time_played || 0);  // a launch through Steam can be newer than RA's last play
    if (ov.minutes_playtime_forever !== t.minutes) ov.minutes_playtime_forever = t.minutes;
    if (ov.minutes_playtime_last_two_weeks !== t.twoWeeks) ov.minutes_playtime_last_two_weeks = t.twoWeeks;  // Recent Games' "Last two weeks"
    if (ov.rt_last_time_played !== last) ov.rt_last_time_played = last;
    if ((ov.rt_recent_activity_time || 0) < last) ov.rt_recent_activity_time = last;
  };
  const applyDetails = (appid) => {
    const t = playtimes.get(appid), a = steamAchievements.get(appid), data = appDetailsStore.m_mapAppData.get(appid), d = data?.details;
    if (!d || (!t && !a)) return;
    const minutes = t?.minutes ?? d.nPlaytimeForever, last = t ? Math.max(t.lastPlayed, d.rtLastTimePlayed || 0) : d.rtLastTimePlayed;
    // A new object: the play bar redraws when the details are replaced, not when a field changes.
    if (d.nPlaytimeForever !== minutes || d.rtLastTimePlayed !== last || (a && d.achievements !== a)) {
      data.details = { ...d, nPlaytimeForever: minutes, rtLastTimePlayed: last, achievements: a ?? d.achievements };
    }
  };
  // RA's counts go into Steam's own per-game cache, which the library's Achievements sort and tiles read (docs/steam-internals.md Q18).
  const progress = new Map();  // appid → { unlocked, total } (the main set)
  const progressCache = () => window.appAchievementProgressCache?.m_achievementProgress?.mapCache;  // absent until Steam's first reply: the next tick fills it
  const applyProgress = (appid) => {
    const r = progress.get(appid), cache = progressCache(), e = cache?.get(appid), last = appStore.GetAppOverviewByAppID(appid)?.rt_last_time_played ?? 0;
    // Steam asks its servers again (they answer 0 for a shortcut) once the last play is newer than cache_time: a tick puts this back.
    if (!r || !cache || (e?.unlocked === r.unlocked && e?.total === r.total && e.groups_total_base === 1 && e.cache_time >= last)) return;
    // groups_*: the game's own set is Steam's "base game" set; completing it puts Steam's trophy on the tile (Q20).
    const all = r.total > 0 && r.unlocked === r.total;
    cache.set(appid, { appid, unlocked: r.unlocked, total: r.total, percentage: r.total ? r.unlocked * 100 / r.total : 0,
      all_unlocked: all, cache_time: Math.max(last, Math.floor(Date.now() / 1000)), vetted: true,
      groups_completed_base: all ? 1 : 0, groups_total_base: 1, groups_completed_dlc: 0, groups_total_dlc: 0, base_game_total: r.total });
  };
  const setProgress = (appid, r) => { progress.set(appid, { unlocked: r.unlocked, total: r.total }); applyProgress(appid); };
  // Steam answers for the shortcut itself again.
  const forgetProgress = (appid) => { progress.delete(appid); progressCache()?.delete(appid); };
  // A matched game's achievements go into Steam's own stores too, so Steam draws them like a Steam game's: its achievements
  // page, the overlay's Achievements button and window, the play bar's count (docs/steam-internals.md Q16, Q20).
  const steamAchievements = new Map();  // appid → details.achievements (the main set): what the overlay and Game Mode menus check
  const describe = (r) => `${r.missable ? "Missable: " : ""}${r.description} (${r.points} ${r.points === 1 ? "point" : "points"})`;
  const toRows = (sp) => sp?.state !== "matched" ? [] : sp.achievements.map((r) => ({ strID: String(r.id), strName: r.title, strDescription: describe(r),
    bAchieved: r.unlocked, rtUnlocked: r.unlockedAt ?? 0, strImage: r.badgeURL + (r.unlocked && r.hardcore ? "#hardcore" : ""), bHidden: false,
    flMinProgress: 0, flCurrentProgress: 0, flMaxProgress: 0, flAchieved: r.rarity ?? 0 }));
  // Steam's achievements views read three cached queries per game. A shortcut's hold Steam's empty answers: ours replace them,
  // with the subsets as achievement sets. The URL fragment marks hardcore unlocks for CSS_TEXT's gold frame; Steam has no field for it.
  const seeded = new Map();  // appid → { payload, entries: [[queryKey, data]] }
  const seedOf = (appid, p, steamid) => {
    const sets = setsOf(p), rows = sets.flatMap((sp) => sp.achievements), key = ["achievements", appid];
    const icon = (r, locked) => r.badgeURL.replace(/(_lock)?\.png$/, locked ? "_lock.png" : ".png") + (!locked && r.unlocked && r.hardcore ? "#hardcore" : "");
    return [
      [[...key, "schema"], { appid, language: "english", schema_hash: 1, schema_version: 1, groups: sets.map((sp, g) => ({
        id: g, name: g ? `${subsetName(sp)} subset` : "", archived: false, ispublic: true, developeronly: false, dlcappid: 0, order: g,
        achievements: sp.achievements.map((r) => ({ internal_key: r.id, api_name: String(r.id), name: r.title, description: describe(r), hidden: false, archived: false,
          icon_achieved: icon(r, false), icon_unachieved: icon(r, true), groupid: g, min_progress: 0, max_progress: 0 })) })) }],
      [[...key, "globalpercentages"], { percentages: Object.fromEntries(rows.map((r) => [r.id, r.rarity ?? 0])) }],
      [[...key, "user_achievements", steamid], { appid, steamid, schema_hash: 1,
        achievements: Object.fromEntries(rows.map((r) => [r.id, { internal_key: r.id, unlocked: r.unlocked, unlock_time: r.unlockedAt ?? 0, progress: 0 }])),
        // is_achievable: whether the set counts. Steam shows one that doesn't as a bare heading, without its locked achievements.
        groups: Object.fromEntries(sets.map((sp, g) => {
          const done = earnedIn(sp), complete = done > 0 && done === sp.achievements.length;
          return [g, { groupid: g, is_achievable: g === 0 || done > 0, completed_achievements: done, is_completed: complete,
            time_completed: complete ? Math.max(...sp.achievements.map((r) => r.unlockedAt ?? 0)) : 0 }];
        })) }],
    ];
  };
  // Each tick: Steam drops an unwatched entry after 5 minutes and restores its own answer at startup, so ours go back in.
  const applySeed = (appid) => {
    const qc = steamUI.queryClient();
    for (const [queryKey, data] of qc ? seeded.get(appid)?.entries ?? [] : []) {
      const q = qc.getQueryCache().build(qc, qc.defaultQueryOptions({ queryKey, gcTime: Infinity }));
      if (q.state.data === data) continue;
      q.cancel({ silent: true });  // Steam's own request, which would land on top of ours
      // setState, not setQueryData: Steam saves "success" updates to its disk cache, and ours don't belong there.
      // Dated far ahead, so Steam never finds it stale and asks its servers again; a new date makes its summaries recompute.
      q.setState({ data, status: "success", fetchStatus: "idle", error: null, dataUpdatedAt: Date.now() + 1e12 });
    }
  };
  // Steam answers for the shortcut itself again.
  const unseed = (appid) => { if (seeded.delete(appid)) steamUI.queryClient()?.removeQueries({ queryKey: ["achievements", appid] }); };
  // Steam hides the overlay toolbar's Achievements button for every shortcut; one with RA achievements gets it back.
  // The button's rule sits in a lookup Steam exports only as a function, found by its source.
  let toolbarButton = null;  // { def, visible }: Steam's rule, put back on dispose
  const hookToolbarButton = () => {
    if (toolbarButton) return;
    toolbarButton = {};
    const lookup = /^function \w+\(\w+\)\{const \w+=\w+\[\w+\];return typeof \w+=="function"\?\w+\(\):\w+\}$/;
    let def = null;
    steamUI.findExport((v) => {
      if (typeof v !== "function" || v.length !== 1 || !lookup.test(String(v))) return false;
      try { const d = v("Achievements"); if (d?.tooltipToken === "#AppOverlay_Toolbar_Achievements" && typeof d.buttonVisible === "function") def = d; } catch (_) {}
      return !!def;
    });
    if (!def) return log("error", "Steam's overlay Achievements button not found");
    const visible = def.buttonVisible.sraOriginal ?? def.buttonVisible;
    def.buttonVisible = (app, ...rest) => visible(app, ...rest) || steamAchievements.get(app?.appid)?.nTotal > 0;
    def.buttonVisible.sraOriginal = visible;
    toolbarButton = { def, visible };
  };
  const feedSteam = (appid, p) => {
    const store = steamUI.achievementStore();
    if (!store || p?.state === "error") return;  // a failed fetch keeps what Steam already shows
    const steamid = window.App?.m_CurrentUser?.strSteamID, main = steamid ? toRows(p) : [];  // the queries are kept per Steam account
    if ((!main.length && !steamAchievements.has(appid)) || seeded.get(appid)?.payload === p) return;
    const achieved = main.filter((r) => r.bAchieved), unachieved = main.filter((r) => !r.bAchieved);
    const byID = (list) => Object.fromEntries(list.map((r) => [r.strID, r]));
    if (main.length) {
      hookToolbarButton();
      seeded.set(appid, { payload: p, entries: seedOf(appid, p, steamid) });
      applySeed(appid);
      // The old store: the overlay's Game Overview still lists recent unlocks from it.
      store.m_mapMyAchievements.set(appid, { data: { achieved: byID(achieved), unachieved: byID(unachieved), hidden: {} } });
      store.m_mapGlobalAchievements.set(appid, { data: Object.fromEntries(main.map((r) => [r.strID, r.flAchieved])) });
    } else {
      unseed(appid);
      store.m_mapMyAchievements.delete(appid);
      store.m_mapGlobalAchievements.delete(appid);
    }
    steamAchievements.set(appid, { nTotal: main.length, nAchieved: achieved.length, vecHighlight: achieved, vecUnachieved: unachieved, vecAchievedHidden: [] });
    applyDetails(appid);
    setProgress(appid, { unlocked: achieved.length, total: main.length });
  };
  const loadForOverlay = safe(async (appid, method) => {
    const shortcut = await steamUI.shortcut(appid);
    if (shortcut.exe) feedSteam(appid, await call(method, { shortcut }, 180000));
  });
  const overlays = new WeakMap();  // Steam's overlay window → whether it was open at the last tick
  let lastInGame = null;  // the Game Mode in-game Achievements route at the last tick
  const overlayDocs = () => [...g_PopupManager.m_mapPopups.values()].map((p) => p.m_popup?.document)
    .concat((SteamUIStore.WindowStore?.OverlayWindows ?? []).map((w) => w.BrowserWindow?.document)).filter((d) => d?.head);
  // Steam rebuilds an overview from each update it gets: put the values back right after. The prototype is found through
  // an app Steam has loaded, and at login the script often arrives before Steam has any: each tick looks again until then.
  let overviewProto = null, initFromProto = null;
  const hookOverviews = () => {
    if (overviewProto) return;
    let o = Object.getPrototypeOf(appStore.m_mapApps.values().next().value ?? {});
    while (o && !Object.prototype.hasOwnProperty.call(o, "InitFromProto")) o = Object.getPrototypeOf(o);
    if (!o) return;
    overviewProto = o;
    initFromProto = o.InitFromProto.sraOriginal ?? o.InitFromProto;
    o.InitFromProto = function (...args) {
      const r = initFromProto.apply(this, args);
      try { applyOverview(this); } catch (_) {}
      return r;
    };
    o.InitFromProto.sraOriginal = initFromProto;
  };
  hookOverviews();
  // All shortcuts, or one (after it was played). Shortcuts the app no longer has playtime for go back to none.
  // A failed sync (RA or the app not answering) changes nothing and tries again in a minute; so do the games RA failed to answer for.
  let playtimeRetry = null;
  const retryPlaytimes = () => { clearTimeout(playtimeRetry); playtimeRetry = setTimeout(() => syncPlaytimes(), 60000); };
  const syncPlaytimes = safe(async (only) => {
    let rows;
    try { rows = (await call("playtimes", { shortcuts: only ? [only] : await listShortcuts() }, 600000)) ?? []; } catch (e) { retryPlaytimes(); throw e; }
    if (!only) for (const id of playtimes.keys()) if (!rows.some((r) => r.appid === id)) rows.push({ appid: id, minutes: 0, lastPlayed: 0, twoWeeks: 0 });
    if (rows.some((r) => r.failed)) retryPlaytimes();
    for (const r of rows) if (!r.failed) applyPlaytime(r);
    for (const r of rows) if (r.total === undefined) playtimes.delete(r.appid);  // put back to none once; Steam's own answer from then on
    try { localStorage.setItem(PLAYTIMES_KEY, JSON.stringify([...playtimes])); } catch (_) {}
  });
  const applyPlaytime = (r) => {
    playtimes.set(r.appid, r);
    applyOverview(appStore.GetAppOverviewByAppID(r.appid));
    applyDetails(r.appid);
    r.total === undefined ? forgetProgress(r.appid) : setProgress(r.appid, r);
  };
  // shortcut: a game played on another device shows up at the next hourly sync
  const playtimeInterval = setInterval(() => syncPlaytimes(), 3600000);
  let playtimesSynced = false;

  // ---------------------------------------------------------------- All Games in Big Picture (docs/steam-internals.md Q19)
  // Big Picture leaves every shortcut out of All Games. X on its Non-Steam tab opens a menu that puts the matched ones back.
  const ALL_GAMES_KEY = "sra-show-in-all-games";
  let showInAllGames = localStorage.getItem(ALL_GAMES_KEY) === "1";
  let allGames = null;  // the hook: what to put back on dispose, and `extra`, an observable list so Steam redraws All Games when it changes
  const syncAllGames = () => {
    if (!allGames && !hookAllGames()) return;
    const want = showInAllGames ? [...progress].filter(([, r]) => r.total > 0).map(([id]) => id) : [];
    if (want.join() !== allGames.extra.get().join()) allGames.extra.set(want);
  };
  const hookAllGames = () => {
    const admin = Object.getOwnPropertySymbols(collectionStore).find((s) => s.description === "mobx administration");
    const computed = collectionStore[admin]?.values_?.get("allGamesCollection"), observable = steamUI.observable();
    let proto = Object.getPrototypeOf(appStore.m_mapApps.values().next().value ?? {});
    while (proto && !Object.prototype.hasOwnProperty.call(proto, "BIsShortcut")) proto = Object.getPrototypeOf(proto);
    if (!computed?.derivation || !observable || !proto) return false;
    const derivation = computed.derivation.sraOriginal ?? computed.derivation, isShortcut = proto.BIsShortcut.sraOriginal ?? proto.BIsShortcut;
    const extra = observable.box([], { deep: false });
    // Steam builds All Games by dropping whatever BIsShortcut() says; only during that build, the listed games aren't shortcuts.
    // Nothing may be written to Steam's stores in here: this runs inside a MobX computed.
    let letThrough = null;
    proto.BIsShortcut = function () { return letThrough?.includes(this.appid) ? false : isShortcut.call(this); };
    proto.BIsShortcut.sraOriginal = isShortcut;
    computed.derivation = function () {
      letThrough = extra.get();
      try { return derivation.call(this); } finally { letThrough = null; }
    };
    computed.derivation.sraOriginal = derivation;
    allGames = { computed, derivation, proto, isShortcut, extra };
    computed.trackAndCompute();  // Steam built the list before this hook: this run makes it depend on `extra`
    return true;
  };
  const openNonSteamMenu = (doc, host) => {
    closeOverlay?.();
    ensureStyle(doc);
    const M = steamUI.classes("BasicContextMenuModal", "BasicContextMenuContainer", "contextMenuItem"), nav = [];
    const label = () => `Show in All Games: ${showInAllGames ? "On" : "Off"}`;
    const item = el(doc, "div", { class: `${c(M, "contextMenuItem", "Focused")} contextMenuItem Panel sra-item`, role: "menuitemcheckbox", "aria-checked": String(showInAllGames), tabindex: "0",
      onclick: () => {
        showInAllGames = !showInAllGames;
        localStorage.setItem(ALL_GAMES_KEY, showInAllGames ? "1" : "0");
        item.textContent = label();
        item.setAttribute("aria-checked", String(showInAllGames));
        syncAllGames();
      } }, label());
    const node = el(doc, "div", { class: `BasicUIContextMenu ${c(M, "BasicContextMenuModal")} sra-menu`, onclick: (e) => { if (e.target === node) close(); } },
      el(doc, "div", { class: `${c(M, "BasicContextMenuContainer")} Panel` },
        el(doc, "div", { class: `${c(M, "contextMenuContents")} Panel sra-column`, role: "menu", "aria-label": "RetroAchievements" }, item)));
    const close = () => { nav.reverse().forEach((fn) => { try { fn(); } catch (_) {} }); node.remove(); closeOverlay = null; takeFocus(navNodeFor(doc, host)); };
    // Only A reaches the item; everything else stays in the menu, and B closes it.
    node.addEventListener("vgp_onbuttondown", safe((e) => { if (e.detail?.button === BTN.OK) return; handled(e); if (e.detail?.button === BTN.CANCEL) close(); }));
    host.append(node);
    closeOverlay = close;
    takeFocus(registerNav(doc, node, nav, { [BTN.OK]: "Toggle", [BTN.CANCEL]: "Close", [BTN.SECONDARY]: null })[0]);
  };
  let optionsDoc = null;
  const onLibraryPad = safe((e) => {
    if (e.detail?.button !== BTN.SECONDARY) return;
    const doc = e.currentTarget, host = steamUI.findClass(doc, "DesktopApps");
    if (host?.contains(e.target) && !e.target.closest(".sra-menu")) { handled(e); openNonSteamMenu(doc, host); }
  });
  const ensureNonSteamOptions = (doc) => {
    if (!allGames) return;
    if (optionsDoc !== doc) {
      optionsDoc?.removeEventListener("vgp_onbuttondown", onLibraryPad, true);
      doc.addEventListener("vgp_onbuttondown", onLibraryPad, true);  // capture: Steam's grid stops the event before it reaches the document
      optionsDoc = doc;
    }
    const host = steamUI.findClass(doc, "DesktopApps"), hostNode = host && navNodeFor(doc, host), map = hostNode?.m_Properties?.actionDescriptionMap;
    // Steam's footer reads this up the focus tree; a redraw of the tab clears it, so each tick checks.
    if (hostNode && !map?.[BTN.SECONDARY]) hostNode.SetProperties({ ...hostNode.m_Properties, actionDescriptionMap: { ...map, [BTN.SECONDARY]: "RetroAchievements" } });
  };

  // ---------------------------------------------------------------- navigation
  const load = safe(async (appid, method) => {
    const shortcut = await steamUI.shortcut(appid);
    if (current?.appid !== appid) return;
    // Steam's details didn't arrive in time: try the page again on the next tick rather than calling it "not an emulator".
    if (!shortcut.exe) { lastAppid = null; return; }
    current.shortcut = shortcut;
    // The first match of a disc image can take a while (hashing, game lists): say so after 20 s, but keep waiting for the reply.
    const slow = setTimeout(safe(() => {
      if (current?.appid === appid && !current.payload) render({ state: "error", message: "Couldn't reach RetroAchievements.", achievements: [] });
    }), 20000);
    let payload;
    try {
      payload = await call(method, { shortcut }, 180000);
    } catch (e) {
      log("error", e?.message ?? e);
      return;
    } finally {
      clearTimeout(slow);
    }
    if (current?.appid === appid) render(payload);   // drop replies for a page we've left
  });

  let lastDoc = null, lastAppid = null;
  const tick = safe(() => {
    hookOverviews();
    if (!playtimesSynced && appStore.m_bIsInitialized) { playtimesSynced = true; playtimes.forEach(applyPlaytime); syncPlaytimes(); }
    if (current) applyDetails(current.appid);  // Steam replaces a page's details when it hears about the app again
    steamAchievements.forEach((_, id) => applyDetails(id));
    progress.forEach((_, id) => applyProgress(id));  // Steam's own reply can land after ours
    seeded.forEach((_, id) => applySeed(id));
    syncAllGames();
    // A shortcut's in-game overlay: its game's achievements when the game starts, fresh ones each time the overlay opens.
    const overlayWindows = SteamUIStore.WindowStore?.OverlayWindows ?? [];
    if (overlayWindows.length) overlayDocs().forEach(ensureStyle);  // the hardcore frame, in the overlay and the windows it opens
    for (const w of overlayWindows) {
      const appid = w.params?.appid, open = !!w.m_DesktopOverlay?.overlay_active, seen = overlays.has(w);
      if (!appid || (seen && overlays.get(w) === open) || !steamUI.isShortcut(appid)) continue;
      overlays.set(w, open);
      if (!seen || open) loadForOverlay(appid, seen ? "refreshPanel" : "getPanel");
    }
    // Game Mode (and Big Picture): the running game's Achievements page is in the main window, driven by the controller.
    // Fresh achievements each time it opens, like the desktop overlay.
    const gamepad = SteamUIStore.WindowStore?.GamepadUIMainWindowInstance;
    const inGame = /^\/app\/(\d+)\/overlay\/achievements/.exec(gamepad?.m_history?.location?.pathname ?? ""), inGameApp = Number(inGame?.[1]);
    if (inGame?.[0] !== lastInGame) {
      lastInGame = inGame?.[0];
      if (inGame && steamUI.isShortcut(inGameApp)) loadForOverlay(inGameApp, "refreshPanel");
    }
    const gamepadDoc = gamepad?.BrowserWindow?.document;
    if (inGame && gamepadDoc) ensureStyle(gamepadDoc);
    // The achievements page in Game Mode's in-game menu, or Big Picture's library: the leaderboards strip.
    const libraryAch = /^\/library\/app\/(\d+)\/achievements\//.exec(gamepad?.m_history?.location?.pathname ?? "");
    const stripApp = inGame ? inGameApp : Number(libraryAch?.[1]);
    if (stripApp && gamepadDoc && steamUI.isShortcut(stripApp)) ensureStrip(gamepadDoc, stripApp);
    else if (strip.node) removeStrip();
    const surface = steamUI.surface();
    if (!surface) return;
    const doc = surface.doc;
    surface.bpm ? ensureNonSteamOptions(doc) : ensureLibraryButtons(doc);
    const appid = steamUI.appid(surface);
    // A shortcut's overview can load after its page opens (Steam just started, or the game was just added).
    if (appid !== lastAppid || doc !== lastDoc || (!current && appid && steamUI.isShortcut(appid))) {
      lastDoc?.querySelectorAll?.("[data-sra-panel]").forEach((n) => n.remove());
      lastDoc = doc;
      lastAppid = appid;
      removePanel();
      closeOverlay?.();
      current = appid && steamUI.isShortcut(appid) ? { appid, bpm: surface.bpm, shortcut: null, payload: null } : null;
      if (current) load(appid, "getPanel");
    } else if (current?.payload && current.payload.state !== "hidden" && !/\/achievements\//.test(surface.route)
      && (current.nodes?.some((n) => !n.isConnected) || (current.bpm ? current.tab !== bpmTab(doc) : !current.nodes?.length))) {
      // Steam re-rendered the page and dropped our node, Big Picture switched tabs, or the reply came before the page had drawn.
      // Not on Steam's achievements page, which takes the game page's place in Big Picture.
      render(current.payload);
    }
    if (pendingOpen && !surface.bpm) { const open = pendingOpen; pendingOpen = null; open(); }
  });

  const ensureLibraryButtons = (doc) => {
    if (doc.querySelector("[data-sra-addgames]")) return;
    const steamButton = steamUI.addGameButton(doc);
    if (!steamButton) return;
    ensureStyle(doc);
    steamButton.after(
      el(doc, "button", { class: "sra-btn sra-addgames", "data-sra-addgames": "", onclick: () => openAddGames() }, "Add Games"),
      el(doc, "button", { class: "sra-btn sra-addgames", onclick: () => openSettings() }, "RetroAchievements"));
  };

  let lifetime = null;
  try {
    lifetime = SteamClient.GameSessions.RegisterForAppLifetimeNotifications(safe((e) => {
      if (e && e.bRunning === false && steamUI.isShortcut(e.unAppID)) {
        const appid = e.unAppID;
        setTimeout(safe(async () => {
          syncPlaytimes(await steamUI.shortcut(appid));
          lbFresh.add(appid);  // new scores too
          stripData.delete(appid);
          if (current?.appid === appid) { current.lb = null; load(appid, "refreshPanel"); }
        }), 10000);
      }
    }));
  } catch (e) { log("error", `lifetime notifications unavailable: ${e?.message ?? e}`); }

  // ---------------------------------------------------------------- unlock toasts
  // While a shortcut matched to an RA game runs, RA is asked for new unlocks every 3 s; each one gets Steam's own achievement toast.
  const sessions = new Map();  // running shortcut → { since, matched, busy, next }
  const toasted = new Set();   // "achievement:date", so each unlock pops once
  const toast = (appid, u) => {
    const [eType, target] = Object.entries(NotificationStore.GetNotificationTargets()).find(([, t]) => t.strTest === "Achievement") ?? [];
    if (!target) return log("error", "Steam's achievement toast not found");
    const data = target.proto.fromObject({ achievement_id: String(u.id), appid, name: u.title, description: u.description, image_url: u.image, achieved: true, rtime_unlocked: u.date });
    // Where Steam's client sends a native unlock (Q17): it shows in Game Mode, the game's overlay, or the desktop corner.
    NotificationStore.OnNotification(NotificationStore.m_nNextTestNotificationID++, Number(eType), data.serializeBinary());
  };
  const pollUnlocks = safe(async () => {
    const running = new Set((SteamUIStore.RunningApps ?? []).map((a) => a.appid).filter((id) => steamUI.isShortcut(id)));
    for (const id of sessions.keys()) if (!running.has(id)) sessions.delete(id);
    for (const appid of running) {
      let s = sessions.get(appid);
      if (!s) sessions.set(appid, s = { since: Date.now() / 1000, matched: null, busy: false, next: 0 });
      if (s.busy || s.matched === false || Date.now() < s.next) continue;
      s.busy = true;
      try {
        if (s.matched === null) {
          const shortcut = await steamUI.shortcut(appid);
          if (!shortcut.exe) continue;  // Steam's details didn't arrive in time: ask again next round
          const panel = await call("getPanel", { shortcut }, 180000);
          s.matched = panel?.state === "matched";
          if (!s.matched) continue;
          s.gameIds = lbGameIds(panel);
          s.icon = panel.game.iconURL;
        }
        for (const u of await call("unlocks", { since: s.since })) {
          const key = `${u.id}:${u.date}`;
          if (!toasted.has(key)) { toasted.add(key); toast(appid, u); }
        }
        // A score sent to a leaderboard since the game started: Steam's toast with the board, the score and the rank. RA is asked every 30 s.
        if (Date.now() >= (s.nextBest ?? 0)) {
          s.nextBest = Date.now() + 30000;
          for (const b of await call("leaderboardBests", { gameIds: s.gameIds, since: s.since })) {
            const key = `lb:${b.boardId}:${b.date}`;
            if (toasted.has(key)) continue;
            toasted.add(key);
            toast(appid, { id: `lb${b.boardId}`, title: `New best: ${b.title}`, description: [b.score, b.rank && `Rank #${num(b.rank)}`].filter(Boolean).join(" · "), image: s.icon, date: b.date });
            lbFresh.add(appid);
            stripData.delete(appid);
            if (strip.appid === appid) removeStrip();
            if (current?.appid === appid) { current.lb = null; if (current.payload) render(current.payload); }
          }
        }
      } catch (e) {
        s.next = Date.now() + 30000;  // RA unreachable or refusing: back off
        log("error", `unlocks: ${e?.message ?? e}`);
      } finally { s.busy = false; }
    }
  });
  const unlockInterval = setInterval(pollUnlocks, 3000);

  const interval = setInterval(tick, 500);

  window.__sra = {
    receive: safe((msg) => {
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      clearTimeout(p.timer);
      msg.error !== undefined ? p.reject(new Error(msg.error)) : p.resolve(msg.result);
    }),
    // A background refresh can arrive after "Wrong game?" picked a different game: only accept the game on screen.
    update: safe((msg) => {
      if (msg.appid !== current?.appid) return feedSteam(msg.appid, msg.payload);  // a game playing with its page closed
      if (current.payload?.game && msg.payload.game?.id !== current.payload.game.id) return;
      render(msg.payload);
    }),
    dispose: safe(() => {
      clearInterval(interval);
      clearInterval(playtimeInterval);
      clearTimeout(playtimeRetry);
      clearInterval(unlockInterval);
      if (initFromProto) overviewProto.InitFromProto = initFromProto;
      for (const id of steamAchievements.keys()) feedSteam(id, null);
      for (const id of progress.keys()) forgetProgress(id);
      if (toolbarButton?.def) toolbarButton.def.buttonVisible = toolbarButton.visible;
      optionsDoc?.removeEventListener("vgp_onbuttondown", onLibraryPad, true);
      if (allGames) { allGames.extra.set([]); allGames.computed.derivation = allGames.derivation; allGames.proto.BIsShortcut = allGames.isShortcut; }
      overlayDocs().forEach((d) => d.querySelectorAll("style[data-sra]").forEach((n) => n.remove()));
      try { lifetime?.unregister?.(); } catch (_) {}
      closeOverlay?.();
      removeStrip();
      removePanel();
      steamUI.doc()?.querySelectorAll("[data-sra]").forEach((n) => n.remove());
      for (const p of pending.values()) clearTimeout(p.timer);
      pending.clear();
    }),
    listShortcuts,
    addShortcuts,
    openSettings: () => { pendingOpen = openSettings; },
    openAddGames: () => { pendingOpen = openAddGames; },
  };
  log("info", "inject loaded");
})();
