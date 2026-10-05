'use strict';
// Notes: any number of named notes + two customisable counter cards (Water, Counter).
(function () {
  const N = window.N, el = N.el;
  let root = null, view = 'edit', editing = null;   // editing = counter id being customised
  let nameIn = null, textIn = null;

  const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const notes = () => N.get('notes', []);
  function saveNotes(n) { N.set('notes', n); }
  function ensure() {
    let n = notes();
    if (!n.length) { n = [{ id: uid(), name: 'Note', text: '', ts: Date.now() }]; saveNotes(n); }
    let cur = N.get('noteCur', null);
    if (!n.find(x => x.id === cur)) { cur = n[0].id; N.set('noteCur', cur); }
    return { n, cur };
  }
  const curNote = () => { const { n, cur } = ensure(); return n.find(x => x.id === cur); };

  // ---- counters
  const DEFAULT_COUNTERS = [
    { id: 'water', name: 'Water', unit: 'ml', step: 250, goal: 2000, color: 'cyan', value: 0, daily: true, ring: true },
    { id: 'counter', name: 'Counter', unit: '', step: 1, goal: 0, color: 'orange', value: 0, daily: false, ring: false }
  ];
  function counters() {
    let c = N.get('counters', null);
    if (!Array.isArray(c) || c.length !== 2) { c = JSON.parse(JSON.stringify(DEFAULT_COUNTERS)); N.set('counters', c); }
    const day = N.dayKey();
    if (N.get('lastDay', '') !== day) {
      c.forEach(x => { if (x.daily) x.value = 0; });
      N.set('lastDay', day); N.set('counters', c);
    }
    return c;
  }
  function saveCounter(c) { const all = counters().map(x => x.id === c.id ? c : x); N.set('counters', all); }

  function ring(c) {
    const r = 15, C = 2 * Math.PI * r, frac = c.goal > 0 ? Math.min(1, c.value / c.goal) : 0;
    return '<svg width="38" height="38" viewBox="0 0 38 38"><circle cx="19" cy="19" r="' + r + '" fill="none" stroke="rgba(255,255,255,.15)" stroke-width="4"/><circle cx="19" cy="19" r="' + r + '" fill="none" stroke="' + (N.colors[c.color] || '#fff') + '" stroke-width="4" stroke-linecap="round" stroke-dasharray="' + C.toFixed(1) + '" stroke-dashoffset="' + (C * (1 - frac)).toFixed(1) + '" transform="rotate(-90 19 19)"/></svg>';
  }
  function counterCard(c) {
    const col = N.colors[c.color] || '#fff';
    const box = el('div', { class: 'ccard' });
    const head = el('div', { class: 'row' }, el('div', { class: 'small', style: { color: col, fontWeight: '700' }, text: c.name }), el('div', { class: 'grow' }),
      el('button', { class: 'pillbtn', title: 'Customise', onclick: () => { editing = c.id; draw(); } }, N.icon('sliders', 12)));
    const val = el('div', { class: 'row' });
    if (c.ring) { const r = el('span', { style: { lineHeight: 0 } }); r.innerHTML = ring(c); val.appendChild(r); }
    val.appendChild(el('div', {}, el('span', { class: 'cval', text: String(c.value) }), el('span', { class: 'dim tiny', text: ' ' + (c.unit || '') + (c.goal > 0 ? ' / ' + c.goal : '') })));
    const bump = d => { c.value = Math.max(0, c.value + d); saveCounter(c); draw(); };
    box.appendChild(head); box.appendChild(val);
    box.appendChild(el('div', { class: 'row', style: { marginTop: '4px' } },
      el('button', { class: 'pillbtn', onclick: () => bump(-c.step) }, '−'), el('button', { class: 'pillbtn', onclick: () => bump(c.step) }, '+ ' + c.step)));
    return box;
  }

  function customisePanel(c) {
    const f = (label, input) => el('label', { class: 'row small', style: { gap: '6px' } }, el('span', { class: 'dim', style: { width: '64px' }, text: label }), input);
    const name = el('input', { type: 'text', value: c.name, maxlength: '20', style: { width: '120px' } });
    const unit = el('input', { type: 'text', value: c.unit, maxlength: '8', style: { width: '70px' } });
    const step = el('input', { type: 'number', value: c.step, min: '1', max: '100000', style: { width: '80px' } });
    const goal = el('input', { type: 'number', value: c.goal, min: '0', max: '1000000', style: { width: '80px' } });
    const val = el('input', { type: 'number', value: c.value, min: '0', max: '1000000', style: { width: '80px' } });
    let color = c.color, daily = c.daily, showRing = c.ring;
    const sw = el('div', { class: 'swatches' });
    const drawSw = () => { N.clear(sw); Object.keys(N.colors).forEach(k => sw.appendChild(el('div', { class: 'sw' + (k === color ? ' sel' : ''), style: { background: N.colors[k] }, onclick: () => { color = k; drawSw(); } }))); };
    drawSw();
    const mkSwitch = (get, set) => { const s = el('button', { class: 'switch' + (get() ? ' on' : '') }); s.onclick = () => { set(!get()); s.classList.toggle('on', get()); }; return s; };
    const num = (i, d, lo, hi) => { const v = Math.round(Number(i.value)); return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d; };
    return el('div', { class: 'card', style: { display: 'flex', flexDirection: 'column', gap: '6px', height: '100%', overflow: 'auto' } },
      el('div', { class: 'row' }, el('div', { class: 'h', text: 'Customise ' + c.name }), el('div', { class: 'grow' }),
        el('button', { class: 'btn primary', onclick: () => {
          saveCounter({ id: c.id, name: (name.value.trim() || c.name).slice(0, 20), unit: unit.value.trim().slice(0, 8), step: num(step, c.step, 1, 100000), goal: num(goal, c.goal, 0, 1000000), value: num(val, c.value, 0, 1000000), color, daily, ring: showRing });
          editing = null; draw();
        } }, 'Done'), el('button', { class: 'btn', onclick: () => { editing = null; draw(); } }, 'Cancel')),
      el('div', { class: 'row', style: { flexWrap: 'wrap', gap: '8px 18px' } }, f('Name', name), f('Unit', unit), f('Step', step), f('Goal', goal), f('Value', val)),
      el('div', { class: 'row', style: { gap: '18px', flexWrap: 'wrap' } }, f('Colour', sw),
        el('label', { class: 'row small' }, el('span', { class: 'dim', text: 'Reset daily' }), mkSwitch(() => daily, v => { daily = v; })),
        el('label', { class: 'row small' }, el('span', { class: 'dim', text: 'Progress ring' }), mkSwitch(() => showRing, v => { showRing = v; }))));
  }

  // ---- notes UI
  const saveText = N.debounce(() => { const n = notes(), cur = N.get('noteCur'); const x = n.find(i => i.id === cur); if (x && textIn) { x.text = textIn.value; x.ts = Date.now(); saveNotes(n); } }, 350);
  const saveName = N.debounce(() => { const n = notes(), cur = N.get('noteCur'); const x = n.find(i => i.id === cur); if (x && nameIn) { x.name = nameIn.value.slice(0, 60) || 'Note'; saveNotes(n); } }, 350);

  function flush() {
    const n = notes(), cur = N.get('noteCur'); const x = n.find(i => i.id === cur);
    if (x && textIn && nameIn) { x.text = textIn.value; x.name = nameIn.value.slice(0, 60) || 'Note'; saveNotes(n); }
  }

  function draw() {
    N.clear(root);
    const cs = counters();
    if (editing) { root.appendChild(customisePanel(cs.find(c => c.id === editing) || cs[0])); return; }
    const { n, cur } = ensure();
    const note = n.find(x => x.id === cur);
    const left = el('div', { class: 'notes-main' });
    if (view === 'list') {
      left.appendChild(el('div', { class: 'row' }, el('div', { class: 'h grow', text: 'All notes' }),
        el('button', { class: 'btn', onclick: () => { view = 'edit'; draw(); } }, 'Back to note'),
        el('button', { class: 'btn primary', onclick: newNote }, N.icon('plus', 14), 'New')));
      const box = el('div', { class: 'scroll grow' });
      n.slice().sort((a, b) => b.ts - a.ts).forEach(x => box.appendChild(el('div', { class: 'clip' + (x.id === cur ? ' pinned' : ''), onclick: () => { N.set('noteCur', x.id); view = 'edit'; draw(); } },
        el('div', { class: 'tx' }, el('b', { text: x.name + '  ' }), el('span', { class: 'dim', text: (x.text || '').replace(/\s+/g, ' ').slice(0, 80) })),
        el('span', { class: 'dim tiny', text: new Date(x.ts).toLocaleDateString() }))));
      left.appendChild(box);
    } else {
      nameIn = el('input', { type: 'text', value: note.name, placeholder: 'Note name', class: 'grow', style: { fontWeight: '700' } });
      textIn = el('textarea', { placeholder: 'Write something...', spellcheck: 'false' }); textIn.value = note.text;
      nameIn.addEventListener('input', saveName); textIn.addEventListener('input', saveText);
      left.appendChild(el('div', { class: 'row' },
        el('button', { class: 'btn icon', title: 'All notes', onclick: () => { flush(); view = 'list'; draw(); } }, N.icon('list', 14)), nameIn,
        el('button', { class: 'btn icon', title: 'New note', onclick: newNote }, N.icon('plus', 14)),
        el('button', { class: 'btn icon', title: 'Delete note', onclick: delNote }, N.icon('trash', 14))));
      left.appendChild(textIn);
    }
    root.appendChild(el('div', { class: 'notes-wrap' }, left, el('div', { class: 'counter' }, cs.map(counterCard))));
  }
  function newNote() { flush(); const n = notes(); const x = { id: uid(), name: 'Note ' + (n.length + 1), text: '', ts: Date.now() }; n.push(x); saveNotes(n); N.set('noteCur', x.id); view = 'edit'; draw(); setTimeout(() => { try { textIn.focus(); } catch (e) { /* ignore */ } }, 30); }
  function delNote() {
    const n = notes(), cur = N.get('noteCur');
    const rest = n.filter(x => x.id !== cur);
    saveNotes(rest.length ? rest : []); N.set('noteCur', rest.length ? rest[0].id : null);
    draw(); N.toast('Note deleted');
  }

  N.register({
    id: 'notes', name: 'Notes', icon: 'notes', size: [700, 262],
    mount(r) { root = el('div', { style: { height: '100%' } }); r.appendChild(root); draw(); },
    show() { editing = null; draw(); },
    hide() { flush(); }
  });
})();
