'use strict';
// Settings: appearance, tab order/visibility, hotkeys, launch at login, update choice.
(function () {
  const N = window.N, el = N.el, api = N.api;
  let root = null, view = 'main';
  const HK = [['toggle', 'Open / close NOTCH'], ['ai', 'Ask AI'], ['clip', 'Clipboard']];
  const DEFAULT_HK = { toggle: 'Control+Alt+N', ai: 'Control+Alt+A', clip: 'Control+Alt+V' };
  let capturing = null;

  const hk = () => Object.assign({}, DEFAULT_HK, N.cfg.hotkeys || {});
  const pretty = a => a ? a.replace('Control', 'Ctrl') : 'Off';

  function swatches(key, def, after) {
    const box = el('div', { class: 'swatches', style: { gap: '6px', flexWrap: 'nowrap' } });
    Object.keys(N.colors).forEach(name => {
      const s = el('div', { class: 'sw' + (N.get(key, def) === name ? ' sel' : ''), title: name, style: { background: N.colors[name] },
        onclick: () => { N.set(key, name); N.applyAppearance(); after && after(); draw(); } });
      box.appendChild(s);
    });
    return box;
  }
  function line(label, ctl) { return el('div', { class: 'row', style: { minHeight: '28px' } }, el('div', { class: 'dim', style: { width: '92px', flex: 'none' }, text: label }), el('div', { class: 'grow row' }, ctl)); }
  function sw(on, fn) { return el('button', { class: 'switch' + (on ? ' on' : ''), onclick: fn }); }

  function hotkeyRow(name, label) {
    const cur = hk()[name];
    const box = el('button', { class: 'btn', style: { minWidth: '110px', justifyContent: 'center' }, text: capturing === name ? 'Press keys...' : pretty(cur) });
    box.addEventListener('click', () => { capturing = name; draw(); });
    const reset = el('button', { class: 'pillbtn', title: 'Reset', onclick: () => setHk(name, DEFAULT_HK[name]) }, '↺');
    const off = el('button', { class: 'pillbtn', title: 'Turn off', onclick: () => setHk(name, null) }, N.icon('x', 11));
    return line(label, [box, reset, off]);
  }
  async function setHk(name, accel) {
    capturing = null;
    const r = await api.setHotkey(name, accel);
    if (r && r.ok) { const h = hk(); h[name] = accel; N.cfg.hotkeys = h; } else N.toast((r && r.reason) || 'Could not set that hotkey');
    draw();
  }
  document.addEventListener('keydown', e => {
    if (!capturing) return;
    e.preventDefault(); e.stopPropagation();
    if (e.key === 'Escape') { capturing = null; draw(); return; }
    if (['Control', 'Alt', 'Shift', 'Meta', 'AltGraph'].includes(e.key)) return;
    let k = null;
    if (/^Key[A-Z]$/.test(e.code)) k = e.code.slice(3); else if (/^Digit[0-9]$/.test(e.code)) k = e.code.slice(5);
    if (!(e.ctrlKey && e.altKey) || !k) { N.toast('Use Control + Alt together with a letter or number'); return; }
    setHk(capturing, 'Control+Alt+' + k);
  }, true);

  function mainView() {
    const fonts = Object.keys(N.fonts);
    const round = el('input', { type: 'range', min: '8', max: '40', step: '1', value: String(N.get('round', 26)) });
    round.addEventListener('input', () => { N.set('round', Number(round.value)); N.applyAppearance(); });
    const pill = el('input', { type: 'range', min: '180', max: '380', step: '10', value: String(N.get('pillWidth', 250)) });
    pill.addEventListener('change', () => { N.set('pillWidth', Number(pill.value)); N.updatePill(true); });
    const font = el('select', { onchange: e => { N.set('font', e.target.value); N.applyAppearance(); } }, fonts.map(f => el('option', { value: f, text: f[0].toUpperCase() + f.slice(1), selected: N.get('font', 'default') === f })));
    const idle = el('select', { onchange: e => { N.set('idleStyle', e.target.value); N.applyAppearance(); } },
      [['bar', 'Thin bar'], ['notch', 'Small notch'], ['hidden', 'Hidden until hover']].map(([v, t]) => el('option', { value: v, text: t, selected: N.get('idleStyle', 'bar') === v })));
    const wk = el('select', { onchange: e => N.set('weekStart', e.target.value) },
      [['mon', 'Monday'], ['sun', 'Sunday']].map(([v, t]) => el('option', { value: v, text: t, selected: N.get('weekStart', 'mon') === v })));
    const left = el('div', { class: 'grow scroll', style: { display: 'flex', flexDirection: 'column', gap: '4px', paddingRight: '8px' } },
      el('div', { class: 'h', text: 'Appearance' }),
      line('Accent', swatches('accent', 'green')), line('Clock colour', swatches('clockColor', 'white')),
      line('Font', font), line('Roundness', round), line('Idle look', idle), line('Pill width', pill), line('Week starts', wk),
      el('div', { class: 'row', style: { marginTop: '4px' } }, el('button', { class: 'btn', onclick: () => { view = 'tabs'; draw(); } }, N.icon('list', 14), 'Customise tabs')));
    const loginOn = !!N.cfg.__login;
    const right = el('div', { class: 'grow scroll', style: { display: 'flex', flexDirection: 'column', gap: '4px', paddingLeft: '8px', borderLeft: '1px solid var(--faint)' } },
      el('div', { class: 'h', text: 'Behaviour' }),
      line('Launch at login', sw(loginOn, async () => { N.cfg.__login = await api.setLogin(!loginOn); draw(); })),
      line('Click to expand', sw(!!N.get('clickMode', false), () => { const v = !N.get('clickMode', false); N.set('clickMode', v); api.setClickMode(v); draw(); })),
      line('Auto-update', sw(!!N.get('updAuto', false), () => { N.set('updAuto', !N.get('updAuto', false)); draw(); })),
      el('div', { class: 'h', style: { marginTop: '6px' }, text: 'Hotkeys' }),
      HK.map(([n, l]) => hotkeyRow(n, l)),
      el('div', { class: 'dim tiny', text: 'Every hotkey uses Control + Alt together.' }));
    return el('div', { class: 'row', style: { alignItems: 'stretch', height: '100%' } }, left, right);
  }

  function tabsView() {
    const hidden = N.get('tabsHidden', []);
    const order = N.orderedTabs().map(t => t.id);
    const save = (o, h) => { N.set('tabsOrder', o); N.set('tabsHidden', h); N.renderTabs(); N.applySize(); draw(); };
    const list = el('div', { class: 'scroll grow', style: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '4px 12px', alignContent: 'start' } });
    order.forEach((id, i) => {
      const t = N.byId[id], hid = hidden.includes(id);
      const move = d => { const o = order.slice(); const j = i + d; if (j < 0 || j >= o.length) return; [o[i], o[j]] = [o[j], o[i]]; save(o, hidden); };
      const toggle = () => {
        const visibleCount = order.filter(x => !hidden.includes(x)).length;
        if (!hid && visibleCount <= 1) { N.toast('At least one tab must stay visible'); return; }
        save(order, hid ? hidden.filter(x => x !== id) : hidden.concat(id));
      };
      list.appendChild(el('div', { class: 'row clip', style: { opacity: hid ? '.45' : '1', cursor: 'default', marginBottom: '0' } }, N.icon(t.icon || t.id, 14), el('div', { class: 'tx', text: t.name }),
        el('button', { class: 'pillbtn', onclick: () => move(-1) }, N.icon('up', 12)), el('button', { class: 'pillbtn', onclick: () => move(1) }, N.icon('down', 12)),
        el('button', { class: 'pillbtn', title: hid ? 'Show' : 'Hide', onclick: toggle }, N.icon(hid ? 'eyeoff' : 'eye', 12))));
    });
    const mins = el('input', { type: 'number', min: '5', max: '240', value: String(N.get('idleUnloadMins', 30)), style: { width: '64px' } });
    mins.addEventListener('change', () => { const v = Math.max(5, Math.min(240, Math.round(Number(mins.value)) || 30)); N.set('idleUnloadMins', v); mins.value = String(v); });
    return el('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px', height: '100%' } },
      el('div', { class: 'row' }, el('button', { class: 'btn', onclick: () => { view = 'main'; draw(); } }, N.icon('left', 14), 'Back'), el('div', { class: 'h grow', text: 'Customise tabs' }),
        el('button', { class: 'btn', onclick: () => save([], []) }, 'Reset')),
      list,
      el('div', { class: 'row' }, sw(N.get('idleUnload', true), () => { N.set('idleUnload', !N.get('idleUnload', true)); draw(); }), el('span', { class: 'dim small', text: 'Unload idle web pages after' }), mins, el('span', { class: 'dim small', text: 'minutes (never while playing audio)' })));
  }

  function draw() {
    if (!root) return;
    N.clear(root);
    root.appendChild(view === 'tabs' ? tabsView() : mainView());
    N.resize();
  }

  const tab = {
    id: 'settings', name: 'Settings', icon: 'settings', size: () => view === 'tabs' ? [700, 360] : [700, 372],
    mount(r) { root = r; draw(); },
    show() { draw(); },
    hide() { capturing = null; },
    showCustomise() { view = 'tabs'; draw(); }
  };
  N.register(tab);
})();
