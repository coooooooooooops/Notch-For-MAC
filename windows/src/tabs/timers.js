'use strict';
// Timers: focus / break timer with custom lengths, plus a stopwatch.
(function () {
  const N = window.N, el = N.el;
  const T = N.timers = {
    focus: Math.min(180, Math.max(1, N.get('focusMins', 25))),
    brk: Math.min(60, Math.max(1, N.get('breakMins', 5))),
    onBreak: false, running: false, endAt: 0, left: 0,
    sw: 0, swRunning: false, swStart: 0
  };
  T.left = T.focus * 60;
  let ui = null;

  const phaseLen = () => (T.onBreak ? T.brk : T.focus) * 60;
  const remaining = () => T.running ? Math.max(0, Math.ceil((T.endAt - Date.now()) / 1000)) : T.left;
  const swNow = () => T.swRunning ? T.sw + (Date.now() - T.swStart) / 1000 : T.sw;
  const step = (v, up, max) => up ? Math.min(max, v < 5 ? v + 1 : v + 5) : Math.max(1, v <= 5 ? v - 1 : v - 5);

  function startPause() {
    if (T.running) { T.left = remaining(); T.running = false; }
    else { if (T.left <= 0) T.left = phaseLen(); T.endAt = Date.now() + T.left * 1000; T.running = true; }
    refresh();
  }
  function reset() { T.running = false; T.onBreak = false; T.left = T.focus * 60; refresh(); }
  function skip() { T.running = false; T.onBreak = !T.onBreak; T.left = phaseLen(); refresh(); }
  function setLen(which, up) {
    if (which === 'focus') { T.focus = step(T.focus, up, 180); N.set('focusMins', T.focus); if (!T.running && !T.onBreak) T.left = T.focus * 60; }
    else { T.brk = step(T.brk, up, 60); N.set('breakMins', T.brk); if (!T.running && T.onBreak) T.left = T.brk * 60; }
    refresh();
  }

  function refresh() {
    const r = remaining();
    if (ui) {
      ui.time.textContent = N.mmss(r);
      ui.phase.textContent = T.onBreak ? 'Break' : 'Focus';
      const frac = phaseLen() ? 1 - r / phaseLen() : 0;
      ui.arc.setAttribute('stroke-dashoffset', String(263.9 * (1 - Math.max(0, Math.min(1, frac)))));
      N.clear(ui.go); ui.go.appendChild(N.icon(T.running ? 'pause' : 'play', 14)); ui.go.appendChild(document.createTextNode(T.running ? 'Pause' : 'Start'));
      ui.f.textContent = T.focus + ' min'; ui.b.textContent = T.brk + ' min';
      ui.sw.textContent = N.mmss(swNow());
      N.clear(ui.swGo); ui.swGo.appendChild(N.icon(T.swRunning ? 'pause' : 'play', 14)); ui.swGo.appendChild(document.createTextNode(T.swRunning ? 'Stop' : 'Start'));
    }
    if (T.running) N.live('timer', { prio: 3, icon: 'timers', left: T.onBreak ? 'Break' : 'Focus', right: N.mmss(r) });
    else if (T.swRunning) N.live('timer', { prio: 3, icon: 'timers', left: 'Stopwatch', right: N.mmss(swNow()) });
    else N.live('timer', null);
  }

  function tick() {
    if (T.running && remaining() <= 0) {
      const wasBreak = T.onBreak;
      T.running = false; T.onBreak = !wasBreak; T.left = phaseLen();
      N.chime(); N.wobble();
    }
    refresh();
  }

  function pills(label, valueEl, which) {
    return el('div', { class: 'row', style: { gap: '6px' } }, el('span', { class: 'dim small', style: { width: '34px' }, text: label }),
      el('button', { class: 'pillbtn', onclick: () => setLen(which, false) }, '−'), valueEl,
      el('button', { class: 'pillbtn', onclick: () => setLen(which, true) }, '+'));
  }

  N.register({
    id: 'timers', name: 'Timers', icon: 'timers', size: [700, 232],
    mount(root) {
      ui = {
        time: el('div', { class: 'timer-big', text: '25:00' }), phase: el('div', { class: 'dim small', text: 'Focus' }),
        f: el('span', { style: { minWidth: '52px', textAlign: 'center' } }), b: el('span', { style: { minWidth: '52px', textAlign: 'center' } }),
        sw: el('div', { class: 'timer-big', style: { fontSize: '34px' }, text: '00:00' })
      };
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('class', 'ring'); svg.setAttribute('viewBox', '0 0 100 100');
      const mk = (cls, attrs) => { const c = document.createElementNS('http://www.w3.org/2000/svg', 'circle'); Object.entries(attrs).forEach(([k, v]) => c.setAttribute(k, v)); svg.appendChild(c); return c; };
      mk('bg', { cx: 50, cy: 50, r: 42, fill: 'none', stroke: 'rgba(255,255,255,.15)', 'stroke-width': 7 });
      ui.arc = mk('arc', { cx: 50, cy: 50, r: 42, fill: 'none', stroke: 'var(--accent)', 'stroke-width': 7, 'stroke-linecap': 'round', 'stroke-dasharray': 263.9, 'stroke-dashoffset': 263.9, transform: 'rotate(-90 50 50)' });
      ui.go = el('button', { class: 'btn primary', onclick: startPause });
      ui.swGo = el('button', { class: 'btn primary', onclick: () => { if (T.swRunning) { T.sw = swNow(); T.swRunning = false; } else { T.swStart = Date.now(); T.swRunning = true; } refresh(); } });
      root.appendChild(el('div', { class: 'row', style: { height: '100%', gap: '16px' } },
        el('div', { class: 'card grow', style: { display: 'flex', gap: '14px', alignItems: 'center', height: '100%' } }, svg,
          el('div', { class: 'grow', style: { display: 'flex', flexDirection: 'column', gap: '6px' } },
            el('div', { class: 'row' }, ui.phase), ui.time,
            el('div', { class: 'row' }, ui.go, el('button', { class: 'btn', onclick: reset }, 'Reset'), el('button', { class: 'btn', title: 'Skip to ' + 'the next period', onclick: skip }, 'Skip')),
            el('div', { class: 'row', style: { gap: '10px', flexWrap: 'wrap' } }, pills('Focus', ui.f, 'focus'), pills('Break', ui.b, 'break')))),
        el('div', { class: 'card', style: { width: '200px', display: 'flex', flexDirection: 'column', gap: '8px', justifyContent: 'center', height: '100%' } },
          el('div', { class: 'dim small', text: 'Stopwatch' }), ui.sw,
          el('div', { class: 'row' }, ui.swGo, el('button', { class: 'btn', onclick: () => { T.sw = 0; T.swRunning = false; refresh(); } }, 'Reset')))));
      refresh();
    },
    show() { refresh(); }
  });

  N.startTimers = function () { setInterval(tick, 250); };
})();
