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
  const log = (level, message) => { try { window.__sra_send(JSON.stringify({ id: 0, method: "log", params: { level, message: String(message) } })); } catch (_) {} };
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
      if (bpm) return { doc: bpm, bpm: true, route: SteamUIStore.GetFocusedWindowInstance?.()?.m_history?.location?.pathname ?? "" };
      const doc = g_PopupManager.GetExistingPopup("SP Desktop_uid0")?.m_popup?.document;
      return doc ? { doc, bpm: false, route: MainWindowBrowserManager?.m_lastLocation?.pathname ?? "" } : null;
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

  // ---------------------------------------------------------------- drawing helpers
  const CSS_TEXT = `
  .sra-panel { font-family: "Motiva Sans", Arial, Helvetica, sans-serif; color: #c6d4df; margin: 0 0 16px; padding: 12px 14px;
    background: rgba(0, 0, 0, 0.2); border-radius: 2px; font-size: 13px; line-height: 1.4; }
  .sra-head { font-size: 14px; color: rgb(148, 161, 166); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 10px; }
  .sra-game { display: flex; gap: 10px; align-items: center; margin-bottom: 10px; }
  .sra-game img { width: 40px; height: 40px; border-radius: 2px; }
  .sra-game-title { color: #fff; font-size: 15px; }
  .sra-muted { color: #8b929b; font-size: 12px; }
  .sra-link { color: #67c1f5; cursor: pointer; background: none; border: 0; padding: 0; font: inherit; font-size: 12px; }
  .sra-link:hover { color: #fff; }
  .sra-notice { background: rgba(255, 196, 0, 0.12); border-left: 3px solid #e5b50d; color: #e8d9a8; padding: 6px 8px; margin: 0 0 10px; font-size: 12px; }
  .sra-summary { color: #fff; }
  .sra-bar { height: 6px; background: rgba(255, 255, 255, 0.1); border-radius: 3px; margin: 6px 0; overflow: hidden; }
  .sra-bar > div { height: 100%; background: linear-gradient(90deg, #1a9fff, #67c1f5); }
  .sra-badges { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
  .sra-badge { width: 40px; height: 40px; border-radius: 2px; cursor: default; }
  .sra-badge.sra-hc { box-shadow: 0 0 0 2px #e5b50d; }
  .sra-more { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: rgba(255, 255, 255, 0.07); color: #8b929b; border-radius: 2px; }
  .sra-actions { display: flex; gap: 14px; margin: 8px 0; align-items: center; }
  .sra-btn { background: rgba(255, 255, 255, 0.1); color: #fff; border: 0; border-radius: 2px; padding: 6px 12px; font: inherit; cursor: pointer; }
  .sra-btn:hover { background: #1a9fff; }
  .sra-details { display: grid; grid-template-columns: auto 1fr; gap: 2px 12px; margin-top: 8px; font-size: 12px; }
  .sra-details dt { color: #8b929b; } .sra-details dd { margin: 0; color: #c6d4df; }
  .sra-card { position: fixed; z-index: 10000; max-width: 280px; background: #22252b; border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4); padding: 10px; border-radius: 3px; font-family: "Motiva Sans", Arial, sans-serif; color: #c6d4df; font-size: 12px; pointer-events: none; }
  .sra-card b { color: #fff; font-size: 13px; display: block; margin-bottom: 2px; }
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
  .sra-bpm { font-size: 17px; margin: 16px 2.8vw; } .sra-bpm .sra-row { background: rgba(255, 255, 255, 0.06); }
  .sra-bpm .sra-head { font-size: 17px; } .sra-bpm .sra-muted, .sra-bpm .sra-details { font-size: 15px; }
  .sra-bpm .sra-summary { font-size: 19px; } .sra-bpm .sra-game-title { font-size: 22px; } .sra-bpm .sra-notice { font-size: 15px; }
  .sra-btn:disabled, .sra-btn:disabled:hover { opacity: 0.5; cursor: default; background: rgba(255, 255, 255, 0.1); }
  .sra-btn.sra-danger:hover { background: #c4302b; }
  .sra-input { background: #0e141b; color: #fff; border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 2px; padding: 6px 8px; font: inherit; }
  .sra-form label { display: flex; flex-direction: column; gap: 4px; margin: 8px 0; }
  .sra-form .sra-head { margin: 18px 0 8px; }
  .sra-form label.sra-check { flex-direction: row; align-items: center; gap: 8px; }
  .sra-error { color: #ff7b7b; font-size: 12px; }
  .sra-footer { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 16px; border-top: 1px solid rgba(255, 255, 255, 0.08); }
  .sra-footer .sra-muted { white-space: pre-line; }
  .sra-row select { max-width: 170px; }
  .sra-btn.sra-addgames { margin-left: 8px; background: none; color: #8b929b; font-size: 12px; padding: 4px 6px; }
  .sra-btn.sra-addgames:hover { background: none; color: #fff; }
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

  // ---------------------------------------------------------------- panel
  let current = null;        // { appid, shortcut, payload }
  let hoverCard = null;

  const showCard = (doc, target, row) => {
    hideCard();
    const r = target.getBoundingClientRect();
    hoverCard = el(doc, "div", { class: "sra-card" },
      el(doc, "b", {}, row.title), row.description,
      el(doc, "div", { class: "sra-muted" }, `${row.points} points`),
      row.unlockedText && el(doc, "div", { class: "sra-muted" }, row.unlockedText),
      row.rarityText && el(doc, "div", { class: "sra-muted" }, row.rarityText));
    doc.body.append(hoverCard);
    hoverCard.style.left = `${Math.min(r.left, doc.defaultView.innerWidth - 300)}px`;
    hoverCard.style.top = `${r.bottom + 6}px`;
  };
  const hideCard = () => { hoverCard?.remove(); hoverCard = null; };

  const removePanel = () => {
    hideCard();
    steamUI.doc()?.querySelectorAll("[data-sra-panel]").forEach((n) => n.remove());
  };

  const render = (payload) => {
    const doc = steamUI.doc();
    if (!doc || !current) return;
    current.payload = payload;
    removePanel();
    if (payload.state === "hidden") return;
    const host = steamUI.panelHost(doc, current.bpm);
    if (!host) return;
    ensureStyle(doc);
    if (current.bpm) return host.prepend(bpmBlock(doc, payload));

    const p = payload, kids = [el(doc, "div", { class: "sra-head" }, "RetroAchievements")];
    if (p.state === "signedOut") {
      kids.push(el(doc, "div", {}, p.message), el(doc, "div", { class: "sra-actions" },
        el(doc, "button", { class: "sra-btn", onclick: () => openSettings() }, "Sign In")));
    } else if (p.state === "notMatched") {
      kids.push(el(doc, "div", {}, p.message), el(doc, "div", { class: "sra-actions" },
        el(doc, "button", { class: "sra-btn", onclick: () => openChooser(p.consoleId) }, "Choose game")));
    } else if (p.state === "error") {
      kids.push(el(doc, "div", { class: "sra-muted" }, p.message));
    } else {
      const g = p.game;
      kids.push(el(doc, "div", { class: "sra-game" },
        el(doc, "img", { src: g.iconURL, alt: "" }),
        el(doc, "div", {}, el(doc, "div", { class: "sra-game-title" }, g.title),
          el(doc, "button", { class: "sra-link", onclick: () => call("openURL", { url: g.raURL }) }, "View on RetroAchievements"))));
      if (p.notice) kids.push(el(doc, "div", { class: "sra-notice" }, p.notice));
      if (p.state === "noSet") {
        kids.push(el(doc, "div", { class: "sra-muted" }, p.message));
      } else {
        const s = p.summary, shown = p.achievements.slice(0, 10);
        kids.push(
          el(doc, "div", { class: "sra-summary" }, s.text),
          el(doc, "div", { class: "sra-bar" }, (() => { const f = el(doc, "div"); f.style.width = `${s.percent}%`; return f; })()),
          el(doc, "div", { class: "sra-muted" }, [s.pointsText, s.hardcoreText].filter(Boolean).join(" · ")),
          el(doc, "div", { class: "sra-badges" },
            shown.map((row) => el(doc, "img", { class: "sra-badge" + (row.hardcore ? " sra-hc" : ""), src: row.badgeURL, alt: row.title,
              onmouseenter: (e) => showCard(doc, e.currentTarget, row), onmouseleave: hideCard })),
            p.achievements.length > shown.length && el(doc, "div", { class: "sra-more" }, `+${p.achievements.length - shown.length}`)),
          el(doc, "div", { class: "sra-actions" },
            el(doc, "button", { class: "sra-btn", onclick: () => openAll(p) }, "View all achievements"),
            el(doc, "button", { class: "sra-link", onclick: () => openChooser(p.consoleId) }, "Wrong game?")));
      }
      if (g.details.length) kids.push(el(doc, "dl", { class: "sra-details" }, g.details.flatMap((d) => [el(doc, "dt", {}, d.label), el(doc, "dd", {}, d.value)])));
    }
    if (p.updatedText) kids.push(el(doc, "div", { class: "sra-muted" }, p.updatedText));
    const panel = el(doc, "div", { class: "sra-panel", "data-sra-panel": "" }, kids);
    host.prepend(panel);
  };

  // Big Picture: one scrollable block, no buttons or overlays (controller focus can't reach them reliably).
  const bpmBlock = (doc, p) => {
    const kids = [el(doc, "div", { class: "sra-head" }, "RetroAchievements")];
    if (p.game) kids.push(el(doc, "div", { class: "sra-game" }, el(doc, "img", { src: p.game.iconURL, alt: "" }), el(doc, "div", { class: "sra-game-title" }, p.game.title)));
    if (p.message) kids.push(el(doc, "div", { class: "sra-muted" }, p.state === "notMatched" ? `${p.message} Choose the game on the desktop library page.` : p.message));
    if (p.notice) kids.push(el(doc, "div", { class: "sra-notice" }, p.notice));
    if (p.summary) {
      const fill = el(doc, "div");
      fill.style.width = `${p.summary.percent}%`;
      kids.push(el(doc, "div", { class: "sra-summary" }, p.summary.text), el(doc, "div", { class: "sra-bar" }, fill),
        el(doc, "div", { class: "sra-muted" }, [p.summary.pointsText, p.summary.hardcoreText].filter(Boolean).join(" · ")));
    }
    if (p.game?.details.length) kids.push(el(doc, "dl", { class: "sra-details" }, p.game.details.flatMap((d) => [el(doc, "dt", {}, d.label), el(doc, "dd", {}, d.value)])));
    kids.push(...p.achievements.map((row) =>
      el(doc, "div", { class: "sra-row" + (row.unlocked ? "" : " sra-locked") + (row.hardcore ? " sra-hc" : "") },
        el(doc, "img", { src: row.badgeURL, alt: "" }),
        el(doc, "div", { class: "sra-row-main" }, el(doc, "div", { class: "sra-row-title" }, row.title), el(doc, "div", { class: "sra-muted" }, row.description)),
        el(doc, "div", { class: "sra-row-side" }, `${row.points} points`, row.unlockedText && el(doc, "div", {}, row.unlockedText)))));
    if (p.updatedText) kids.push(el(doc, "div", { class: "sra-muted" }, p.updatedText));
    return el(doc, "div", { class: "sra-panel sra-bpm", "data-sra-panel": "" }, kids);
  };

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

  const openAll = (p) => {
    const doc = steamUI.doc();
    if (!doc) return;
    overlay(doc, p.game.title, el(doc, "div", { class: "sra-dialog-body" }, p.achievements.map((row) =>
      el(doc, "div", { class: "sra-row" + (row.unlocked ? "" : " sra-locked") + (row.hardcore ? " sra-hc" : "") },
        el(doc, "img", { src: row.badgeURL, alt: "" }),
        el(doc, "div", { class: "sra-row-main" }, el(doc, "div", { class: "sra-row-title" }, row.title), el(doc, "div", { class: "sra-muted" }, row.description)),
        el(doc, "div", { class: "sra-row-side" }, `${row.points} points`, row.unlockedText && el(doc, "div", {}, row.unlockedText),
          row.rarityText && el(doc, "div", {}, row.rarityText))))));
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
        const payload = await call("chooseGame", { shortcut, gameId: g.gameId, consoleId: Number(select.value) });
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

  // ---------------------------------------------------------------- settings and add games (desktop library only)
  // Opened from outside (the Mac menu, first run) through pendingOpen, so tick() has settled the page and won't close them.
  let pendingOpen = null;
  const desktopDoc = () => { const s = steamUI.surface(); return s && !s.bpm ? s.doc : null; };
  const head = (doc, text) => el(doc, "div", { class: "sra-head" }, text);
  const signedInChanged = () => { if (current) { current.payload = null; load(current.appid, "getPanel"); } };

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
        el(doc, "button", { class: "sra-link", type: "button", onclick: () => call("openURL", { url: "https://retroachievements.org/settings" }) }, "Find your Web API key"),
        error, el(doc, "div", { class: "sra-actions" }, submit)));
        setTimeout(() => user.focus(), 0);
      }
      kids.push(head(doc, "Emulators"), el(doc, "dl", { class: "sra-details" },
        s.emulators.flatMap((e) => [el(doc, "dt", {}, e.name), el(doc, "dd", {}, e.installed ? "Installed" : "Not installed")])));
      const login = el(doc, "input", { type: "checkbox", onchange: async () => { login.checked = await call("setOpenAtLogin", { on: login.checked }); } });
      login.checked = s.openAtLogin;
      kids.push(head(doc, "General"), el(doc, "label", { class: "sra-check" }, login, "Open at login"));
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
    const st = { items: [], included: new Set(), consoleOverrides: {}, emulatorOverrides: {}, busy: false };
    const folder = el(doc, "input", { class: "sra-input", placeholder: "ROM folder", spellcheck: "false", onkeydown: (e) => { if (e.key === "Enter") scan(); } });
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
      const emulatorCell = it.emulator && it.emulatorChoices.length > 1
        ? select(it.emulatorChoices.map((c) => [c.id, c.name]), it.emulator, (v) => { st.emulatorOverrides[String(it.consoleId)] = v; scan(); })
        : el(doc, "div", { class: "sra-row-side" }, it.emulatorChoices.find((c) => c.id === it.emulator)?.name ?? "");
      return el(doc, "div", { class: "sra-row" }, box,
        el(doc, "div", { class: "sra-row-main" }, el(doc, "div", { class: "sra-row-title" }, it.title), el(doc, "div", { class: "sra-muted" }, it.statusText)),
        consoleCell, emulatorCell);
    }));
    // Hashing ROMs to tell consoles apart can take a while in a big folder.
    const scan = safe(async (message = "") => {
      st.busy = true;
      drawFooter("Scanning…");
      try {
        const r = await call("scanGames", { folder: folder.value.trim() || null, shortcuts: await listShortcuts(),
          consoleOverrides: st.consoleOverrides, emulatorOverrides: st.emulatorOverrides }, 180000);
        folder.value = r.folder;
        st.items = r.items;
        st.included = new Set(r.items.filter((i) => i.status === "ready").map((i) => i.id));
        drawList();
        if (!message && !r.items.length) message = "No games found in this folder.";
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
      const errors = results.filter((r) => r.error).map((r) => `${r.name}: ${r.error}`);
      await scan([`Added ${results.length - errors.length} games to Steam.`, ...errors].join("\n"));
    });
    overlay(doc, "Add Games", el(doc, "div", { class: "sra-search" }, folder, el(doc, "button", { class: "sra-btn", onclick: () => scan() }, "Scan")), list, footer);
    scan();
  });

  // ---------------------------------------------------------------- navigation
  const load = safe(async (appid, method) => {
    const shortcut = await steamUI.shortcut(appid);
    if (current?.appid !== appid) return;
    current.shortcut = shortcut;
    let payload;
    try {
      payload = await call(method, { shortcut });
    } catch (e) {
      log("error", e?.message ?? e);
      // No reply in time and nothing on screen yet: say so instead of showing nothing.
      if (current?.appid === appid && !current.payload) render({ state: "error", message: "Couldn't reach RetroAchievements.", achievements: [] });
      return;
    }
    if (current?.appid === appid) render(payload);   // drop replies for a page we've left
  });

  let lastDoc = null, lastAppid = null;
  const tick = safe(() => {
    const surface = steamUI.surface();
    if (!surface) return;
    const doc = surface.doc;
    if (!surface.bpm) ensureLibraryButtons(doc);
    const appid = steamUI.appid(surface);
    if (appid !== lastAppid || doc !== lastDoc) {
      lastDoc?.querySelectorAll?.("[data-sra-panel]").forEach((n) => n.remove());
      lastDoc = doc;
      lastAppid = appid;
      removePanel();
      closeOverlay?.();
      current = appid && steamUI.isShortcut(appid) ? { appid, bpm: surface.bpm, shortcut: null, payload: null } : null;
      if (current) load(appid, "getPanel");
    } else if (current?.payload && !doc.querySelector("[data-sra-panel]") && current.payload.state !== "hidden") {
      render(current.payload);   // Steam re-rendered the page and dropped our node
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
      if (e && e.bRunning === false && e.unAppID === current?.appid) {
        const appid = e.unAppID;
        setTimeout(safe(() => { if (current?.appid === appid) load(appid, "refreshPanel"); }), 10000);
      }
    }));
  } catch (e) { log("error", `lifetime notifications unavailable: ${e?.message ?? e}`); }

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
      if (msg.appid !== current?.appid) return;
      if (current.payload?.game && msg.payload.game?.id !== current.payload.game.id) return;
      render(msg.payload);
    }),
    dispose: safe(() => {
      clearInterval(interval);
      try { lifetime?.unregister?.(); } catch (_) {}
      closeOverlay?.();
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
