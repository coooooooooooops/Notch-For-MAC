'use strict';
// NOTCH for Windows - core: helpers, tab registry, open/close animation, top bar, live pill.
(function () {
  const api = window.notch;
  const N = window.N = { api, tabs: [], byId: {}, open: false, cur: null, liveItems: {}, mounted: {} };

  // ------------------------------------------------------------------ config
  N.cfg = api.cfgAll();
  N.get = (k, d) => (N.cfg[k] === undefined || N.cfg[k] === null ? d : N.cfg[k]);
  N.set = (k, v) => { N.cfg[k] = v; api.cfgSet(k, v); };
  N.version = N.cfg.__version || '1.0.0';

  // ------------------------------------------------------------------ small DOM helpers
  N.el = function (tag, props, ...kids) {
    const e = document.createElement(tag);
    if (props) {
      for (const k of Object.keys(props)) {
        const v = props[k];
        if (v === undefined || v === null || v === false) continue;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k === 'style' && typeof v === 'object') Object.assign(e.style, v);
        else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2).toLowerCase(), v);
        else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') e[k] = v;
        else e.setAttribute(k, v === true ? '' : String(v));
      }
    }
    for (const kid of kids.flat(Infinity)) {
      if (kid === null || kid === undefined || kid === false) continue;
      e.appendChild(typeof kid === 'string' || typeof kid === 'number' ? document.createTextNode(String(kid)) : kid);
    }
    return e;
  };
  const el = N.el;
  N.clear = e => { while (e.firstChild) e.removeChild(e.firstChild); return e; };

  const IC = {
    music: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
    shelf: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    clip: '<rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>',
    timers: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M9 2h6"/>',
    notes: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h5"/>',
    apps: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
    ai: '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
    browser: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    camera: '<path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>',
    calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    system: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
    control: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
    weather: '<path d="M12 2v2M4.9 4.9l1.4 1.4M2 12h2M20 12h2M17.7 6.3l1.4-1.4"/><path d="M16 12a4 4 0 0 0-7.7-1.5A4.5 4.5 0 1 0 8.5 19H17a3.5 3.5 0 0 0-1-7z"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    updater: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
    play: '<path d="M6 4l14 8-14 8z" fill="currentColor"/>',
    pause: '<rect x="6" y="4" width="4" height="16" fill="currentColor"/><rect x="14" y="4" width="4" height="16" fill="currentColor"/>',
    next: '<path d="M5 4l10 8-10 8z" fill="currentColor"/><path d="M19 5v14"/>',
    prev: '<path d="M19 4L9 12l10 8z" fill="currentColor"/><path d="M5 5v14"/>',
    plus: '<path d="M12 5v14M5 12h14"/>', minus: '<path d="M5 12h14"/>',
    trash: '<path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6"/>',
    pin: '<path d="M12 17v5M9 10.8a2 2 0 0 1-1.1 1.8l-1.8.9A2 2 0 0 0 5 15.2V17h14v-1.8a2 2 0 0 0-1.1-1.8l-1.8-.9a2 2 0 0 1-1.1-1.8V6a3 3 0 0 0 1-2H8a3 3 0 0 0 1 2z"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
    x: '<path d="M18 6L6 18M6 6l12 12"/>',
    left: '<path d="M15 18l-6-6 6-6"/>', right: '<path d="M9 18l6-6-6-6"/>', up: '<path d="M18 15l-6-6-6 6"/>', down: '<path d="M6 9l6 6 6-6"/>',
    eye: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z"/><circle cx="12" cy="12" r="3"/>',
    eyeoff: '<path d="M17.9 17.9A10.9 10.9 0 0 1 12 20C5 20 1 12 1 12a18 18 0 0 1 5.1-5.9M9.9 4.2A9.1 9.1 0 0 1 12 4c7 0 11 8 11 8a18 18 0 0 1-2.2 3.2M1 1l22 22"/>',
    reload: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
    copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    folder: '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
    check: '<path d="M20 6L9 17l-5-5"/>',
    wifi: '<path d="M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 20h.01M2 9a15 15 0 0 1 20 0"/>',
    bt: '<path d="M6.5 6.5l11 11L12 23V1l5.5 5.5-11 11"/>',
    moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    volume: '<path d="M11 5L6 9H2v6h4l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    mute: '<path d="M11 5L6 9H2v6h4l5 4zM23 9l-6 6M17 9l6 6"/>',
    shot: '<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/><rect x="7" y="7" width="10" height="10" rx="1"/>',
    power: '<path d="M18.4 6.6a9 9 0 1 1-12.8 0M12 2v10"/>',
    external: '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
    mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M19 10a7 7 0 0 1-14 0M12 19v3"/>',
    zoomin: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3M11 8v6M8 11h6"/>',
    zoomout: '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3M8 11h6"/>'
  };
  N.icons = IC;
  N.icon = function (name, size, sw) {
    const s = el('span', { style: { display: 'inline-grid', placeItems: 'center', lineHeight: 0 } });
    s.innerHTML = '<svg width="' + (size || 16) + '" height="' + (size || 16) + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + (sw || 2) + '" stroke-linecap="round" stroke-linejoin="round">' + (IC[name] || '') + '</svg>';
    return s;
  };

  let toastT = null;
  N.toast = function (msg, ms) {
    const t = document.getElementById('toast');
    t.textContent = msg; t.classList.add('show');
    clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('show'), ms || 2200);
  };

  N.debounce = (fn, ms) => { let t = null; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
  N.pad = n => String(n).padStart(2, '0');
  N.mmss = s => { s = Math.max(0, Math.floor(s)); return N.pad(Math.floor(s / 60)) + ':' + N.pad(s % 60); };
  N.dayKey = (d) => { d = d || new Date(); return d.getFullYear() + '-' + N.pad(d.getMonth() + 1) + '-' + N.pad(d.getDate()); };

  // right-click / context menu
  let menuEl = null;
  N.closeMenu = () => { if (menuEl) { menuEl.remove(); menuEl = null; } };
  N.menu = function (ev, items) {
    N.closeMenu();
    ev.preventDefault(); ev.stopPropagation();
    menuEl = el('div', { class: 'ctxmenu' }, items.map(it => el('div', { class: it.danger ? 'danger' : '', text: it.label, onclick: e => { e.stopPropagation(); N.closeMenu(); it.fn(); } })));
    document.body.appendChild(menuEl);
    const r = menuEl.getBoundingClientRect();
    menuEl.style.left = Math.max(4, Math.min(ev.clientX, window.innerWidth - r.width - 4)) + 'px';
    menuEl.style.top = Math.max(4, Math.min(ev.clientY, window.innerHeight - r.height - 4)) + 'px';
  };
  document.addEventListener('click', () => N.closeMenu());
  window.addEventListener('blur', () => N.closeMenu());

  // ------------------------------------------------------------------ sounds
  let actx = null;
  N.chime = function () {
    try {
      actx = actx || new (window.AudioContext || window.webkitAudioContext)();
      const t0 = actx.currentTime;
      [[880, 0], [1175, 0.18], [1568, 0.36]].forEach(([f, d]) => {
        const o = actx.createOscillator(), g = actx.createGain();
        o.type = 'sine'; o.frequency.value = f;
        g.gain.setValueAtTime(0.0001, t0 + d);
        g.gain.exponentialRampToValueAtTime(0.25, t0 + d + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + d + 0.5);
        o.connect(g); g.connect(actx.destination);
        o.start(t0 + d); o.stop(t0 + d + 0.55);
      });
    } catch (e) { /* no audio device */ }
  };
  N.wobble = function () {
    const n = document.getElementById('notch');
    n.classList.remove('wobble'); void n.offsetWidth; n.classList.add('wobble');
    setTimeout(() => n.classList.remove('wobble'), 800);
  };

  // ------------------------------------------------------------------ appearance
  N.colors = { white: '#ffffff', green: '#30d158', cyan: '#64d2ff', pink: '#ff6482', orange: '#ff9f0a', yellow: '#ffd60a', purple: '#bf5af2', red: '#ff453a' };
  N.fonts = {
    default: '"Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
    rounded: '"Arial Rounded MT Bold", "Nirmala UI", "Segoe UI", sans-serif',
    serif: 'Georgia, "Times New Roman", serif',
    mono: 'Consolas, "Cascadia Mono", monospace'
  };
  N.accent = () => N.colors[N.get('accent', 'green')] || N.colors.green;
  N.applyAppearance = function () {
    const r = document.documentElement.style;
    r.setProperty('--accent', N.accent());
    r.setProperty('--clock', N.colors[N.get('clockColor', 'white')] || '#fff');
    r.setProperty('--radius', N.get('round', 26) + 'px');
    r.setProperty('--font', N.fonts[N.get('font', 'default')] || N.fonts.default);
    document.body.classList.remove('idle-bar', 'idle-notch', 'idle-hidden');
    document.body.classList.add('idle-' + N.get('idleStyle', 'bar'));
    N.updatePill(true);
  };

  // ------------------------------------------------------------------ tab registry
  N.register = function (t) { N.tabs.push(t); N.byId[t.id] = t; };
  N.orderedTabs = function () {
    const saved = N.get('tabsOrder', []);
    const ids = N.tabs.map(t => t.id);
    const order = saved.filter(i => ids.includes(i)).concat(ids.filter(i => !saved.includes(i)));
    return order.map(i => N.byId[i]);
  };
  N.visibleTabs = function () {
    const hidden = N.get('tabsHidden', []);
    const v = N.orderedTabs().filter(t => !hidden.includes(t.id));
    return v.length ? v : [N.orderedTabs()[0]];
  };

  const $notch = () => document.getElementById('notch');
  const $panel = () => document.getElementById('panel');

  N.renderTabs = function () {
    const box = N.clear(document.getElementById('tabs'));
    N.visibleTabs().forEach(t => {
      const b = el('button', { class: 'tab-btn' + (N.cur === t ? ' active' : ''), title: t.name, 'data-tab': t.id, onclick: () => N.select(t.id) }, N.icon(t.icon || t.id, 16));
      if (t.badge && t.badge()) b.appendChild(el('span', { class: 'dot' }));
      box.appendChild(b);
    });
  };
  document.getElementById('tabs').addEventListener('contextmenu', e => {
    N.menu(e, [{ label: 'Customise tabs...', fn: () => { N.select('settings'); if (N.byId.settings.showCustomise) N.byId.settings.showCustomise(); } }]);
  });

  N.tabSize = function () {
    const t = N.cur;
    let s = t && (typeof t.size === 'function' ? t.size() : t.size);
    if (!s) s = [700, 220];
    return [Math.max(420, Math.min(880, s[0])), Math.max(120, Math.min(540, s[1]))];
  };

  let lastCollapsed = '';
  N.applySize = function () {
    const n = $notch();
    if (N.open) {
      const [w, h] = N.tabSize();
      $panel().style.setProperty('--pw', w + 'px'); $panel().style.setProperty('--ph', h + 'px');
      n.style.width = w + 'px'; n.style.height = h + 'px';
      api.panelSize(w, h);
    } else {
      const [w, h] = N.collapsedSize();
      n.style.width = w + 'px'; n.style.height = h + 'px';
    }
  };
  N.resize = () => { if (N.open) N.applySize(); };

  N.select = function (id, quiet) {
    const t = N.byId[id];
    if (!t) return;
    if (N.cur && N.cur !== t) { try { N.cur.hide && N.cur.hide(); } catch (e) { console.error(e); } const old = N.mounted[N.cur.id]; if (old) old.classList.remove('show'); }
    N.cur = t;
    let pane = N.mounted[id];
    if (!pane) {
      pane = el('div', { class: 'pane' + (t.keep ? ' keep' : ''), 'data-pane': id });
      document.getElementById('content').appendChild(pane);
      N.mounted[id] = pane;
      try { t.mount(pane); } catch (e) { console.error('mount ' + id, e); pane.appendChild(el('div', { class: 'empty err', text: 'This tab failed to load.' })); }
    }
    pane.classList.add('show');
    try { t.show && t.show(); } catch (e) { console.error('show ' + id, e); }
    N.renderTabs();
    N.applySize();
  };

  // ------------------------------------------------------------------ open / close
  let ackT = null;
  N.openUI = function (p) {
    p = p || {};
    clearTimeout(ackT);
    const wasOpen = N.open;
    N.open = true;
    $notch().classList.add('open');
    const vis = N.visibleTabs();
    const target = p.goto && N.byId[p.goto] ? p.goto : (wasOpen && N.cur ? N.cur.id : vis[0].id);
    if (!wasOpen && N.cur) { try { N.cur.hide && N.cur.hide(); } catch (e) { /* ignore */ } const old = N.mounted[N.cur.id]; if (old) old.classList.remove('show'); N.cur = null; }
    N.select(target);
  };
  N.closeUI = function () {
    if (!N.open) { api.collapsedAck(); return; }
    N.open = false;
    $notch().classList.remove('open');
    N.closeMenu();
    if (N.cur) { try { N.cur.hide && N.cur.hide(); } catch (e) { /* ignore */ } }
    N.applySize();
    clearTimeout(ackT);
    ackT = setTimeout(() => api.collapsedAck(), 330);
  };
  N.requestClose = () => api.closeRequest();

  // ------------------------------------------------------------------ collapsed pill + live activities
  // tabs call N.live(key, null | {prio, left:'text', icon:'name', right:'text'})
  N.live = function (key, item) {
    if (item) N.liveItems[key] = item; else delete N.liveItems[key];
    N.updatePill();
  };
  let pillSig = '';
  N.collapsedSize = function () {
    const live = Object.values(N.liveItems).sort((a, b) => b.prio - a.prio)[0];
    const style = N.get('idleStyle', 'bar');
    if (live) return [N.get('pillWidth', 250), 30];
    if (style === 'notch') return [190, 30];
    if (style === 'hidden') return [140, 4];
    return [120, 7];
  };
  N.updatePill = function (force) {
    const items = Object.values(N.liveItems).sort((a, b) => b.prio - a.prio);
    const live = items[0];
    const n = $notch();
    n.classList.toggle('live', !!live);
    const L = document.getElementById('pillL'), R = document.getElementById('pillR');
    const sig = live ? [live.icon, live.left, live.right, live.bars].join('|') : '';
    if (sig !== pillSig || force) {
      pillSig = sig;
      N.clear(L); N.clear(R);
      if (live) {
        if (live.bars) { const b = el('span', { class: 'bars on' }, [0, 1, 2, 3].map(() => el('i'))); L.appendChild(b); }
        else if (live.icon) { const i = N.icon(live.icon, 14); i.style.color = 'var(--accent)'; L.appendChild(i); }
        if (live.left) L.appendChild(el('span', { text: live.left, style: { maxWidth: '120px', overflow: 'hidden', textOverflow: 'ellipsis' } }));
        if (live.right) R.appendChild(el('span', { text: live.right }));
      }
    }
    const [w, h] = N.collapsedSize();
    const key = w + 'x' + h;
    if (key !== lastCollapsed || force) { lastCollapsed = key; api.collapsedSize(w, h); }
    if (!N.open) N.applySize();
  };
  document.getElementById('notch').addEventListener('click', () => { if (!N.open) api.openRequest(); });

  // ------------------------------------------------------------------ top bar: clock + battery
  function tickClock() {
    const d = new Date();
    document.getElementById('clockT').textContent = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    document.getElementById('clockD').textContent = d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });
  }
  document.getElementById('clock').addEventListener('contextmenu', e => {
    const names = Object.keys(N.colors);
    N.menu(e, names.map(n => ({ label: 'Clock: ' + n, fn: () => { N.set('clockColor', n); N.applyAppearance(); } })));
  });
  function drawBattery(b) {
    const pct = Math.round(b.level * 100);
    const box = N.clear(document.getElementById('battIcon'));
    const cls = 'bat' + (b.charging ? ' chg' : pct <= 20 ? ' low' : '');
    box.appendChild(el('span', { class: cls }, el('i', { style: { width: Math.max(8, pct) + '%' } })));
    document.getElementById('battTxt').textContent = pct + '%';
    N.battery = { pct, charging: b.charging };
  }
  N.initTop = function () {
    tickClock(); setInterval(tickClock, 1000);
    try {
      if (navigator.getBattery) {
        navigator.getBattery().then(b => {
          const upd = () => drawBattery(b);
          upd(); ['levelchange', 'chargingchange'].forEach(ev => b.addEventListener(ev, upd));
        }).catch(() => {});
      }
    } catch (e) { /* desktop PC: no battery */ }
  };

  // ------------------------------------------------------------------ Esc closes; events from main
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && N.open) { N.closeMenu(); api.closeRequest(); } });
  api.on('open', p => N.openUI(p));
  api.on('close', () => N.closeUI());
  api.on('cfg-changed', p => { if (p && p.key) { N.cfg[p.key] = p.value; if (p.key === 'clickMode' && N.cfg.__onClickMode) N.cfg.__onClickMode(); } });
})();
