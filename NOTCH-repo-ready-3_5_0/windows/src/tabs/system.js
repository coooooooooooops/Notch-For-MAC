'use strict';
// System: live network speed + sparkline, Wi-Fi signal, CPU and memory. Polls only while the tab is showing.
(function () {
  const N = window.N, el = N.el, api = N.api;

  // <pure>
  const isNum = v => typeof v === 'number' && isFinite(v);
  function fmtRate(b) {
    if (!isNum(b)) return '-';
    b = Math.max(0, b);
    if (b < 1024 * 1000) { const k = b / 1024; return (k < 10 && k > 0 ? k.toFixed(1) : String(Math.round(k))) + ' KB/s'; }
    const m = b / 1048576;
    return (m < 100 ? m.toFixed(1) : String(Math.round(m))) + ' MB/s';
  }
  function fmtGB(b) { return isNum(b) ? (b / 1073741824).toFixed(1) + ' GB' : '-'; }
  const clampPct = v => isNum(v) ? Math.max(0, Math.min(100, Math.round(v))) : null;
  function niceMax(vals) { // auto-scale: at least 64 KB/s so idle noise stays flat
    let mx = 64 * 1024;
    vals.forEach(v => { if (isNum(v) && v > mx) mx = v; });
    return mx * 1.15;
  }
  function wifiBars(pct) { return pct === null ? 0 : pct >= 75 ? 4 : pct >= 50 ? 3 : pct >= 25 ? 2 : pct > 0 ? 1 : 0; }
  // </pure>
  N.__sysTest = { fmtRate, fmtGB, clampPct, niceMax, wifiBars };

  const st = document.createElement('style');
  st.textContent = [
    '.sys-wrap { display: flex; gap: 10px; height: 100%; min-height: 0; }',
    '.sys-net { flex: 1.6; min-width: 0; display: flex; flex-direction: column; gap: 6px; }',
    '.sys-side { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 10px; }',
    '.sys-rates { display: flex; gap: 22px; flex: none; }',
    '.sys-val { font-size: 22px; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1.1; }',
    '.sys-lbl { font-size: 11px; color: var(--dim); display: flex; align-items: center; gap: 4px; }',
    '.sys-graph { position: relative; flex: 1; min-height: 0; }',
    '.sys-graph canvas { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }',
    '.sys-note { position: absolute; inset: 0; display: grid; place-items: center; color: var(--dim); font-size: 12px; pointer-events: none; }',
    '.sys-card { background: rgba(255,255,255,.07); border-radius: 12px; padding: 9px 11px; display: flex; flex-direction: column; gap: 6px; flex: 1; justify-content: center; min-height: 0; }',
    '.sys-top { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }',
    '.sys-top b { font-size: 15px; font-variant-numeric: tabular-nums; }',
    '.sys-wbars { display: inline-flex; gap: 2px; align-items: flex-end; height: 14px; }',
    '.sys-wbars i { width: 4px; border-radius: 1px; background: rgba(255,255,255,.2); }',
    '.sys-wbars i.on { background: var(--accent); }'
  ].join('\n');
  document.head.appendChild(st);

  const MAX = 60;
  let ui = null, timer = null, inflight = false, gen = 0, samples = [], lastGood = 0, lastUp = null, lastDown = null;

  function wifiBox() {
    const bars = el('span', { class: 'sys-wbars' }, [5, 8, 11, 14].map(h => el('i', { style: { height: h + 'px' } })));
    return bars;
  }

  function accent() {
    try { return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#30d158'; } catch (e) { return '#30d158'; }
  }

  function draw() {
    if (!ui) return;
    const cv = ui.canvas;
    const w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return;
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const pw = Math.round(w * dpr), ph = Math.round(h * dpr);
    if (cv.width !== pw) cv.width = pw;
    if (cv.height !== ph) cv.height = ph;
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const col = accent();
    // guide lines
    ctx.strokeStyle = 'rgba(255,255,255,.08)'; ctx.lineWidth = 1;
    [0.25, 0.5, 0.75].forEach(f => { const y = Math.round(h * f) + .5; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); });
    ui.note.style.display = samples.length < 2 ? 'grid' : 'none';
    if (samples.length < 2) return;
    const mx = niceMax(samples), padT = 4, padB = 2;
    const stepX = w / (MAX - 1);
    const x0 = w - (samples.length - 1) * stepX;
    const pts = samples.map((v, i) => ({ x: x0 + i * stepX, y: padT + (h - padT - padB) * (1 - Math.max(0, isNum(v) ? v : 0) / mx) }));
    const path = () => {
      ctx.beginPath(); ctx.moveTo(pts[0].x, pts[0].y);
      for (let i = 1; i < pts.length - 1; i++) {
        const mxp = (pts[i].x + pts[i + 1].x) / 2, myp = (pts[i].y + pts[i + 1].y) / 2;
        ctx.quadraticCurveTo(pts[i].x, pts[i].y, mxp, myp);
      }
      const l = pts[pts.length - 1]; ctx.lineTo(l.x, l.y);
    };
    path();
    ctx.lineTo(pts[pts.length - 1].x, h); ctx.lineTo(pts[0].x, h); ctx.closePath();
    const g = ctx.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, col + '66'); g.addColorStop(1, col + '00');
    try { ctx.fillStyle = g; } catch (e) { ctx.fillStyle = 'rgba(48,209,88,.25)'; }
    ctx.fill();
    path();
    ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round'; ctx.stroke();
    ui.scale.textContent = 'Peak scale ' + fmtRate(mx / 1.15);
  }

  function setBar(bar, pct) { bar.style.width = (pct === null ? 0 : pct) + '%'; }

  function apply(s) {
    if (!ui) return;
    const down = isNum(s.down) ? s.down : null, up = isNum(s.up) ? s.up : null;
    ui.down.textContent = fmtRate(down); ui.up.textContent = fmtRate(up);
    samples.push(down === null ? 0 : down);
    if (samples.length > MAX) samples = samples.slice(-MAX);
    const cpu = clampPct(s.cpu);
    ui.cpu.textContent = cpu === null ? '-' : cpu + '%'; setBar(ui.cpuBar, cpu);
    let mp = null;
    if (isNum(s.memUsed) && isNum(s.memTotal) && s.memTotal > 0) mp = clampPct(s.memUsed / s.memTotal * 100);
    ui.mem.textContent = mp === null ? '-' : mp + '%'; setBar(ui.memBar, mp);
    ui.memSub.textContent = mp === null ? '' : fmtGB(s.memUsed) + ' of ' + fmtGB(s.memTotal);
    const w = clampPct(s.wifi);
    ui.wifi.textContent = w === null ? 'Not on Wi-Fi' : w + '%';
    const n = wifiBars(w);
    Array.from(ui.wbars.children).forEach((b, i) => b.classList.toggle('on', i < n));
    draw();
  }

  N.__sysTest.apply = s => apply(s);

  function applyError() {
    if (!ui) return;
    ui.down.textContent = '-'; ui.up.textContent = '-'; ui.cpu.textContent = '-'; ui.mem.textContent = '-'; ui.wifi.textContent = '-';
    ui.memSub.textContent = 'Stats unavailable';
    setBar(ui.cpuBar, null); setBar(ui.memBar, null);
  }

  async function poll() {
    if (inflight || !timer) return;
    inflight = true;
    const my = gen;
    try {
      const s = await api.sysStats();
      if (my !== gen) return;
      if (s && typeof s === 'object') apply(s); else applyError();
    } catch (e) {
      if (my === gen) applyError();
    } finally { inflight = false; }
  }

  function stat(label, valEl, barEl, sub) {
    return el('div', { class: 'sys-card' },
      el('div', { class: 'sys-top' }, el('span', { class: 'sys-lbl', text: label }), valEl),
      el('div', { class: 'meter' }, barEl), sub || null);
  }

  N.register({
    id: 'system', name: 'System', icon: 'system', size: [700, 252],
    mount(root) {
      ui = {};
      ui.down = el('div', { class: 'sys-val', text: '-' }); ui.up = el('div', { class: 'sys-val', text: '-' });
      ui.canvas = el('canvas'); ui.note = el('div', { class: 'sys-note', text: 'Collecting data...' });
      ui.scale = el('span', { class: 'sys-lbl' });
      const net = el('div', { class: 'card sys-net' },
        el('div', { class: 'sys-rates' },
          el('div', null, el('div', { class: 'sys-lbl' }, N.icon('down', 12), 'Download'), ui.down),
          el('div', null, el('div', { class: 'sys-lbl' }, N.icon('up', 12), 'Upload'), ui.up)),
        el('div', { class: 'sys-graph' }, ui.canvas, ui.note),
        el('div', { class: 'sys-top' }, el('span', { class: 'sys-lbl', text: 'Download, last 60 seconds' }), ui.scale));
      ui.wbars = wifiBox(); ui.wifi = el('b', { text: '-' });
      ui.cpu = el('b', { text: '-' }); ui.cpuBar = el('i');
      ui.mem = el('b', { text: '-' }); ui.memBar = el('i'); ui.memSub = el('div', { class: 'sys-lbl', text: '' });
      const side = el('div', { class: 'sys-side' },
        el('div', { class: 'sys-card' },
          el('div', { class: 'sys-top' }, el('span', { class: 'sys-lbl' }, N.icon('wifi', 12), 'Wi-Fi'), el('span', { class: 'row', style: { gap: '8px' } }, ui.wbars, ui.wifi))),
        stat('CPU', ui.cpu, ui.cpuBar), stat('Memory', ui.mem, ui.memBar, ui.memSub));
      root.appendChild(el('div', { class: 'sys-wrap' }, net, side));
    },
    show() {
      gen++;
      if (timer) clearInterval(timer);
      timer = setInterval(poll, 1000);
      inflight = false;
      poll();
      setTimeout(draw, 60);
    },
    hide() {
      gen++;
      if (timer) { clearInterval(timer); timer = null; }
      inflight = false;
    }
  });
})();
