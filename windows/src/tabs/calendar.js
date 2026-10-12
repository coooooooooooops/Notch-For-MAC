'use strict';
// Calendar: month grid + list of your own events / reminders (stored with N.get('calEvents')).
(function () {
  const N = window.N, el = N.el;

  // <pure>
  const pad2 = n => String(n).padStart(2, '0');
  const ymd = (y, m, d) => y + '-' + pad2(m + 1) + '-' + pad2(d); // m is 0-based
  const KEY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
  const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
  function parseKey(s) {
    const m = KEY_RE.exec(typeof s === 'string' ? s : '');
    if (!m) return null;
    const y = +m[1], mo = +m[2] - 1, d = +m[3];
    if (mo < 0 || mo > 11 || d < 1 || d > daysInMonth(y, mo)) return null;
    return { y, m: mo, d };
  }
  const daysInMonth = (y, m) => new Date(y, m + 1, 0).getDate();
  function dateOf(key) { const p = parseKey(key); return p ? new Date(p.y, p.m, p.d) : null; } // local midnight
  function keyOfDate(dt) { return ymd(dt.getFullYear(), dt.getMonth(), dt.getDate()); }
  function addDays(key, n) { const p = parseKey(key); if (!p) return key; return keyOfDate(new Date(p.y, p.m, p.d + n)); }
  // 42 cells (6 weeks) for the month; weekStart 'mon' or 'sun'
  function monthCells(y, m, weekStart) {
    const first = new Date(y, m, 1).getDay(); // 0=Sun
    const offset = (first - (weekStart === 'sun' ? 0 : 1) + 7) % 7;
    const out = [];
    for (let i = 0; i < 42; i++) {
      const dt = new Date(y, m, 1 - offset + i);
      out.push({ y: dt.getFullYear(), m: dt.getMonth(), d: dt.getDate(), key: keyOfDate(dt), other: dt.getMonth() !== m });
    }
    return out;
  }
  function cmpEv(a, b) {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    if (a.time !== b.time) return a.time < b.time ? -1 : 1; // '' (all day) first
    return a.title < b.title ? -1 : a.title > b.title ? 1 : 0;
  }
  function sanitizeEvents(arr) {
    if (!Array.isArray(arr)) return [];
    const seen = new Set(), out = [];
    arr.forEach((e, i) => {
      if (!e || typeof e !== 'object' || !parseKey(e.date)) return;
      const title = typeof e.title === 'string' ? e.title.trim().slice(0, 200) : '';
      if (!title) return;
      let id = typeof e.id === 'string' && e.id ? e.id : 'e' + i + '_' + Math.random().toString(36).slice(2, 8);
      while (seen.has(id)) id += 'x';
      seen.add(id);
      out.push({ id, date: e.date, time: typeof e.time === 'string' && TIME_RE.test(e.time) ? e.time : '', title, done: e.done === true, color: typeof e.color === 'string' && /^#[0-9a-f]{6}$/i.test(e.color) ? e.color : '#ff9f0a' });
    });
    return out.slice(0, 3000);
  }
  // minutes from now until the event starts (null when it has no time)
  function minsUntil(ev, now) {
    if (!ev.time) return null;
    const p = parseKey(ev.date); if (!p) return null;
    const start = new Date(p.y, p.m, p.d, +ev.time.slice(0, 2), +ev.time.slice(3, 5));
    return (start.getTime() - now.getTime()) / 60000;
  }
  // </pure>
  N.__calTest = { ymd, parseKey, daysInMonth, addDays, monthCells, sanitizeEvents, cmpEv, minsUntil, keyOfDate };

  const st = document.createElement('style');
  st.textContent = [
    '.cal-wrap { display: flex; gap: 10px; height: 100%; min-height: 0; }',
    '.cal-left { width: 332px; flex: none; display: flex; flex-direction: column; min-height: 0; }',
    '.cal-right { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; min-height: 0; }',
    '.cal-head { display: flex; align-items: center; gap: 4px; margin-bottom: 4px; flex: none; }',
    '.cal-month { flex: 1; text-align: center; font-weight: 700; font-size: 14px; cursor: pointer; border-radius: 8px; padding: 3px 0; white-space: nowrap; }',
    '.cal-month:hover { background: var(--faint); }',
    '.cal-left .cal { flex: 1; min-height: 0; grid-template-rows: auto repeat(6, 1fr); }',
    '.cal-left .cal .d { display: grid; place-items: center; padding: 0; font-size: 12px; }',
    '.cal-left .cal .d.today.sel { outline: 2px solid #fff; outline-offset: -2px; }',
    '.cal-list { flex: 1; min-height: 0; overflow: auto; padding-right: 2px; }',
    '.cal-gh { font-size: 11px; font-weight: 700; color: var(--dim); margin: 6px 0 3px; cursor: pointer; }',
    '.cal-gh:first-child { margin-top: 0; }',
    '.cal-gh.sel { color: var(--accent); }',
    '.cal-ev { display: flex; align-items: center; gap: 7px; padding: 4px 6px; border-radius: 8px; min-height: 26px; }',
    '.cal-ev:hover { background: var(--faint); }',
    '.cal-ev .tt { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }',
    '.cal-ev.done .tt { text-decoration: line-through; opacity: .5; }',
    '.cal-ev .tm { font-size: 11px; color: var(--dim); font-variant-numeric: tabular-nums; flex: none; }',
    '.cal-chk { width: 16px; height: 16px; border-radius: 50%; border: 2px solid var(--dim); background: transparent; padding: 0; cursor: pointer; flex: none; display: grid; place-items: center; color: #000; }',
    '.cal-chk.on { background: var(--accent); border-color: var(--accent); }',
    '.cal-x { border: 0; background: transparent; color: var(--dim); cursor: pointer; padding: 2px; border-radius: 6px; display: grid; place-items: center; opacity: 0; }',
    '.cal-ev:hover .cal-x { opacity: 1; } .cal-x:hover { color: #ff8a80; background: var(--faint); }',
    '.cal-sec { display: flex; flex-direction: column; min-height: 0; padding: 8px 8px 6px; }',
    '.cal-sec .ttl { font-size: 11px; font-weight: 700; color: var(--dim); margin: 0 0 4px 4px; flex: none; text-transform: none; }',
    '.cal-form { display: flex; gap: 5px; margin-bottom: 4px; flex: none; }',
    '.cal-form input[type=text] { flex: 1; min-width: 0; padding: 5px 8px; }',
    '.cal-form input[type=time] { width: 92px; padding: 4px 6px; background: rgba(255,255,255,.1); border: 1px solid transparent; border-radius: 9px; color: #fff; font: inherit; outline: none; color-scheme: dark; }',
    '.cal-form input[type=time]:focus { border-color: var(--accent); }',
    '.cal-empty { color: var(--dim); font-size: 12px; padding: 6px 6px; }',
    '.cal-rd { font-size: 10.5px; color: var(--dim); flex: none; min-width: 44px; }'
  ].join('\n');
  document.head.appendChild(st);

  let events = sanitizeEvents(N.get('calEvents', []));
  const today = () => keyOfDate(new Date());
  const t0 = new Date();
  let viewY = t0.getFullYear(), viewM = t0.getMonth(), sel = today(), lastToday = today();
  let mode = N.get('calView', 'month') === 'list' ? 'list' : 'month';
  let ui = null;

  function save() { N.set('calEvents', events); }
  const weekStart = () => N.get('weekStart', 'mon') === 'sun' ? 'sun' : 'mon';
  const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);

  function fmtTime(t) {
    try { return new Date(2000, 0, 1, +t.slice(0, 2), +t.slice(3, 5)).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); } catch (e) { return t; }
  }
  function fmtDay(key, withYear) {
    const dt = dateOf(key); if (!dt) return key;
    try { return dt.toLocaleDateString([], withYear ? { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' } : { weekday: 'short', day: 'numeric', month: 'short' }); } catch (e) { return key; }
  }
  function fmtMonth() {
    try { return new Date(viewY, viewM, 1).toLocaleDateString([], { month: 'long', year: 'numeric' }); } catch (e) { return (viewM + 1) + '/' + viewY; }
  }
  const byDay = key => events.filter(e => e.date === key).sort(cmpEv);

  function setMonth(y, m) {
    while (m < 0) { m += 12; y--; } while (m > 11) { m -= 12; y++; }
    viewY = Math.max(1900, Math.min(2200, y)); viewM = m;
    renderLeft();
  }
  function goToday() { const p = parseKey(today()); viewY = p.y; viewM = p.m; sel = today(); renderAll(); }
  function selectDay(key) {
    const p = parseKey(key); if (!p) return;
    sel = key;
    if (p.y !== viewY || p.m !== viewM) { viewY = p.y; viewM = p.m; }
    renderAll();
  }

  function addEvent() {
    const title = ui.title.value.trim();
    if (!title) { ui.title.focus(); return; }
    const tv = ui.time.value;
    events.push({ id: newId(), date: sel, time: TIME_RE.test(tv) ? tv : '', title: title.slice(0, 200), done: false, color: '#ff9f0a' });
    events = events.slice(-3000);
    save();
    ui.title.value = ''; ui.time.value = '';
    renderAll(); checkAlerts();
    ui.title.focus();
  }
  function toggle(id) { const e = events.find(x => x.id === id); if (e) { e.done = !e.done; save(); renderAll(); checkAlerts(); } }
  function remove(id) { events = events.filter(x => x.id !== id); save(); renderAll(); checkAlerts(); }

  function evRow(e, showDate) {
    return el('div', { class: 'cal-ev' + (e.done ? ' done' : '') },
      el('button', { class: 'cal-chk' + (e.done ? ' on' : ''), title: e.done ? 'Mark as not done' : 'Mark as done', onclick: () => toggle(e.id) }, e.done ? N.icon('check', 10, 3) : null),
      el('span', { style: { width: '6px', height: '6px', borderRadius: '50%', background: e.color, flex: 'none' } }),
      showDate ? el('span', { class: 'cal-rd', text: e.date === today() ? 'Today' : fmtDay(e.date) }) : null,
      e.time ? el('span', { class: 'tm', text: fmtTime(e.time) }) : null,
      el('span', { class: 'tt', title: e.title, text: e.title }),
      el('button', { class: 'cal-x', title: 'Delete', 'aria-label': 'Delete', onclick: () => remove(e.id) }, N.icon('x', 12)));
  }

  function renderLeft() {
    if (!ui) return;
    ui.month.textContent = fmtMonth();
    N.clear(ui.body);
    const counts = {};
    events.forEach(e => { counts[e.date] = (counts[e.date] || 0) + 1; });
    const tk = today();
    if (mode === 'month') {
      const grid = el('div', { class: 'cal' });
      const ws = weekStart();
      for (let i = 0; i < 7; i++) {
        const dt = new Date(2024, 0, (ws === 'sun' ? 7 : 1) + i); // 2024-01-01 is a Monday, 07 a Sunday
        let nm = ''; try { nm = dt.toLocaleDateString([], { weekday: 'short' }); } catch (e) { nm = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][i]; }
        grid.appendChild(el('div', { class: 'dn', text: nm }));
      }
      monthCells(viewY, viewM, ws).forEach(c => {
        const cls = 'd' + (c.other ? ' other' : '') + (c.key === tk ? ' today' : '') + (c.key === sel ? ' sel' : '');
        grid.appendChild(el('div', { class: cls, onclick: () => selectDay(c.key) }, String(c.d), counts[c.key] ? el('i') : null));
      });
      ui.body.appendChild(grid);
    } else {
      const prefix = viewY + '-' + pad2(viewM + 1) + '-';
      const list = events.filter(e => e.date.startsWith(prefix)).sort(cmpEv);
      const box = el('div', { class: 'cal-list' });
      if (!list.length) box.appendChild(el('div', { class: 'cal-empty', text: 'Nothing planned this month' }));
      let cur = '';
      list.forEach(e => {
        if (e.date !== cur) { cur = e.date; const k = cur; box.appendChild(el('div', { class: 'cal-gh' + (k === sel ? ' sel' : ''), text: (k === tk ? 'Today - ' : '') + fmtDay(k), onclick: () => selectDay(k) })); }
        box.appendChild(evRow(e, false));
      });
      ui.body.appendChild(box);
    }
    ui.viewBtn.title = mode === 'month' ? 'Switch to list view' : 'Switch to month view';
    N.clear(ui.viewBtn); ui.viewBtn.appendChild(N.icon(mode === 'month' ? 'list' : 'calendar', 14));
  }

  function renderDay() {
    if (!ui) return;
    ui.dayTitle.textContent = (sel === today() ? 'Today - ' : '') + fmtDay(sel, true);
    ui.addLbl.title = 'Add to ' + fmtDay(sel);
    N.clear(ui.dayList);
    const list = byDay(sel);
    if (!list.length) ui.dayList.appendChild(el('div', { class: 'cal-empty', text: 'Nothing planned' }));
    list.forEach(e => ui.dayList.appendChild(evRow(e, false)));
  }

  function renderRem() {
    if (!ui) return;
    N.clear(ui.remList);
    const a = today(), b = addDays(a, 7);
    const list = events.filter(e => !e.done && e.date >= a && e.date <= b).sort(cmpEv);
    if (!list.length) ui.remList.appendChild(el('div', { class: 'cal-empty', text: 'All clear for the next 7 days' }));
    list.forEach(e => ui.remList.appendChild(evRow(e, true)));
  }

  function renderAll() { renderLeft(); renderDay(); renderRem(); }

  N.register({
    id: 'calendar', name: 'Calendar', icon: 'calendar', size: [700, 330],
    mount(root) {
      ui = {};
      ui.month = el('div', { class: 'cal-month', title: 'Jump to today', onclick: goToday });
      ui.month.addEventListener('contextmenu', e => N.menu(e, [
        { label: 'Week starts on Monday' + (weekStart() === 'mon' ? ' (current)' : ''), fn: () => { N.set('weekStart', 'mon'); renderLeft(); } },
        { label: 'Week starts on Sunday' + (weekStart() === 'sun' ? ' (current)' : ''), fn: () => { N.set('weekStart', 'sun'); renderLeft(); } }
      ]));
      ui.viewBtn = el('button', { class: 'btn icon', onclick: () => { mode = mode === 'month' ? 'list' : 'month'; N.set('calView', mode); renderLeft(); } });
      ui.body = el('div', { style: { display: 'flex', flexDirection: 'column', flex: '1', minHeight: '0' } });
      const left = el('div', { class: 'cal-left' },
        el('div', { class: 'cal-head' },
          el('button', { class: 'btn icon', title: 'Previous month', 'aria-label': 'Previous month', onclick: () => setMonth(viewY, viewM - 1) }, N.icon('left', 14)),
          ui.month,
          el('button', { class: 'btn icon', title: 'Next month', 'aria-label': 'Next month', onclick: () => setMonth(viewY, viewM + 1) }, N.icon('right', 14)),
          ui.viewBtn),
        ui.body);

      ui.title = el('input', { type: 'text', placeholder: 'Add event or reminder', maxlength: '200' });
      ui.title.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addEvent(); } e.stopPropagation(); });
      ui.time = el('input', { type: 'time', title: 'Time (optional)' });
      ui.time.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addEvent(); } e.stopPropagation(); });
      ui.addLbl = el('button', { class: 'btn primary icon', 'aria-label': 'Add', onclick: addEvent }, N.icon('plus', 14, 2.5));
      ui.dayTitle = el('div', { class: 'ttl' });
      ui.dayList = el('div', { class: 'cal-list' });
      ui.remList = el('div', { class: 'cal-list' });
      const day = el('div', { class: 'card cal-sec', style: { flex: '1.5' } }, ui.dayTitle,
        el('div', { class: 'cal-form' }, ui.title, ui.time, ui.addLbl), ui.dayList);
      const rem = el('div', { class: 'card cal-sec', style: { flex: '1' } }, el('div', { class: 'ttl', text: 'Reminders - today and the next 7 days' }), ui.remList);
      root.appendChild(el('div', { class: 'cal-wrap' }, left, el('div', { class: 'cal-right' }, day, rem)));
      renderAll();
    },
    show() {
      if (today() !== lastToday) { lastToday = today(); const p = parseKey(lastToday); viewY = p.y; viewM = p.m; sel = lastToday; }
      renderAll();
    }
  });

  // ---- background: gentle alert when a timed event starts + live pill during the 10 minutes before
  const fired = new Set();
  function checkAlerts() {
    try {
      const now = new Date(), tk = today();
      let next = null, nextMins = 1e9;
      events.forEach(e => {
        if (e.done || !e.time || e.date !== tk) return;
        const mins = minsUntil(e, now);
        if (mins === null) return;
        const key = e.id + '|' + e.date + '|' + e.time;
        if (mins <= 0 && mins > -2 && !fired.has(key)) {
          fired.add(key);
          N.toast(e.title + ' - ' + fmtTime(e.time), 5000); N.chime(); N.wobble();
        }
        if (mins > 0 && mins <= 10 && mins < nextMins) { next = e; nextMins = mins; }
      });
      if (next) N.live('cal', { prio: 2, icon: 'calendar', left: next.title, right: fmtTime(next.time) });
      else N.live('cal', null);
    } catch (err) { console.warn('calendar check', err && err.message); }
  }
  N.startCalendar = function () { checkAlerts(); setInterval(checkAlerts, 30000); };
})();
