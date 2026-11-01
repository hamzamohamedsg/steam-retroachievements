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
      // The Big Picture window's own history; the focused one is null while another app has focus.
      const history = SteamUIStore.WindowStore?.GamepadUIMainWindowInstance?.m_history ?? SteamUIStore.GetFocusedWindowInstance?.()?.m_history;
      if (bpm) return { doc: bpm, bpm: true, route: history?.location?.pathname ?? "" };
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
  /* Steam-classed panel: only what Steam's classes leave to unlisted helpers (docs/steam-internals.md Q13). */
  :where(.sra-h2) { margin: 0; font: unset; }
  .sra-iconrow { width: 100%; height: 100%; display: flex; flex-direction: row; } .sra-iconrow > div { height: 100%; }
  .sra-li { margin-bottom: 8px; }
  .sra-info { display: flex; flex-direction: column; gap: 12px; padding: 16px; font-size: 13px; color: #c6d4df; }
  .sra-info dl { display: grid; grid-template-columns: max-content 1fr; gap: 6px 24px; margin: 0; }
  .sra-info dt { color: #8b929b; } .sra-info dd { margin: 0; color: #fff; }
  .sra-info .sra-notice { margin: 0; }
  .sra-info .sra-actions { margin: 0; }
  .sra-message { padding: 16px; display: flex; flex-direction: column; gap: 12px; align-items: flex-start; }
  .sra-close svg { width: 100%; height: 100%; }
  .sra-stat { cursor: pointer; }
  .sra-btn.sra-addgames { margin-left: 8px; background: none; color: #8b929b; font-size: 12px; padding: 4px 6px; }
  .sra-btn.sra-addgames:hover { background: none; color: #fff; }
  /* Steam's focus ring comes from its React Focusable, which our items don't have; this stands in for it. */
  .sra-carousel .sra-item { cursor: pointer; } .sra-item:focus { outline: 2px solid rgba(255, 255, 255, 0.6); outline-offset: -2px; }
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
  };
  const steamButton = "DialogButton _DialogLayout Secondary Focusable";

  const showCard = (doc, target, row) => {
    hideCard();
    const A = K.ach(), I = K.icon(), H = K.hover(), B = K.hoverBg();
    const points = `${row.points} points${row.hardcore ? " · hardcore" : ""}`;
    const pos = el(doc, "div", { class: c(H, "HoverPosition", "Ready") },
      el(doc, "div", {}, el(doc, "div", { class: c(B, "AppDetailsHover") + " " + c(A, "Hover") + (row.unlocked ? " " + c(A, "Achieved") : "") },
        el(doc, "div", { class: c(B, "Background") }, el(doc, "div", { class: c(B, "BlurContainer") }, el(doc, "img", { src: row.badgeURL, alt: "" }))),
        el(doc, "div", { class: c(A, "TopSection") },
          el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "TopSectionAchievementIcon", "Icon") }, el(doc, "img", { class: c(I, "Icon"), src: row.badgeURL, alt: "" })),
          el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, row.title), el(doc, "div", { class: c(A, "Desc") }, row.description))),
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
  const BTN = { OK: 1, CANCEL: 2, BUMPER_LEFT: 5, BUMPER_RIGHT: 6, DIR_UP: 9, DIR_DOWN: 10, DIR_LEFT: 11, DIR_RIGHT: 12 };  // Steam's gamepad buttons
  const handled = (e) => { e.stopPropagation(); e.preventDefault(); };  // how Steam's own handlers claim a button
  // Each .sra-carousel is a row (left/right) and each .sra-column a column (up/down) of .sra-item; returns the items' nodes in order.
  const registerNav = (doc, root, cleanups = navCleanups, actions = { [BTN.OK]: "View My Achievements" }) => {
    try {
      const context = FocusNavController.m_rgAllContexts.find((x) => x.m_rootWindow === doc.defaultView);
      const deepest = (node) => node.m_rgChildren.reduce((best, ch) => deepest(ch) ?? best, node.m_element?.contains(root) ? node : null);
      let parent = null;
      for (const tree of context?.m_rgGamepadNavigationTrees ?? []) parent = deepest(tree.m_Root) ?? parent;
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
          return (item.sraNode = add(groupNode, item, { focusable: true, actionDescriptionMap: actions }));
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

  const iconOf = (doc, row) => el(doc, "div", { class: c(K.ach(), "AchievementHoverContainer") + " Panel",
      onmouseenter: (e) => showCard(doc, e.currentTarget, row), onmouseleave: hideCard },
    el(doc, "div", { class: c(K.icon(), "AchievementIconWrapper") + " " + c(K.ach(), "Icon") }, el(doc, "img", { class: c(K.icon(), "Icon"), src: row.badgeURL, alt: "" })));

  // One clickable icon per subset (RetroAchievements lists each as its own game); it opens that subset's achievements page.
  const subsetName = (sp) => /\[Subset - ([^\]]+)\]/.exec(sp.game?.title ?? "")?.[1] ?? sp.game?.title ?? "Subset";
  const subsetRow = (doc, p, divider) => {
    const A = K.ach(), I = K.icon();
    const items = p.subsets.map((sp) => {
      const name = subsetName(sp);
      const earned = sp.achievements.filter((r) => r.unlocked).length;
      return el(doc, "div", {}, el(doc, "div", { class: c(A, "AdditionalItem", "Achieved") + " Panel sra-subset", title: `${name}: ${earned} of ${sp.achievements.length}`, onclick: () => openAll(sp) },
        el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "Icon") }, el(doc, "img", { class: c(I, "Icon"), src: sp.game.iconURL, alt: "" }))));
    });
    return el(doc, "div", { class: c(A, "UnachievedSection") + (divider ? " " + c(A, "ShowDivider") : "") },
      el(doc, "div", { class: c(A, "Label") }, "Subsets"), el(doc, "div", { class: c(A, "Additional") }, el(doc, "div", { class: "sra-iconrow" }, items)));
  };

  // "Locked Achievements"-style row: as many icons as fit, the rest as "+N" (filled in once it's on screen and has a width).
  const iconRow = (doc, label, rows, achieved, divider, p) => {
    const A = K.ach(), wrap = el(doc, "div", { class: "sra-iconrow" });
    const item = (row) => el(doc, "div", {}, el(doc, "div", { class: c(A, "AdditionalItem", achieved ? "Achieved" : "NotAchieved") + " Panel" }, iconOf(doc, row)));
    const remainder = (n) => el(doc, "div", {}, el(doc, "div", { class: c(A, "AdditionalItem", "RemainderContainer") + " Panel", onclick: () => openAll(p) },
      el(doc, "div", { class: c(A, "Remainder") }, el(doc, "div", { class: c(A, "RemainderText") }, "+", String(n)))));
    const node = el(doc, "div", { class: c(A, "UnachievedSection") + (divider ? " " + c(A, "ShowDivider") : "") },
      el(doc, "div", { class: c(A, "Label") }, label), el(doc, "div", { class: c(A, "Additional") }, wrap));
    node.sraFit = () => {
      wrap.replaceChildren(...rows.map(item));
      const kids = [...wrap.children], step = kids.length > 1 ? kids[1].offsetLeft - kids[0].offsetLeft : kids[0]?.offsetWidth;
      const fit = step ? Math.max(1, Math.floor(wrap.clientWidth / step)) : rows.length;
      if (rows.length > fit) wrap.replaceChildren(...rows.slice(0, fit - 1).map(item), remainder(rows.length - fit + 1));
    };
    return node;
  };

  // "You've unlocked 3/35 (8%)" over a progress bar.
  const progressHighlight = (doc, p) => {
    const A = K.ach(), D = K.details(), s = p.summary;
    const fill = el(doc, "div", { class: c(A, "AchievementProgress") });
    fill.style.width = `${s?.percent ?? 0}%`;
    return el(doc, "div", { class: c(D, "Highlight") + " " + c(A, "HighlightDiv") },
      el(doc, "div", { class: c(A, "UnlockedLabel") }, s ? [el(doc, "span", {}, s.text.replace(/\s*\(\d+%\)$/, "")), " ",
        el(doc, "span", { class: c(A, "UnlockedLabelPercent") }, `(${s.percent}%)`)] : el(doc, "span", {}, p.message)),
      s && el(doc, "div", { class: c(A, "AchievementProgressContainer") }, fill),
      el(doc, "div", { class: c(A, "GlobalStatLabel") }));
  };

  const achievementsSection = (doc, p) => {
    const A = K.ach(), D = K.details(), s = p.summary;
    const unlocked = p.achievements.filter((r) => r.unlocked), locked = p.achievements.filter((r) => !r.unlocked);
    const highlight = progressHighlight(doc, p);
    const rows = [];
    if (unlocked.length) {
      const r = unlocked[0];  // most recent first (PanelBuilder sorts)
      rows.push(el(doc, "div", { class: c(A, "RightAchievementSection", "Achieved", "Featured") + " Panel" }, iconOf(doc, r),
        el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, r.title), el(doc, "div", { class: c(A, "Desc") }, r.description))));
    }
    if (unlocked.length > 1) rows.push(iconRow(doc, "Unlocked Achievements", unlocked.slice(1), true, true, p));
    if (locked.length) rows.push(iconRow(doc, "Locked Achievements", locked, false, unlocked.length > 0, p));
    if (p.subsets?.length) rows.push(subsetRow(doc, p, unlocked.length > 0 || locked.length > 0));
    const body = s && el(doc, "div", { class: c(D, "Body") }, rows,
      el(doc, "button", { class: c(K.button(), "AppDetailsButton", "BottomRight") + " " + steamButton, onclick: () => openAll(p) }, "View My Achievements"));
    return section(doc, "RetroAchievements", ["AppDetailsSectionHasLabel", "RightColumnSection"], highlight, body);
  };


  // Replaces Steam's "detailed information is unavailable" box on the left.
  const detailsSection = (doc, p) => {
    const g = p.game;
    return section(doc, "Details", ["AppDetailsSectionHasLabel", ...(current?.bpm ? ["RightColumnSection"] : [])], el(doc, "div", { class: c(K.details(), "Body") + " sra-info" },
      p.notice && el(doc, "div", { class: "sra-notice" }, p.notice),
      el(doc, "dl", {}, el(doc, "dt", {}, "Game"), el(doc, "dd", {}, g.title), g.details.flatMap((d) => [el(doc, "dt", {}, d.label), el(doc, "dd", {}, d.value)]),
        p.summary && [el(doc, "dt", {}, "Points"), el(doc, "dd", {}, [p.summary.pointsText, p.summary.hardcoreText].filter(Boolean).join(" · "))]),
      !current?.bpm && el(doc, "div", { class: "sra-actions" },
        el(doc, "button", { class: "sra-link", onclick: () => call("openURL", { url: g.raURL }) }, "View on RetroAchievements"),
        el(doc, "button", { class: "sra-link", onclick: () => openChooser(p.consoleId) }, "Wrong game?")),
      p.updatedText && el(doc, "div", { class: "sra-muted" }, p.updatedText)));
  };

  // The "Achievements 3/35" stat in the play bar, next to Last Played / Play Time (the in-page bar only, like Steam).
  const ACHIEVEMENT_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" fill="none"><g fill="currentColor"><path d="M9.64304 9.49988L6.39294 12.8055L9.64304 16.1112V20.8333H14.2858L18.0001 24.6111L21.7143 20.8333H26.3573V16.111L29.6072 12.8055L26.3573 9.50012V4.77777H21.7143L18.0001 1L14.2858 4.77777H9.64304V9.49988ZM22.6432 12.8056C22.6432 15.4136 20.5645 17.5278 18.0004 17.5278C15.4362 17.5278 13.3575 15.4136 13.3575 12.8056C13.3575 10.1976 15.4362 8.08334 18.0004 8.08334C20.5645 8.08334 22.6432 10.1976 22.6432 12.8056Z"></path><path d="M5 30.2778L8.25 24.6111H12.4286L15.6786 27.9167L11.5 35L9.17857 30.2778H5Z"></path><path d="M30.9999 30.2778L27.7499 24.6111H23.5713L20.3213 27.9167L24.4999 35L26.8213 30.2778H30.9999Z"></path></g></svg>';
  const sel = (cls) => "." + CSS.escape((cls ?? "").split(" ")[0]);
  const playBarStat = (doc, p) => {
    const B = steamUI.classes("GameStatsSection", "MiniAchievements", "AchievementProgressRow");
    const bar = B.InPage && [...doc.querySelectorAll(sel(B.Container))].find((n) => n.matches(sel(B.InPage)));
    const stats = bar?.querySelector(sel(B.GameStatsSection));
    if (!stats) return null;
    const earned = p.achievements.filter((r) => r.unlocked).length, total = p.achievements.length;
    const icon = el(doc, "div", { class: c(B, "GameStatIcon", "AchievementSVG") });
    icon.innerHTML = ACHIEVEMENT_SVG;
    const fill = el(doc, "div", { class: c(B, "DetailsProgressBar") });
    fill.style.width = `${total ? earned * 100 / total : 0}%`;
    const node = el(doc, "div", { class: c(B, "GameStat", "MiniAchievements") + " sra-stat", "data-sra-panel": "", onclick: () => openAll(p) }, icon,
      el(doc, "div", { class: c(B, "GameStatRight") }, el(doc, "div", { class: c(B, "PlayBarLabel") }, "Achievements"),
        el(doc, "div", { class: c(B, "AchievementProgressRow") }, el(doc, "div", { class: c(B, "PlayBarDetailLabel", "AchievementCountLabel") }, `${earned}/${total}`),
          el(doc, "div", { class: c(B, "DetailsProgressContainer") }, fill))));
    stats.append(node);
    return node;
  };

  // Signing in and choosing the game happen on the desktop library page; Big Picture only says so.
  const messageSection = (doc, p) => section(doc, current?.bpm ? "Achievements" : "RetroAchievements", ["AppDetailsSectionHasLabel", "RightColumnSection"],
    el(doc, "div", { class: c(K.details(), "Body") + " sra-message" },
      el(doc, "div", {}, current?.bpm && (p.state === "signedOut" || p.state === "notMatched") ? `${p.message} Do this on the desktop library page.` : p.message),
      !current?.bpm && p.state === "signedOut" && el(doc, "button", { class: steamButton, onclick: () => openSettings() }, "Sign In"),
      !current?.bpm && p.state === "notMatched" && el(doc, "button", { class: steamButton, onclick: () => openChooser(p.consoleId) }, "Choose game")));

  const render = (payload) => {
    const doc = steamUI.doc();
    if (!doc || !current) return;
    current.payload = payload;
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
      const nodes = (tab === 0 ? [p.game ? bpmActivity(doc, p) : messageSection(doc, p)]
        : tab === 1 ? [p.summary ? bpmStuff(doc, p) : messageSection(doc, p), p.game && detailsSection(doc, p)] : []).filter(Boolean);
      ((S && host.querySelector(sel(S))) ?? host).prepend(...nodes);
      current.nodes.push(...nodes);
      current.tab = tab;
      const items = nodes.flatMap((n) => registerNav(doc, n));
      if (refocus >= 0) takeFocus(items[refocus]);  // the update rebuilt the item that had focus
      return;
    }

    const p = payload, main = p.game ? achievementsSection(doc, p) : messageSection(doc, p);
    host.prepend(main);
    current.nodes.push(main);
    main.querySelectorAll(".sra-iconrow").forEach((w) => w.parentElement.parentElement.sraFit());
    const stat = p.summary && playBarStat(doc, p);
    if (stat) current.nodes.push(stat);
    const left = p.game && steamUI.findClass(doc, "LeftColumn");
    if (left) {
      const notice = K.notice().Body && left.querySelector("." + CSS.escape(K.notice().Body.split(" ")[0]));
      const box = notice?.closest("." + CSS.escape(c(K.details(), "AppDetailsSection").split(" ")[0]));
      if (box) { box.style.display = "none"; box.setAttribute("data-sra-hid", ""); }
      const details = detailsSection(doc, p);
      left.prepend(details);
      current.nodes.push(details);
    }
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
      el(item.ownerDocument, "div", { class: c(A, "Description") }, r.description), el(item.ownerDocument, "div", { class: c(A, "Achieved") }, r.rarityText ?? "")));
  };
  const carouselItem = (doc, r, open, big) => {
    const A = K.ach(), I = K.icon();
    const item = el(doc, "div", { class: c(A, "AchievementCarouselItem") + " Panel Focusable sra-item", role: "button", tabindex: "0", "aria-label": r.title, onclick: open,
        onfocus: () => { detail(item); item.scrollIntoView({ block: "nearest", inline: "nearest" }); } },
      el(doc, "div", { class: c(A, r.unlocked ? "Achieved" : "NotAchieved") + " Panel" }, el(doc, "div", { class: c(A, "AchievementHoverContainer") + " Panel" },
        el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "Icon", "CarouselIcon", ...(big ? ["Prioritized"] : [])) }, el(doc, "img", { class: c(I, "Icon"), src: r.badgeURL, alt: "" })))));
    item.sraRow = r;
    return item;
  };

  // YOUR STUFF: Steam's Achievements section; unlocked icons, then locked, then one icon per subset. A opens the achievements page.
  const bpmStuff = (doc, p) => {
    const A = K.ach(), D = K.details(), open = () => openAll(p);
    const unlocked = p.achievements.filter((r) => r.unlocked), locked = p.achievements.filter((r) => !r.unlocked);
    const label = (text) => el(doc, "h3", { class: c(A, "LockedAchievementsLabel") + " sra-h2" }, text);
    const parts = [];
    if (unlocked.length) parts.push(carousel(doc, unlocked.map((r) => carouselItem(doc, r, open, true))));
    if (locked.length) parts.push(label("Locked Achievements"), carousel(doc, locked.map((r) => carouselItem(doc, r, open, false))));
    if (p.subsets?.length) parts.push(label("Subsets"), carousel(doc, p.subsets.map((sp) => carouselItem(doc, { title: subsetName(sp), description: sp.game?.title ?? "",
      badgeURL: sp.game?.iconURL, unlocked: true, rarityText: sp.summary?.text ?? sp.message }, () => openAll(sp), true))));
    const first = parts[0].querySelector(".sra-item");
    if (first) detail(first);  // the most recent unlock, before anything has focus
    return section(doc, "Achievements", ["AppDetailsSectionHasLabel", "RightColumnSection"], progressHighlight(doc, p),
      el(doc, "div", { class: c(D, "Body") + " " + c(A, "BodyStopJiggle", "BasicAppDetailsAchievementsSectionBody") }, parts));
  };

  // ACTIVITY: "<you> achieved" events, one per day with unlocks, newest first, in Steam's activity feed markup.
  const bpmActivity = (doc, p) => {
    const unlocked = p.achievements.filter((r) => r.unlocked);
    if (!unlocked.length) return null;
    const ACT = steamUI.classes("AppActivityDay", "EventHeadline"), F = steamUI.classes("ActivityFeedContainer", "Rollup", "FetchMoreContainer");
    const AV = steamUI.classes("avatarHolder", "avatarStatus", "avatarFrame"), N = steamUI.classes("playerName", "statusAndName");
    const A = K.ach(), I = K.icon(), me = window.friendStore?.m_FriendsUIFriendStore?.self?.persona, open = () => openAll(p);
    const days = [];
    for (const r of unlocked) { const last = days.at(-1); last && last.day === r.unlockedDay ? last.rows.push(r) : days.push({ day: r.unlockedDay, rows: [r] }); }
    const item = (r) => el(doc, "div", { class: c(ACT, "PrimaryAchievement") + " " + c(A, "Achieved", "Featured") + " Panel Focusable sra-item", tabindex: "0", onclick: open,
        onfocus: () => item.scrollIntoView({ block: "nearest", inline: "nearest" }) },
      el(doc, "div", { class: c(A, "AchievementHoverContainer") + " Panel" }, el(doc, "div", { class: c(I, "AchievementIconWrapper") + " " + c(A, "Icon") }, el(doc, "img", { class: c(I, "Icon"), src: r.badgeURL, alt: "" }))),
      el(doc, "div", { class: c(A, "TextSection") }, el(doc, "div", { class: c(A, "Name") }, r.title), el(doc, "div", { class: c(A, "Desc") }, r.description)));
    const event = (rows) => el(doc, "div", { class: c(ACT, "Event", "NoCommentSupport") + " Panel" },
      el(doc, "div", { class: c(ACT, "EventHeadline") + " Panel" },
        el(doc, "div", { class: c(ACT, "EventActorAvatar") + " Panel" }, el(doc, "div", { class: c(AV, "avatarHolder") + " avatarHolder no-drag FillArea online" },
          el(doc, "div", { class: c(AV, "avatarStatus") + " avatarStatus right" }), me?.avatar_url_full && el(doc, "img", { class: c(AV, "avatar") + " avatar", src: me.avatar_url_full, alt: "" }))),
        el(doc, "span", { class: c(ACT, "SpanEvent") }, el(doc, "span", { class: c(ACT, "ActorName") }, el(doc, "span", { class: c(N, "playerName") }, me?.m_strPlayerName ?? "You")), " ", el(doc, "span", {}, "achieved"))),
      el(doc, "div", { class: c(ACT, "EventBody") }, carousel(doc, rows.map(item), c(ACT, "ActivityAchievementUnlocked"))));
    const node = section(doc, "Activity", ["AppDetailsSectionHasLabel"], el(doc, "div", { class: c(K.details(), "Body") + " " + c(F, "InnerContainer") },
      el(doc, "div", { class: "Panel" }, days.map((d) => el(doc, "div", { class: c(ACT, "AppActivityDay") },
        el(doc, "h4", { class: c(ACT, "AppActivityDate") + " sra-h2" }, d.day ?? "", el(doc, "div", { class: c(ACT, "Rule") })), el(doc, "div", {}, event(d.rows)))))));
    node.classList.add(...c(F, "ActivityFeedContainer").split(" ").filter(Boolean));
    return node;
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

  // Steam's achievements page (View My Achievements), over the game page like Steam's own.
  const openAll = (p) => {
    const doc = steamUI.doc();
    if (!doc || !p.game) return;
    closeOverlay?.();
    hideCard();
    const opener = doc.activeElement?.sraNode, nav = [];  // Big Picture: the focused item, to return to on close
    const O = steamUI.classes("AchievementsOverlayContainer", "AchievementsPageContainer", "CloseButton");
    const G = steamUI.classes("GamepadPage", "Flexed", "OverflowHidden");
    const P = steamUI.classes("HeaderContainer", "AchievementTabs", "MyAchievementsHeader");
    const H = steamUI.classes("StatsBlock", "BigStat", "AchievementSearchHeader");
    const T = steamUI.classes("GamepadTabbedPage", "TabRow", "TabTitle");
    const S = steamUI.classes("ScrollPanel", "ScrollY", "ScrollX");
    const L = steamUI.classes("AchievementListItemBase", "AchievementTitle", "UnlockDate");
    const PB = steamUI.classes("ProgressBar", "Percent", "Indeterminate", "TimeRemaining");
    const IM = steamUI.classes("GreyBackground", "Visibility", "Visible");
    const I = K.icon();
    const bar = (pct) => {
      const f = el(doc, "div", { class: c(PB, "Percent") });
      f.style.width = `${pct}%`;
      f.style.background = "var(--gpColor-Blue, #1a9fff)";  // Steam sets the colour inline too
      return el(doc, "div", { class: c(PB, "ProgressBar") }, f);
    };
    const total = p.achievements.length, earned = p.achievements.filter((r) => r.unlocked).length, pct = p.summary?.percent ?? 0;
    const hero = doc.querySelector('img[src*="_hero"]')?.getAttribute("src");

    let tab = "my", query = "";
    const tabs = [["my", "My Achievements"], ["global", "Global Achievements"]].map(([id, title]) =>
      el(doc, "div", { class: c(T, "Tab", "RightAddon") + " Panel", "data-tab": id, onclick: () => { tab = id; draw(); } }, el(doc, "span", { class: c(T, "TabTitle") }, title)));
    const search = el(doc, "input", { class: "DialogInput DialogInputPlaceholder DialogTextInputBase Focusable", placeholder: "Search", type: "text",
      oninput: () => { query = search.value.trim().toLowerCase(); draw(); } });
    const list = el(doc, "div", { class: "sra-column" });
    const row = (r) => el(doc, "div", { class: c(L, "AchievementListItemBase") + " Panel Focusable sra-li sra-item", tabindex: "-1",
        onfocus: (e) => e.currentTarget.scrollIntoView({ block: "nearest" }) }, el(doc, "div", { class: c(L, "Container") },
      el(doc, "div", {}, el(doc, "div", { class: c(I, "AchievementIconWrapper") }, el(doc, "img", { class: c(I, "Icon"), src: r.badgeURL, alt: "" }))),
      el(doc, "div", { class: c(L, "Content") }, el(doc, "div", { class: c(L, "VerticalContent", "AchievementContent") },
        el(doc, "div", { class: c(L, "AchievementTitle") }, r.title), el(doc, "div", { class: c(L, "AchievementDescription") }, r.description),
        el(doc, "div", { class: c(L, "AchievementGlobalPercentage", "InBody") }, [`${r.points} points${r.hardcore ? " · hardcore" : ""}`, tab === "my" && r.rarityText].filter(Boolean).join(" · ")))),
      el(doc, "div", { class: c(L, "Right") }, el(doc, "div", { class: c(L, "VerticalContent", "AlignEnd") },
        tab === "global" ? [el(doc, "div", { class: c(L, "ProgressCount") }, r.rarity == null ? "" : `${r.rarity.toFixed(1)}%`), el(doc, "div", { class: c(L, "ProgressBar") }, bar(r.rarity ?? 0))]
          : r.unlocked ? [el(doc, "div", { class: c(L, "UnlockDate") }, r.unlockedText), el(doc, "div", { class: c(L, "ProgressBar") }, bar(100))] : []))));
    const draw = () => {
      tabs.forEach((t) => { t.className = c(T, "Tab", "RightAddon", ...(t.dataset.tab === tab ? ["Selected"] : [])) + " Panel"; });
      const rows = p.achievements.filter((r) => !query || `${r.title} ${r.description}`.toLowerCase().includes(query));
      const locked = rows.filter((r) => !r.unlocked);
      list.replaceChildren(...(tab === "global" ? [...rows].sort((a, b) => (b.rarity ?? 0) - (a.rarity ?? 0)).map(row)
        : [...rows.filter((r) => r.unlocked).map(row), ...(locked.length ? [el(doc, "div", { class: c(L, "ListTitle") }, "Locked Achievements")] : []), ...locked.map(row)]));
      if (!current?.bpm || !node.isConnected) return;
      unregister();
      takeFocus(registerNav(doc, node, nav, { [BTN.CANCEL]: "Back" })[0]);  // the rows are a column; LB/RB switch tabs, B closes
    };
    const unregister = () => { nav.reverse().forEach((fn) => { try { fn(); } catch (_) {} }); nav.length = 0; };
    // Steam sends the controller's buttons to the focused row; claim the ones that would leave the page behind it.
    const onPad = safe((e) => {
      const b = e.detail?.button, items = [...list.querySelectorAll(".sra-item")], at = items.indexOf(doc.activeElement);
      if (b === BTN.CANCEL) { handled(e); close(); }
      else if (b === BTN.BUMPER_LEFT || b === BTN.BUMPER_RIGHT) { handled(e); tab = b === BTN.BUMPER_LEFT ? "my" : "global"; draw(); }
      else if (b === BTN.DIR_LEFT || b === BTN.DIR_RIGHT || (b === BTN.DIR_UP && at <= 0) || (b === BTN.DIR_DOWN && at === items.length - 1)) handled(e);
    });

    const header = el(doc, "div", { class: c(P, "HeaderContainer") + " Panel" }, el(doc, "div", { class: c(H, "Container") }, el(doc, "div", { class: c(H, "Content") },
      el(doc, "div", { class: c(H, "Title") }, el(doc, "div", { class: c(IM, "Container", "GreyBackground") + " " + c(H, "GameIcon") },
        el(doc, "img", { class: c(IM, "Image", "Visibility", "Visible"), src: p.game.iconURL, alt: "" })), p.game.title),
      el(doc, "div", { class: "Panel" }, el(doc, "div", { class: c(H, "StatsBlock") }, el(doc, "div", { class: c(H, "Stat", "BigStat") },
        el(doc, "div", { class: c(H, "StatLabelAndValue") },
          el(doc, "div", { class: c(H, "ProgressLabel") }, el(doc, "div", { class: c(H, "Label") }, `${earned} of ${total} achievements earned`), el(doc, "div", { class: c(H, "Label") }, `(${pct}%)`)),
          el(doc, "div", { class: c(H, "Progress") }, bar(pct)))))))));
    const tabbed = el(doc, "div", { class: c(T, "GamepadTabbedPage", "CanBeHeaderBackground") + " Panel" },
      el(doc, "div", { class: c(T, "TabHeaderRowWrapper", "Pinned") }, el(doc, "div", { class: c(T, "TabRow") }, el(doc, "div", { class: c(T, "TabRowTabs") },
        el(doc, "div", { class: c(T, "TabsRowScroll") }, el(doc, "div", { class: c(T, "FixCenterAlignScroll") + " Panel" },
          el(doc, "div", { class: c(T, "TabRowSpacer") }), tabs, el(doc, "div", { class: c(T, "TabRowSpacer") })))))),
      el(doc, "div", { class: c(T, "TabContents") + " Panel" }, el(doc, "div", { class: "_TabContentsScroll " + c(T, "TabContentsScroll") + " Panel" },
        el(doc, "div", { class: c(L, "AchievementList") + " " + c(P, "List") + " Panel" },
        el(doc, "div", { class: c(H, "AchievementSearchHeader") + " " + c(P, "MyAchievementsHeader") + " Panel" }, el(doc, "div", { class: c(H, "LeftContent") }),
          el(doc, "div", { class: c(H, "SearchField") }, el(doc, "div", { class: "DialogInput_Wrapper _DialogLayout Panel" }, search))),
        list))));
    const closeButton = el(doc, "div", { class: c(O, "CloseButton") + " sra-close", onclick: () => close() });
    closeButton.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" class="SVGIcon_Button SVGIcon_X_Line" viewBox="0 0 256 256"><line fill="none" stroke="#FFFFFF" stroke-width="45" x1="212" y1="212" x2="44" y2="44"></line><line fill="none" stroke="#FFFFFF" stroke-width="45" x1="44" y1="212" x2="212" y2="44"></line></svg>';
    const node = el(doc, "div", { class: c(O, "AppDetailsOverlayTransitionGroup") },
      el(doc, "div", { class: c(O, "AchievementsOverlayContainer", "OverlayAppDetailsTransitionEntered") },
        el(doc, "div", { class: c(O, "AchievementsPageContainer") },
          el(doc, "div", { class: c(G, "GamepadPage", "Flexed", "OverflowHidden") + " Panel" },
            el(doc, "div", { class: c(P, "Page") + " " + c(S, "ScrollPanel", "ScrollY") + " Panel" },
              el(doc, "div", { class: c(P, "Background") }, el(doc, "div", { class: c(P, "Blur") }),
                hero && el(doc, "div", { class: c(IM, "Container", "GreyBackground") + " " + c(P, "HeaderImage") }, el(doc, "img", { class: c(IM, "Image", "Visibility", "Visible"), src: hero, alt: "" }))),
              el(doc, "div", { class: c(P, "Container") + " Panel" }, header, el(doc, "div", { class: c(P, "AchievementTabs") + " Panel" }, tabbed)))),
          closeButton)));
    const onKey = safe((e) => { if (e.key === "Escape") close(); });
    const close = () => { unregister(); node.remove(); doc.removeEventListener("keydown", onKey, true); closeOverlay = null; takeFocus(opener); };
    doc.addEventListener("keydown", onKey, true);
    node.addEventListener("vgp_onbuttondown", onPad);
    (steamUI.findClass(doc, "AppDetailsMain") ?? doc.body).append(node);
    closeOverlay = close;
    draw();
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
    } else if (current?.payload && current.payload.state !== "hidden" && (current.nodes?.some((n) => !n.isConnected) || (current.bpm && current.tab !== bpmTab(doc)))) {
      render(current.payload);   // Steam re-rendered the page and dropped our node, or Big Picture switched tabs
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
