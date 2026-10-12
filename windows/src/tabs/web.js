'use strict';
// Web tabs: Apps (favourite apps + websites that can open inside the notch), AI (chat in the AI's own site), Browser.
(function () {
  const N = window.N, el = N.el, api = N.api;

  // ------------------------------------------------------------------ constants + tiny helpers
  const ZMIN = 40, ZMAX = 150, ZSTEP = 10, ZDEF = 60, AI_ZOOM = 80;
  const HOLD = 20000;
  const clampZoom = z => Math.max(ZMIN, Math.min(ZMAX, Math.round((Number(z) || ZDEF) / ZSTEP) * ZSTEP));
  const hold = () => { try { api.holdOpen(HOLD); } catch (e) { /* ignore */ } };
  const warn = (e) => { try { console.error('web tab:', e && e.message ? e.message : e); } catch (x) { /* ignore */ } };
  const safe = fn => function () { try { return fn.apply(this, arguments); } catch (e) { warn(e); } };
  const settle = p => { try { return Promise.resolve(p).catch(() => {}); } catch (e) { return Promise.resolve(); } };

  try {
    const IC = N.icons;
    if (IC) {
      if (!IC.nwRight) IC.nwRight = '<path d="M5 12h14M12 5l7 7-7 7"/>';
      if (!IC.nwLeft) IC.nwLeft = '<path d="M19 12H5M12 19l-7-7 7-7"/>';
    }
  } catch (e) { /* ignore */ }

  const css = [
    '.nw-bar{display:flex;gap:6px;align-items:center;margin-bottom:6px;flex:none;min-width:0}',
    '.nw-bar .btn{flex:none}',
    '.nw-url{flex:1;min-width:0;width:100%}',
    '.nw-title{flex:1;min-width:0;display:flex;align-items:center;gap:6px;font-weight:600;white-space:nowrap}',
    '.nw-title span.t{overflow:hidden;text-overflow:ellipsis}',
    '.nw-badge{flex:none;font-size:9.5px;font-weight:700;letter-spacing:.3px;text-transform:uppercase;padding:1px 6px;border-radius:8px;background:var(--faint2);color:var(--dim)}',
    '.nw-zoom{flex:none;display:flex;align-items:center;background:var(--faint);border-radius:9px;padding:1px}',
    '.nw-zoom button{border:0;background:transparent;border-radius:8px;cursor:pointer;color:inherit;height:26px;min-width:26px;display:grid;place-items:center;padding:0 4px}',
    '.nw-zoom button:hover{background:var(--faint2)}',
    '.nw-zoom button:disabled{opacity:.35;cursor:default}',
    '.nw-zoom .pct{min-width:44px;font-size:11.5px;font-variant-numeric:tabular-nums}',
    '.nw-stage{position:relative;flex:1;min-height:0;border-radius:10px;overflow:hidden;background:#111}',
    '.nw-stage>.webbox{position:absolute;inset:0;margin:0;border-radius:0}',
    '.nw-viewer{position:absolute;inset:0;display:flex;flex-direction:column;visibility:hidden;pointer-events:none;background:#000;z-index:2}',
    '.nw-viewer.on{visibility:inherit;pointer-events:auto}',
    '.nw-fail{position:absolute;inset:0;z-index:3;background:#111;display:none;flex-direction:column;align-items:center;justify-content:center;gap:8px;text-align:center;padding:20px}',
    '.nw-fail.on{display:flex}',
    '.nw-fail .big{font-size:15px;font-weight:700}',
    '.nw-fail .msg{color:var(--dim);max-width:420px;overflow-wrap:anywhere}',
    '.nw-home{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:16px;text-align:center}',
    '.nw-home .big{font-size:18px;font-weight:700}',
    '.nw-quick{display:flex;gap:10px;flex-wrap:wrap;justify-content:center;max-width:560px}',
    '.nw-q{width:92px;border:0;background:rgba(255,255,255,.08);border-radius:12px;padding:10px 4px;cursor:pointer;display:flex;flex-direction:column;align-items:center;gap:6px;font-size:11px}',
    '.nw-q:hover{background:rgba(255,255,255,.15)}',
    '.nw-letter{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:700;font-size:18px;color:#fff;flex:none;text-transform:uppercase}',
    '.nw-tile{background:rgba(255,255,255,.08);border-radius:12px;padding:10px 4px 8px;text-align:center;cursor:pointer;position:relative;min-width:0}',
    '.nw-tile:hover{background:rgba(255,255,255,.15)}',
    '.nw-tile .ic{width:38px;height:38px;margin:0 auto 5px;display:grid;place-items:center}',
    '.nw-tile .ic img{width:36px;height:36px;object-fit:contain;border-radius:6px;display:block}',
    '.nw-tile .nm{font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 4px}',
    '.nw-tile .nw-badge{position:absolute;top:5px;right:5px}',
    '.nw-add{border:1.5px dashed rgba(255,255,255,.22);background:transparent;color:var(--dim);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;min-height:78px}',
    '.nw-form{display:flex;flex-direction:column;gap:10px;max-width:520px;width:100%;margin:0 auto;padding-top:6px}',
    '.nw-form label{display:flex;flex-direction:column;gap:4px;font-size:11px;color:var(--dim)}',
    '.nw-form input{width:100%;font-size:13px;color:#fff}',
    '.nw-err{color:#ff8a80;font-size:11.5px;min-height:15px}',
    '.nw-bigbtn{display:flex;align-items:center;gap:12px;width:100%;border:0;background:rgba(255,255,255,.08);border-radius:12px;padding:12px 14px;cursor:pointer;text-align:left}',
    '.nw-bigbtn:hover{background:rgba(255,255,255,.15)}',
    '.nw-bigbtn .s{font-size:11px;color:var(--dim)}',
    '.nw-row{display:flex;align-items:center;gap:10px;padding:6px 8px;border-radius:9px;cursor:pointer;min-width:0}',
    '.nw-row:hover{background:var(--faint)}',
    '.nw-row .ic{width:24px;height:24px;flex:none;display:grid;place-items:center}',
    '.nw-row .ic img{width:24px;height:24px;object-fit:contain}',
    '.nw-row .nm{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '.nw-ai{display:grid;grid-template-columns:repeat(auto-fill,minmax(128px,1fr));gap:8px;align-content:start}',
    '.nw-card{background:rgba(255,255,255,.08);border-radius:14px;padding:12px 8px 10px;display:flex;flex-direction:column;align-items:center;gap:8px;min-width:0;border:1.5px solid transparent}',
    '.nw-card.last{border-color:var(--accent)}',
    '.nw-card .nm{font-weight:600;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}',
    '.nw-card .btns{display:flex;gap:5px}',
    '.nw-card .btn{padding:3px 10px;font-size:11.5px}',
    '.nw-veiltxt{pointer-events:none;text-align:center;padding:0 20px}'
  ].join('\n');
  try { document.head.appendChild(el('style', { text: css })); } catch (e) { warn(e); }

  // ------------------------------------------------------------------ url helpers
  function hostOf(u) { try { return new URL(u).hostname.replace(/^www\./i, ''); } catch (e) { return ''; } }

  // Strict: for the "add website" / "web address" forms. Returns a normalised http(s) url or null.
  function parseWebUrl(raw) {
    let s = String(raw == null ? '' : raw).trim();
    if (!s || /\s/.test(s)) return null;
    if (!/^https?:\/\//i.test(s)) { if (/^[a-z][a-z0-9+.-]*:(?!\d)/i.test(s)) return null; s = 'https://' + s; }
    try {
      const u = new URL(s);
      if (!/^https?:$/.test(u.protocol)) return null;
      if (!u.hostname || (!u.hostname.includes('.') && u.hostname !== 'localhost')) return null;
      return u.href;
    } catch (e) { return null; }
  }

  // Lenient: for the browser address bar. {ok, url, search?, reason?}
  const HOSTLIKE = /^(localhost|(\d{1,3}\.){3}\d{1,3}|([a-z0-9-]+\.)+[a-z]{2,})(:\d{1,5})?([/?#]\S*)?$/i;
  function resolveInput(raw) {
    const s = String(raw == null ? '' : raw).trim();
    if (!s) return { ok: false, reason: 'empty' };
    if (/^https?:\/\//i.test(s)) {
      try { const u = new URL(s); if (u.hostname) return { ok: true, url: u.href }; } catch (e) { /* fall through */ }
      return { ok: false, reason: 'bad' };
    }
    if (/^(javascript|data|file|vbscript|blob|about|chrome|chrome-extension|view-source|ftp|mailto|tel|ws|wss|ms-[a-z-]+):/i.test(s)) return { ok: false, reason: 'scheme' };
    if (HOSTLIKE.test(s)) {
      const local = /^(localhost|\d{1,3}(\.\d{1,3}){3})(:|\/|\?|#|$)/i.test(s);
      try { const u = new URL((local ? 'http://' : 'https://') + s); return { ok: true, url: u.href }; } catch (e) { /* search instead */ }
    }
    return { ok: true, url: 'https://duckduckgo.com/?q=' + encodeURIComponent(s), search: true };
  }

  function friendlyFail(code, desc) {
    const c = Number(code);
    if ([-106, -105, -109, -118, -130, -137, -138, -324, -101, -102, -7].includes(c)) return "Can't reach this site. Check your internet connection and try again.";
    if (c >= -299 && c <= -200) return "This site's security certificate isn't trusted, so it was blocked.";
    if (c === -20 || c === -27) return 'This page was blocked.';
    return "This page couldn't be loaded" + (desc ? ' (' + String(desc).replace(/^ERR_/, '').replace(/_/g, ' ').toLowerCase() + ').' : '.');
  }

  // ------------------------------------------------------------------ letter tiles
  function hueOf(s) { let h = 7; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360; return h; }
  function letterTile(name, size, color) {
    const s = String(name || '?').trim();
    const ch = (s.match(/[A-Za-z0-9À-￿]/) || ['?'])[0];
    const t = el('div', { class: 'nw-letter', text: ch });
    t.style.background = color || ('hsl(' + hueOf(s.toLowerCase()) + ',52%,42%)');
    if (size) { t.style.width = size + 'px'; t.style.height = size + 'px'; t.style.fontSize = Math.round(size * 0.48) + 'px'; t.style.borderRadius = Math.round(size * 0.26) + 'px'; }
    return t;
  }
  // icon for a local app: letter tile first, swapped for the real icon when Windows gives one
  function appIcon(holder, name, path, size) {
    holder.appendChild(letterTile(name, size));
    if (!path) return;
    let p; try { p = api.fileIcon(path); } catch (e) { return; }
    settle(Promise.resolve(p).then(u => {
      if (!u || typeof u !== 'string' || !holder.isConnected) return;
      const img = el('img', { alt: '', src: u });
      N.clear(holder); holder.appendChild(img);
    }));
  }

  // ------------------------------------------------------------------ known web versions of popular apps
  const KNOWN = [
    [/spotify/i, 'https://open.spotify.com'],
    [/whats\s?app/i, 'https://web.whatsapp.com'],
    [/discord/i, 'https://discord.com/app'],
    [/slack/i, 'https://app.slack.com/client'],
    [/notion/i, 'https://www.notion.so'],
    [/telegram/i, 'https://web.telegram.org'],
    [/teams/i, 'https://teams.microsoft.com'],
    [/outlook/i, 'https://outlook.office.com/mail'],
    [/onenote/i, 'https://www.onenote.com/notebooks'],
    [/\bword\b/i, 'https://www.microsoft365.com/launch/word'],
    [/\bexcel\b/i, 'https://www.microsoft365.com/launch/excel'],
    [/power\s?point/i, 'https://www.microsoft365.com/launch/powerpoint'],
    [/\boffice\b|microsoft 365|\bm365\b/i, 'https://www.microsoft365.com'],
    [/onedrive/i, 'https://onedrive.live.com'],
    [/youtube\s?music/i, 'https://music.youtube.com'],
    [/youtube/i, 'https://www.youtube.com'],
    [/google\s?calendar/i, 'https://calendar.google.com'],
    [/gmail/i, 'https://mail.google.com'],
    [/google\s?drive|^drive$/i, 'https://drive.google.com'],
    [/google\s?docs/i, 'https://docs.google.com'],
    [/google\s?meet/i, 'https://meet.google.com'],
    [/chat\s?gpt/i, 'https://chatgpt.com'],
    [/\bclaude\b/i, 'https://claude.ai'],
    [/gemini/i, 'https://gemini.google.com'],
    [/messenger/i, 'https://www.messenger.com'],
    [/instagram/i, 'https://www.instagram.com'],
    [/facebook/i, 'https://www.facebook.com'],
    [/twitter|^x$/i, 'https://x.com'],
    [/reddit/i, 'https://www.reddit.com'],
    [/netflix/i, 'https://www.netflix.com'],
    [/twitch/i, 'https://www.twitch.tv'],
    [/soundcloud/i, 'https://soundcloud.com'],
    [/apple\s?music/i, 'https://music.apple.com'],
    [/figma/i, 'https://www.figma.com'],
    [/canva/i, 'https://www.canva.com'],
    [/trello/i, 'https://trello.com'],
    [/github/i, 'https://github.com'],
    [/\bzoom\b/i, 'https://app.zoom.us/wc']
  ];
  function knownWeb(name) {
    const n = String(name || '');
    for (const [re, u] of KNOWN) if (re.test(n)) return u;
    return null;
  }

  // ------------------------------------------------------------------ one guarded webview (+ failure message)
  // Everything on the returned object is safe to call at any time (before dom-ready, after destroy...).
  function mkView(o) {
    let view;
    try { view = document.createElement('webview'); view.setAttribute('src', o.url || 'about:blank'); }
    catch (e) { warn(e); return null; }
    const V = { view, ready: false, dead: false, url: o.url || '', title: '', loading: false, canBack: false, canFwd: false, zoom: clampZoom(o.zoom), failed: false, focused: false };
    const failBig = el('div', { class: 'big', text: "Can't open this page" });
    const failMsg = el('div', { class: 'msg' });
    const failEl = el('div', { class: 'nw-fail' }, failBig, failMsg,
      el('button', { class: 'btn', onclick: safe(() => V.retry()) }, N.icon('reload', 14), 'Try again'));
    V.box = el('div', { class: 'webbox' }, view, failEl);

    let holdT = null;
    const stopHold = () => { if (holdT) { clearInterval(holdT); holdT = null; } };
    const showFail = msg => { V.failed = true; failMsg.textContent = msg; failEl.classList.add('on'); sync(); };
    const hideFail = () => { V.failed = false; failEl.classList.remove('on'); };
    function sync() {
      if (V.dead) return;
      if (V.ready) { try { V.canBack = !!view.canGoBack(); V.canFwd = !!view.canGoForward(); } catch (e) { V.canBack = false; V.canFwd = false; } }
      try { o.onState && o.onState(V); } catch (e) { warn(e); }
    }
    function applyZoom() { if (!V.ready) return; try { view.setZoomFactor(V.zoom / 100); } catch (e) { /* not ready yet */ } }
    const on = (ev, fn) => view.addEventListener(ev, e => { if (V.dead) return; try { fn(e); } catch (err) { warn(err); } });

    on('dom-ready', () => { V.ready = true; applyZoom(); sync(); });
    on('did-start-loading', () => { V.loading = true; sync(); });
    on('did-stop-loading', () => { V.loading = false; applyZoom(); sync(); });
    on('did-navigate', e => {
      if (e.url && /^https?:/i.test(e.url)) { V.url = e.url; hideFail(); }
      applyZoom(); sync();
    });
    on('did-navigate-in-page', e => { if (e.isMainFrame !== false && e.url && /^https?:/i.test(e.url)) V.url = e.url; sync(); });
    on('page-title-updated', e => { V.title = String(e.title || ''); sync(); });
    on('did-fail-load', e => {
      if (e.isMainFrame === false || Number(e.errorCode) === -3) return;
      showFail(friendlyFail(e.errorCode, e.errorDescription));
    });
    on('render-process-gone', () => { V.ready = false; showFail('This page stopped working. Try loading it again.'); });
    on('crashed', () => { V.ready = false; showFail('This page stopped working. Try loading it again.'); });
    on('focus', () => { V.focused = true; hold(); if (!holdT) holdT = setInterval(() => { if (V.dead) stopHold(); else hold(); }, 8000); });
    on('blur', () => { V.focused = false; stopHold(); });

    V.go = function (url) {
      if (V.dead) return;
      hideFail(); V.url = url;
      try {
        if (V.ready) settle(view.loadURL(url));
        else view.setAttribute('src', url);
      } catch (e) { try { view.setAttribute('src', url); } catch (e2) { warn(e2); } }
      sync();
    };
    V.retry = function () {
      if (V.dead) return;
      const u = V.url;
      hideFail();
      try { if (V.ready) { settle(view.loadURL(u)); return; } } catch (e) { /* fall through */ }
      try { view.setAttribute('src', 'about:blank'); setTimeout(() => { try { if (!V.dead) view.setAttribute('src', u); } catch (e) { warn(e); } }, 60); } catch (e) { warn(e); }
    };
    V.reload = function () { if (V.dead) return; if (V.failed) { V.retry(); return; } try { if (V.ready) view.reload(); } catch (e) { V.retry(); } };
    V.back = function () { try { if (V.ready && view.canGoBack()) view.goBack(); } catch (e) { /* ignore */ } };
    V.fwd = function () { try { if (V.ready && view.canGoForward()) view.goForward(); } catch (e) { /* ignore */ } };
    V.setZoom = function (pct) { V.zoom = clampZoom(pct); applyZoom(); sync(); return V.zoom; };
    V.audible = function () { try { return !!(V.ready && view.isCurrentlyAudible()); } catch (e) { return false; } };
    V.exec = function (js) {
      if (V.dead || !V.ready) return Promise.reject(new Error('not ready'));
      try { return Promise.resolve(view.executeJavaScript(js)); } catch (e) { return Promise.reject(e); }
    };
    V.focusPage = function () { try { if (V.ready) view.focus(); } catch (e) { /* ignore */ } };
    V.setHidden = function (h) { view.classList.toggle('hid', !!h); V.box.style.visibility = h ? 'hidden' : ''; V.box.style.pointerEvents = h ? 'none' : ''; };
    V.destroy = function () {
      if (V.dead) return;
      V.dead = true; stopHold();
      try { V.box.remove(); } catch (e) { /* ignore */ }
    };
    return V;
  }

  // zoom control: [-] 60% [+]; clicking the percentage resets
  function mkZoomCtl(onChange, def) {
    const minus = el('button', { title: 'Zoom out', onclick: () => onChange(-ZSTEP) }, N.icon('zoomout', 14));
    const pct = el('button', { class: 'pct', title: 'Reset zoom', text: def + '%', onclick: () => onChange(0) });
    const plus = el('button', { title: 'Zoom in', onclick: () => onChange(ZSTEP) }, N.icon('zoomin', 14));
    const root = el('div', { class: 'nw-zoom' }, minus, pct, plus);
    return {
      root,
      update(z) { pct.textContent = z + '%'; minus.disabled = z <= ZMIN; plus.disabled = z >= ZMAX; }
    };
  }

  // ------------------------------------------------------------------ viewer: several kept-alive pages, one visible at a time
  function mkViewer(cfg) {
    const sites = new Map();
    let active = null, isOpen = false, paneVis = false;
    const curSite = () => (active ? sites.get(active) : null);

    const nBack = el('button', { class: 'btn icon', title: 'Back', onclick: () => { const s = curSite(); if (s && s.V) s.V.back(); } }, N.icon('nwLeft', 14));
    const nFwd = el('button', { class: 'btn icon', title: 'Forward', onclick: () => { const s = curSite(); if (s && s.V) s.V.fwd(); } }, N.icon('nwRight', 14));
    const nRel = el('button', { class: 'btn icon', title: 'Reload', onclick: () => { const s = curSite(); if (s && s.V) s.V.reload(); } }, N.icon('reload', 14));
    const titleT = el('span', { class: 't' });
    const title = el('div', { class: 'nw-title' }, titleT, cfg.badge ? el('span', { class: 'nw-badge', text: 'web' }) : null);
    const zoom = mkZoomCtl(d => {
      const s = curSite(); if (!s) return;
      const z = d === 0 ? (cfg.zoom || ZDEF) : clampZoom((s.V ? s.V.zoom : s.zoom) + d);
      s.zoom = z; if (s.V) s.V.setZoom(z); syncBar();
    }, cfg.zoom || ZDEF);
    const backBtn = el('button', { class: 'btn', title: cfg.backTitle || 'Back', onclick: safe(() => { V_close(); cfg.onClose && cfg.onClose(); }) }, N.icon('nwLeft', 14), cfg.backLabel || 'Back');
    const bar = el('div', { class: 'nw-bar' }, backBtn, title, nBack, nFwd, nRel, zoom.root);
    const stage = el('div', { class: 'nw-stage' });
    const root = el('div', { class: 'nw-viewer' }, bar, stage);
    cfg.pane.appendChild(root);

    function syncBar() {
      const s = curSite();
      titleT.textContent = s ? s.title : '';
      const V = s && s.V;
      nBack.disabled = !(V && V.canBack); nFwd.disabled = !(V && V.canFwd); nRel.disabled = !V;
      zoom.update(s ? (V ? V.zoom : s.zoom) : (cfg.zoom || ZDEF));
    }
    function applyVis() {
      root.classList.toggle('on', isOpen);
      sites.forEach((s, k) => { if (s.V && !s.V.dead) s.V.setHidden(!(isOpen && paneVis && k === active)); });
    }
    function ensure(s) {
      if (s.V && !s.V.dead) return true;
      s.V = null;
      const V = mkView({ url: s.url, zoom: s.zoom, onState: () => { if (curSite() === s) syncBar(); } });
      if (!V) { N.toast('Web pages are unavailable right now'); return false; }
      s.V = V; s.last = Date.now();
      stage.appendChild(V.box);
      if (cfg.onCreate) { try { cfg.onCreate(V, s); } catch (e) { warn(e); } }
      return true;
    }
    function V_close() { isOpen = false; applyVis(); syncBar(); }

    return {
      root, stage, sites,
      get isOpen() { return isOpen; },
      get active() { return active; },
      activeView() { const s = curSite(); return s && s.V && !s.V.dead ? s.V : null; },
      open(key, name, url) {
        let s = sites.get(key);
        if (!s) { s = { key, title: name, url, zoom: cfg.zoom || ZDEF, V: null, last: Date.now() }; sites.set(key, s); }
        s.title = name;
        if (s.url !== url) { s.url = url; if (s.V && !s.V.dead) s.V.go(url); }
        active = key; isOpen = true; s.last = Date.now();
        ensure(s); applyVis(); syncBar();
      },
      close: V_close,
      drop(key) {
        const s = sites.get(key); if (!s) return;
        if (s.V) s.V.destroy();
        sites.delete(key);
        if (active === key) { active = null; isOpen = false; applyVis(); syncBar(); }
      },
      setPaneVisible(b) {
        paneVis = !!b;
        const s = curSite();
        if (paneVis && isOpen && s) { s.last = Date.now(); ensure(s); }
        applyVis(); syncBar();
      },
      sweep(now, mins, idleOn) {
        sites.forEach((s, k) => {
          if (!s.V || s.V.dead) return;
          if (isOpen && paneVis && N.open && k === active) { s.last = now; return; }
          if (!idleOn) return;
          if (now - s.last < mins * 60000) return;
          if (s.V.audible()) return;   // music / calls keep their page alive
          const V = s.V; s.V = null; V.destroy();
          if (k === active) syncBar();
        });
      }
    };
  }

  // idle unloading, shared by apps + ai
  const viewers = [];
  N.startWeb = function () {
    setInterval(() => {
      try {
        const on = N.get('idleUnload', true) !== false;
        const m = Number(N.get('idleUnloadMins', 30));
        const mins = isFinite(m) && m > 0 ? m : 30;
        const now = Date.now();
        viewers.forEach(v => { try { v.sweep(now, mins, on); } catch (e) { warn(e); } });
      } catch (e) { warn(e); }
    }, 30000);
  };

  // ==================================================================== APPS
  const A = { grid: null, viewer: null, mode: 'grid', target: null, installed: null, loadingInst: false, filter: '' };

  const getFavs = () => {
    const raw = N.get('favApps', []);
    return (Array.isArray(raw) ? raw : []).filter(x => x && typeof x === 'object' && typeof x.name === 'string' && ((typeof x.path === 'string' && x.path) || (typeof x.url === 'string' && x.url)));
  };
  const favKey = it => (it.path ? 'p:' + it.path.toLowerCase() : 'u:' + it.url);
  const webFor = it => (it.url ? it.url : (typeof it.web === 'string' && it.web ? it.web : knownWeb(it.name)));
  const saveFavs = list => { N.set('favApps', list); };
  function addFav(entry) {
    const list = getFavs();
    if (list.some(x => favKey(x) === favKey(entry))) return false;
    list.push(entry); saveFavs(list); return true;
  }
  function baseName(p) { return String(p || '').split(/[\\/]/).pop().replace(/\.(exe|lnk|bat|cmd)$/i, '') || 'App'; }

  function openFav(it) {
    const web = webFor(it);
    if (web) { A.viewer.open(favKey(it), it.name, web); return; }
    openReal(it);
  }
  function openReal(it) {
    if (!it.path) { N.toast('This is a website - open it inside the notch'); return; }
    settle(Promise.resolve(api.openPath(it.path)).then(r => { if (r) N.toast("Couldn't open " + it.name); }).catch(() => N.toast("Couldn't open " + it.name)));
  }
  function setMode(m, target) { A.mode = m; A.target = target || null; A.filter = ''; renderApps(); }

  function appsHeader(text, sub) {
    return el('div', { class: 'row', style: { marginBottom: '8px', flex: 'none' } },
      el('div', { class: 'h', text }), el('div', { class: 'dim small grow', text: sub || '' }));
  }
  function backHeader(text) {
    return el('div', { class: 'row', style: { marginBottom: '8px', flex: 'none' } },
      el('button', { class: 'btn icon', title: 'Back', onclick: () => setMode('grid') }, N.icon('nwLeft', 14)),
      el('div', { class: 'h grow', text }));
  }

  function renderApps() {
    const g = A.grid; if (!g) return;
    try {
      N.clear(g);
      if (A.mode === 'grid') renderAppsGrid(g);
      else if (A.mode === 'add') renderAddMenu(g);
      else if (A.mode === 'installed') renderInstalled(g);
      else if (A.mode === 'site') renderSiteForm(g);
      else if (A.mode === 'addr') renderAddr(g);
    } catch (e) { warn(e); N.clear(g); g.appendChild(el('div', { class: 'empty err', text: 'Something went wrong showing your apps.' })); A.mode = 'grid'; }
  }

  function renderAppsGrid(g) {
    const list = getFavs();
    g.appendChild(el('div', { class: 'row', style: { marginBottom: '8px', flex: 'none' } },
      el('div', { class: 'h', text: 'Apps' }),
      el('div', { class: 'dim small grow', text: list.length ? 'Right-click an app for more options' : '' }),
      el('button', { class: 'btn', onclick: () => setMode('add') }, N.icon('plus', 14), 'Add')));
    const grid = el('div', { class: 'grid scroll grow', style: { gridTemplateColumns: 'repeat(auto-fill, minmax(96px, 1fr))', padding: '2px' } });
    list.forEach(it => {
      const web = webFor(it);
      const ic = el('div', { class: 'ic' });
      if (it.url) ic.appendChild(letterTile(it.name, 38)); else appIcon(ic, it.name, it.path, 38);
      const t = el('div', { class: 'nw-tile', title: it.name + (web ? '  (opens inside the notch)' : ''), onclick: safe(() => openFav(it)) },
        ic, el('div', { class: 'nm', text: it.name }), web ? el('span', { class: 'nw-badge', text: 'web' }) : null);
      t.addEventListener('contextmenu', e => {
        const items = [];
        if (it.url) {
          items.push({ label: 'Open', fn: () => openFav(it) });
          items.push({ label: 'Open in default browser', fn: () => settle(api.openExternal(it.url)) });
        } else {
          if (web) items.push({ label: 'Open inside the notch', fn: () => openFav(it) });
          items.push({ label: web ? 'Change web address...' : 'Open inside the notch...', fn: () => setMode('addr', favKey(it)) });
          items.push({ label: 'Open the real app', fn: () => openReal(it) });
        }
        items.push({ label: 'Remove', danger: true, fn: () => removeFav(it) });
        N.menu(e, items);
      });
      grid.appendChild(t);
    });
    if (!list.length) grid.appendChild(el('div', { class: 'empty', style: { gridColumn: '1/-1' }, text: 'Add your favourite apps and websites here. Popular ones like Spotify, WhatsApp or YouTube open right inside the notch.' }));
    grid.appendChild(el('button', { class: 'nw-tile nw-add', title: 'Add an app or website', onclick: () => setMode('add') }, N.icon('plus', 20), el('span', { class: 'small', text: 'Add' })));
    g.appendChild(grid);
  }

  function removeFav(it) {
    const k = favKey(it);
    A.viewer.drop(k);
    saveFavs(getFavs().filter(x => favKey(x) !== k));
    renderApps();
  }

  function renderAddMenu(g) {
    g.appendChild(backHeader('Add to Apps'));
    const big = (icon, t, s, fn) => el('button', { class: 'nw-bigbtn', onclick: safe(fn) }, N.icon(icon, 20), el('div', null, el('div', { text: t }), el('div', { class: 's', text: s })));
    g.appendChild(el('div', { class: 'nw-form' },
      big('apps', 'Choose from installed apps', 'Pick from the apps on this PC', () => setMode('installed')),
      big('folder', 'Browse for an app...', 'Pick an .exe or shortcut file', async () => {
        let p = null;
        try { p = await api.pickApp(); } catch (e) { warn(e); }
        if (!p || typeof p !== 'string') return;
        const ok = addFav({ name: baseName(p), path: p });
        N.toast(ok ? 'Added ' + baseName(p) : 'Already in Apps');
        setMode('grid');
      }),
      big('external', 'Add a website', 'Name and address, opens inside the notch', () => setMode('site'))));
  }

  function loadInstalled() {
    if (A.installed || A.loadingInst) return;
    A.loadingInst = true;
    let p; try { p = api.listApps(); } catch (e) { p = Promise.resolve([]); }
    Promise.resolve(p).then(l => { A.installed = Array.isArray(l) ? l.filter(x => x && typeof x.name === 'string' && typeof x.path === 'string') : []; })
      .catch(() => { A.installed = []; })
      .then(() => { A.loadingInst = false; if (A.mode === 'installed') renderApps(); });
  }

  function renderInstalled(g) {
    g.appendChild(backHeader('Installed apps'));
    const q = el('input', { type: 'text', placeholder: 'Search apps', spellcheck: 'false', style: { width: '100%', marginBottom: '6px', flex: 'none' } });
    q.value = A.filter;
    g.appendChild(q);
    const listEl = el('div', { class: 'scroll grow' });
    g.appendChild(listEl);
    const fill = () => {
      N.clear(listEl);
      if (!A.installed) { listEl.appendChild(el('div', { class: 'empty', text: 'Looking for installed apps...' })); return; }
      const f = A.filter.trim().toLowerCase();
      const have = new Set(getFavs().map(favKey));
      const rows = A.installed.filter(a => !f || a.name.toLowerCase().includes(f)).slice(0, 150);
      if (!rows.length) { listEl.appendChild(el('div', { class: 'empty', text: A.installed.length ? 'No apps match.' : "No installed apps were found. Use 'Browse for an app' instead." })); return; }
      rows.forEach(a => {
        const ic = el('div', { class: 'ic' }); appIcon(ic, a.name, a.path, 24);
        const added = have.has(favKey(a));
        listEl.appendChild(el('div', { class: 'nw-row', title: a.path, onclick: safe(() => {
          if (added) { N.toast('Already in Apps'); return; }
          addFav({ name: a.name, path: a.path }); N.toast('Added ' + a.name); setMode('grid');
        }) }, ic, el('div', { class: 'nm', text: a.name }), added ? el('span', { class: 'dim small', text: 'Added' }) : N.icon('plus', 14)));
      });
    };
    q.addEventListener('input', () => { A.filter = q.value; fill(); });
    q.addEventListener('focus', hold);
    fill(); loadInstalled();
    setTimeout(() => { try { q.focus(); } catch (e) { /* ignore */ } }, 30);
  }

  function renderSiteForm(g) {
    g.appendChild(backHeader('Add a website'));
    const name = el('input', { type: 'text', placeholder: 'e.g. Spotify', spellcheck: 'false', maxlength: '40' });
    const url = el('input', { type: 'text', placeholder: 'e.g. open.spotify.com', spellcheck: 'false' });
    const err = el('div', { class: 'nw-err' });
    const submit = safe(() => {
      const u = parseWebUrl(url.value);
      if (!u) { err.textContent = 'Enter a valid web address, like example.com'; url.focus(); return; }
      const nm = (name.value.trim() || hostOf(u) || 'Website').slice(0, 40);
      const ok = addFav({ name: nm, url: u });
      if (!ok) { err.textContent = 'That website is already in Apps.'; return; }
      N.toast('Added ' + nm); setMode('grid');
    });
    [name, url].forEach(i => { i.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); }); i.addEventListener('focus', hold); i.addEventListener('input', () => { err.textContent = ''; hold(); }); });
    g.appendChild(el('div', { class: 'nw-form' },
      el('label', null, 'Name (optional)', name), el('label', null, 'Web address', url), err,
      el('div', { class: 'row' }, el('button', { class: 'btn primary', onclick: submit }, 'Add website'), el('button', { class: 'btn', onclick: () => setMode('grid') }, 'Cancel'))));
    setTimeout(() => { try { name.focus(); } catch (e) { /* ignore */ } }, 30);
  }

  function renderAddr(g) {
    const it = getFavs().find(x => favKey(x) === A.target);
    if (!it) { A.mode = 'grid'; renderAppsGrid(g); return; }
    g.appendChild(backHeader('Open ' + it.name + ' inside the notch'));
    const url = el('input', { type: 'text', placeholder: 'e.g. app.example.com', spellcheck: 'false' });
    url.value = it.web || knownWeb(it.name) || '';
    const err = el('div', { class: 'nw-err' });
    const submit = safe(() => {
      const u = parseWebUrl(url.value);
      if (!u) { err.textContent = 'Enter a valid web address, like example.com'; url.focus(); return; }
      const list = getFavs(); const f = list.find(x => favKey(x) === favKey(it));
      if (f) { f.web = u; saveFavs(list); }
      A.viewer.drop(favKey(it));
      setMode('grid');
      A.viewer.open(favKey(it), it.name, u);
    });
    url.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
    url.addEventListener('focus', hold); url.addEventListener('input', () => { err.textContent = ''; hold(); });
    const btns = el('div', { class: 'row' }, el('button', { class: 'btn primary', onclick: submit }, 'Open'), el('button', { class: 'btn', onclick: () => setMode('grid') }, 'Cancel'));
    if (it.web) btns.appendChild(el('button', { class: 'btn', onclick: safe(() => {
      const list = getFavs(); const f = list.find(x => favKey(x) === favKey(it));
      if (f) { delete f.web; saveFavs(list); }
      A.viewer.drop(favKey(it)); setMode('grid');
    }) }, 'Use default'));
    g.appendChild(el('div', { class: 'nw-form' },
      el('div', { class: 'dim small', text: 'Type the web address of this app. It will open in a panel here, and keep running (music, chats) when the notch closes.' }),
      el('label', null, 'Web address', url), err, btns));
    setTimeout(() => { try { url.focus(); url.select(); } catch (e) { /* ignore */ } }, 30);
  }

  N.register({
    id: 'apps', name: 'Apps', icon: 'apps', size: [760, 470], keep: true,
    mount(root) {
      A.grid = el('div', { style: { display: 'flex', flexDirection: 'column', flex: '1', minHeight: '0' } });
      root.appendChild(A.grid);
      A.viewer = mkViewer({ pane: root, zoom: ZDEF, badge: true, backLabel: 'Apps', backTitle: 'Back to your apps' });
      viewers.push(A.viewer);
      renderApps();
    },
    show() { if (A.viewer) A.viewer.setPaneVisible(true); if (!A.viewer || !A.viewer.isOpen) renderApps(); },
    hide() { if (A.viewer) A.viewer.setPaneVisible(false); }
  });

  // ==================================================================== AI
  const PROVIDERS = [
    { id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com', color: '#10a37f', re: /chat\s?gpt/i },
    { id: 'claude', name: 'Claude', url: 'https://claude.ai', color: '#d97757', re: /\bclaude\b/i },
    { id: 'gemini', name: 'Gemini', url: 'https://gemini.google.com', color: '#4285f4', re: /\bgemini\b/i },
    { id: 'perplexity', name: 'Perplexity', url: 'https://www.perplexity.ai', color: '#20808d', re: /perplexity/i },
    { id: 'copilot', name: 'Copilot', url: 'https://copilot.microsoft.com', color: '#7a5af8', re: /\bcopilot\b/i, not: /github|visual studio|365/i },
    { id: 'grok', name: 'Grok', url: 'https://grok.com', color: '#3a3a40', re: /\bgrok\b/i },
    { id: 'deepseek', name: 'DeepSeek', url: 'https://chat.deepseek.com', color: '#4d6bfe', re: /deep\s?seek/i },
    { id: 'mistral', name: 'Le Chat', url: 'https://chat.mistral.ai', color: '#fa520f', re: /le chat|mistral/i },
    { id: 'poe', name: 'Poe', url: 'https://poe.com', color: '#5d5cde', re: /^poe$/i }
  ];
  const AI = { chooser: null, viewer: null, found: {}, scannedAt: 0, scanning: false, switched: false, veil: null, dragT: null };

  function scanAiApps() {
    if (AI.scanning || Date.now() - AI.scannedAt < 60000) return;
    AI.scanning = true;
    let p; try { p = api.listApps(); } catch (e) { p = Promise.resolve([]); }
    Promise.resolve(p).then(list => {
      const found = {};
      (Array.isArray(list) ? list : []).forEach(a => {
        if (!a || typeof a.name !== 'string' || typeof a.path !== 'string') return;
        const pr = PROVIDERS.find(x => !found[x.id] && x.re.test(a.name) && !(x.not && x.not.test(a.name)));
        if (pr) found[pr.id] = a;
      });
      AI.found = found;
    }).catch(() => {}).then(() => { AI.scanning = false; AI.scannedAt = Date.now(); renderChooser(); });
  }

  const getPick = () => { const p = N.get('aiPick', null); return p && typeof p === 'object' && PROVIDERS.some(x => x.id === p.id) ? p : null; };

  function openChat(pr) { AI.switched = false; AI.viewer.open('ai:' + pr.id, pr.name, pr.url); AI.veil.classList.add('armed'); focusChatSoon(); }

  function choose(pr, mode) {
    if (mode === 'app') {
      const a = AI.found[pr.id];
      if (!a) { mode = 'web'; }
      else {
        N.set('aiPick', { id: pr.id, mode: 'app', path: a.path }); renderChooser();
        settle(Promise.resolve(api.openPath(a.path)).then(r => { if (r) N.toast("Couldn't open " + pr.name); else N.toast('Opening ' + pr.name); }).catch(() => N.toast("Couldn't open " + pr.name)));
        return;
      }
    }
    N.set('aiPick', { id: pr.id, mode: 'web' });
    openChat(pr); renderChooser();
  }

  function renderChooser() {
    const c = AI.chooser; if (!c) return;
    try {
      N.clear(c);
      const pick = getPick();
      c.appendChild(el('div', { class: 'row', style: { marginBottom: '8px', flex: 'none' } },
        el('div', { class: 'h', text: 'Ask AI' }),
        el('div', { class: 'dim small grow', text: AI.scanning ? 'Looking for installed AI apps...' : 'Pick one. Drop a file or text onto the chat to send it.' })));
      const grid = el('div', { class: 'nw-ai scroll grow', style: { padding: '2px' } });
      PROVIDERS.forEach(pr => {
        const app = AI.found[pr.id];
        const btns = el('div', { class: 'btns' }, el('button', { class: 'btn', title: 'Chat on ' + pr.url.replace(/^https:\/\//, ''), onclick: safe(() => choose(pr, 'web')) }, 'Web'));
        if (app) btns.appendChild(el('button', { class: 'btn', title: 'Open the installed app', onclick: safe(() => choose(pr, 'app')) }, 'App'));
        grid.appendChild(el('div', { class: 'nw-card' + (pick && pick.id === pr.id ? ' last' : '') }, letterTile(pr.name, 40, pr.color), el('div', { class: 'nm', text: pr.name }), btns));
      });
      c.appendChild(grid);
    } catch (e) { warn(e); }
  }

  // ---- inserting dropped content into the page's message box
  function buildInsertJs(text) {
    return '(function(t){try{' +
      'var sels=["#prompt-textarea","div.ProseMirror[contenteditable=true]","div[contenteditable=true][role=textbox]","rich-textarea div[contenteditable=true]","textarea","div[contenteditable=true]","input[type=text]"];' +
      'var el=null;for(var i=0;i<sels.length&&!el;i++){var l=document.querySelectorAll(sels[i]);for(var j=0;j<l.length;j++){var r=l[j].getBoundingClientRect();if(r.width>0&&r.height>0){el=l[j];break;}}}' +
      'if(!el)return "nofield";' +
      'el.focus();' +
      'var ok=false;try{ok=document.execCommand("insertText",false,t);}catch(e){ok=false;}' +
      'if(!ok){if(el.isContentEditable){el.textContent=(el.textContent||"")+t;}else{var p=Object.getPrototypeOf(el);var d=Object.getOwnPropertyDescriptor(p,"value");var v=(el.value||"")+t;if(d&&d.set){d.set.call(el,v);}else{el.value=v;}}' +
      'el.dispatchEvent(new Event("input",{bubbles:true}));}' +
      'return "ok";}catch(e){return "error";}})(' + JSON.stringify(String(text)) + ')';
  }
  const FOCUS_JS = '(function(){try{var sels=["#prompt-textarea","div.ProseMirror[contenteditable=true]","div[contenteditable=true][role=textbox]","rich-textarea div[contenteditable=true]","textarea","div[contenteditable=true]"];for(var i=0;i<sels.length;i++){var l=document.querySelectorAll(sels[i]);for(var j=0;j<l.length;j++){var r=l[j].getBoundingClientRect();if(r.width>0&&r.height>0){l[j].focus();return "ok";}}}return "nofield";}catch(e){return "error";}})()';

  function focusChatSoon() {
    [0, 700, 2000, 4000].forEach(ms => setTimeout(() => {
      try {
        const V = AI.viewer && AI.viewer.isOpen ? AI.viewer.activeView() : null;
        if (!V || !V.ready) return;
        V.focusPage();
        settle(V.exec(FOCUS_JS));
      } catch (e) { warn(e); }
    }, ms));
  }

  function insertIntoChat(text) {
    const V = AI.viewer.activeView();
    if (!V || !V.ready) { N.toast('The chat is still loading. Try again in a moment.'); return; }
    hold();
    V.exec(buildInsertJs(text)).then(r => {
      if (r === 'ok') N.toast('Added to the chat');
      else { settle(api.clipWriteText(text)); N.toast("Couldn't find the message box. Copied to your clipboard instead."); }
    }).catch(() => N.toast("Couldn't add that to the chat"));
  }

  async function handleDrop(files, plain) {
    try {
      if (files.length) {
        const parts = []; let bad = 0, big = 0;
        for (const f of files.slice(0, 5)) {
          const p = api.pathForFile(f);
          let r = null;
          if (p) { try { r = await api.readTextFile(p); } catch (e) { r = null; } }
          if (r && r.ok && typeof r.text === 'string') parts.push('File: ' + (f.name || 'file') + '\n```\n' + r.text + '\n```');
          else if (r && r.reason === 'size') big++;
          else bad++;
        }
        if (parts.length) { insertIntoChat(parts.join('\n\n') + '\n'); if (bad || big) N.toast('Some files were skipped (only small text or code files can be dropped)', 3200); return; }
        N.toast(big ? 'That file is too big to drop (300 KB max)' : 'Only text and code files can be dropped here', 3000);
        return;
      }
      if (plain && plain.trim()) { insertIntoChat(plain); return; }
      N.toast('Nothing to drop. Try a text file or some selected text.');
    } catch (e) { warn(e); N.toast("Couldn't add that to the chat"); }
  }

  function setDragging(on) {
    try {
      document.body.classList.toggle('dragging', !!on);
      clearTimeout(AI.dragT);
      if (on) AI.dragT = setTimeout(() => document.body.classList.remove('dragging'), 700);
    } catch (e) { /* ignore */ }
  }
  const canDrop = () => !!(AI.viewer && AI.viewer.isOpen && AI.viewer.activeView() && N.cur && N.cur.id === 'ai');

  function wireDrop(pane) {
    const hasData = e => { const t = e.dataTransfer && e.dataTransfer.types ? Array.from(e.dataTransfer.types) : []; return t.includes('Files') || t.includes('text/plain'); };
    const over = e => {
      try {
        if (!hasData(e)) return;
        e.preventDefault(); hold();
        if (canDrop()) setDragging(true);
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
      } catch (err) { warn(err); }
    };
    pane.addEventListener('dragenter', over);
    pane.addEventListener('dragover', over);
    pane.addEventListener('dragleave', e => { try { if (!e.relatedTarget) setDragging(false); } catch (err) { /* ignore */ } });
    pane.addEventListener('drop', e => {
      try {
        e.preventDefault(); setDragging(false);
        if (!canDrop()) { N.toast('Open a chat first, then drop onto it'); return; }
        const dt = e.dataTransfer; if (!dt) return;
        const files = Array.from(dt.files || []);
        const plain = files.length ? '' : (dt.getData('text/plain') || '');
        handleDrop(files, plain);
      } catch (err) { warn(err); }
    });
    window.addEventListener('dragend', () => setDragging(false));
  }

  N.register({
    id: 'ai', name: 'Ask AI', icon: 'ai', size: [760, 470], keep: true,
    mount(root) {
      AI.chooser = el('div', { style: { display: 'flex', flexDirection: 'column', flex: '1', minHeight: '0' } });
      root.appendChild(AI.chooser);
      AI.viewer = mkViewer({
        pane: root, zoom: AI_ZOOM, badge: false, backLabel: 'Switch', backTitle: 'Choose a different AI',
        onClose() { AI.switched = true; renderChooser(); }
      });
      viewers.push(AI.viewer);
      AI.veil = el('div', { class: 'dropveil' }, el('div', { class: 'nw-veiltxt', text: 'Drop a text or code file, or selected text, to add it to the chat' }));
      AI.veil.addEventListener('dragover', e => { try { e.preventDefault(); if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'; setDragging(true); } catch (err) { /* ignore */ } });
      AI.viewer.stage.appendChild(AI.veil);
      wireDrop(root);
      renderChooser();
    },
    show() {
      if (!AI.viewer) return;
      renderChooser();
      scanAiApps();
      AI.viewer.setPaneVisible(true);
      const pick = getPick();
      if (pick && pick.mode === 'web' && !AI.viewer.isOpen && !AI.switched) {
        const pr = PROVIDERS.find(x => x.id === pick.id);
        if (pr) openChat(pr);
      } else if (AI.viewer.isOpen) focusChatSoon();
      AI.veil.classList.toggle('armed', AI.viewer.isOpen);
    },
    hide() {
      setDragging(false);
      if (AI.viewer) AI.viewer.setPaneVisible(false);
    }
  });

  try {
    api.on('focus-ai', () => {
      try {
        if (!AI.viewer) return;
        const pick = getPick();
        if (pick && pick.mode === 'app' && pick.path) { settle(api.openPath(pick.path)); return; }
        if (AI.viewer.isOpen) { focusChatSoon(); return; }
        if (pick && pick.mode === 'web' && N.cur && N.cur.id === 'ai') {
          const pr = PROVIDERS.find(x => x.id === pick.id);
          if (pr) openChat(pr);
        }
      } catch (e) { warn(e); }
    });
  } catch (e) { warn(e); }

  // ==================================================================== BROWSER
  const HOME_LINKS = [
    ['DuckDuckGo', 'https://duckduckgo.com'], ['Wikipedia', 'https://www.wikipedia.org'], ['YouTube', 'https://www.youtube.com'],
    ['GitHub', 'https://github.com'], ['Reddit', 'https://www.reddit.com'], ['BBC News', 'https://www.bbc.com/news']
  ];
  const B = { V: null, zoom: ZDEF, ui: null };

  function bSync() {
    const u = B.ui; if (!u) return;
    const V = B.V && !B.V.dead ? B.V : null;
    u.back.disabled = !(V && V.canBack); u.fwd.disabled = !(V && V.canFwd); u.rel.disabled = !V;
    u.zoom.update(V ? V.zoom : B.zoom);
    u.home.style.display = V ? 'none' : 'flex';
    if (document.activeElement !== u.input) u.input.value = V ? (V.url || '') : '';
  }
  function bGo(text) {
    const u = B.ui; if (!u) return;
    const r = resolveInput(text);
    if (!r.ok) {
      if (r.reason === 'scheme') N.toast('Only http and https addresses can be opened');
      else if (r.reason === 'bad') N.toast("That address doesn't look right");
      return;
    }
    if (!B.V || B.V.dead) {
      const V = mkView({ url: r.url, zoom: B.zoom, onState: v => { B.zoom = v.zoom; bSync(); } });
      if (!V) { N.toast('The browser is unavailable right now'); return; }
      B.V = V; u.stage.appendChild(V.box);
    } else B.V.go(r.url);
    try { u.input.blur(); } catch (e) { /* ignore */ }
    bSync();
  }
  function bReset() {
    if (B.V) { B.V.destroy(); B.V = null; }
    B.zoom = ZDEF;
    if (B.ui) { B.ui.input.value = ''; bSync(); }
  }

  N.register({
    id: 'browser', name: 'Browser', icon: 'browser', size: [760, 470],
    mount(root) {
      const input = el('input', { type: 'text', class: 'nw-url', placeholder: 'Search or enter a web address', spellcheck: 'false', autocomplete: 'off' });
      input.addEventListener('keydown', e => { try { hold(); if (e.key === 'Enter') bGo(input.value); else if (e.key === 'Escape') { input.value = B.V ? B.V.url : ''; input.blur(); } } catch (err) { warn(err); } });
      input.addEventListener('focus', () => { hold(); try { input.select(); } catch (e) { /* ignore */ } });
      const back = el('button', { class: 'btn icon', title: 'Back', onclick: () => { if (B.V) B.V.back(); } }, N.icon('nwLeft', 14));
      const fwd = el('button', { class: 'btn icon', title: 'Forward', onclick: () => { if (B.V) B.V.fwd(); } }, N.icon('nwRight', 14));
      const rel = el('button', { class: 'btn icon', title: 'Reload', onclick: () => { if (B.V) B.V.reload(); } }, N.icon('reload', 14));
      const zoom = mkZoomCtl(d => {
        B.zoom = d === 0 ? ZDEF : clampZoom(B.zoom + d);
        if (B.V && !B.V.dead) B.V.setZoom(B.zoom);
        bSync();
      }, ZDEF);
      const quick = el('div', { class: 'nw-quick' }, HOME_LINKS.map(([n, u]) => el('button', { class: 'nw-q', onclick: () => bGo(u) }, letterTile(n, 34), n)));
      const home = el('div', { class: 'nw-home' }, el('div', { class: 'big', text: 'Browse the web' }),
        el('div', { class: 'dim', text: 'Search or type an address above. This page clears each time the notch closes.' }), quick);
      const stage = el('div', { class: 'nw-stage' }, home);
      root.appendChild(el('div', { class: 'nw-bar' }, back, fwd, rel, input, zoom.root));
      root.appendChild(stage);
      B.ui = { input, back, fwd, rel, zoom, home, stage };
      bSync();
    },
    show() { bSync(); },
    hide() { if (!N.open) bReset(); }
  });
  // also clear when the notch closes while another tab is showing
  try { api.on('close', () => { try { bReset(); } catch (e) { warn(e); } }); } catch (e) { warn(e); }
})();
