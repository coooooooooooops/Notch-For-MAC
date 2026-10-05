'use strict';
// Shelf: drop files here, drag them back out later.
(function () {
  const N = window.N, el = N.el, api = N.api;
  let grid = null, drop = null;
  const items = () => N.get('shelf', []);

  function save(list) { N.set('shelf', list.slice(0, 60)); render(); }

  async function addPaths(paths) {
    const cur = items();
    let added = 0;
    for (const p of paths) {
      if (!p || cur.some(i => i.path === p)) continue;
      cur.unshift({ path: p, name: p.split(/[\\/]/).pop() }); added++;
    }
    if (added) save(cur); else if (paths.length) N.toast(paths.some(Boolean) ? 'Already on the shelf' : "Couldn't read that item");
  }

  function render() {
    if (!grid) return;
    N.clear(grid);
    const list = items();
    if (!list.length) { grid.appendChild(el('div', { class: 'empty', style: { gridColumn: '1/-1' }, text: 'Drop files here. Drag them back out whenever you need them.' })); return; }
    list.forEach(it => {
      const img = el('img', { alt: '' });
      api.fileIcon(it.path).then(u => { if (u) img.src = u; }).catch(() => {});
      const t = el('div', { class: 'tile', draggable: 'true', title: it.path }, img, el('div', { class: 'nm', text: it.name }));
      t.addEventListener('dragstart', e => { e.preventDefault(); api.startDrag(it.path); });
      t.addEventListener('dblclick', () => api.openPath(it.path).then(r => { if (r) N.toast('Could not open that file'); }));
      t.addEventListener('contextmenu', e => N.menu(e, [
        { label: 'Open', fn: () => api.openPath(it.path) },
        { label: 'Show in Explorer', fn: () => api.reveal(it.path) },
        { label: 'Copy path', fn: () => { api.clipWriteText(it.path); N.toast('Path copied'); } },
        { label: 'Remove from shelf', danger: true, fn: () => save(items().filter(x => x.path !== it.path)) }
      ]));
      grid.appendChild(t);
    });
  }

  function onDrop(e) {
    e.preventDefault();
    drop.classList.remove('over');
    const files = Array.from(e.dataTransfer.files || []);
    addPaths(files.map(f => api.pathForFile(f)).filter(Boolean));
  }

  N.register({
    id: 'shelf', name: 'Shelf', icon: 'shelf', size: [700, 230],
    mount(root) {
      grid = el('div', { class: 'grid scroll grow', style: { padding: '2px' } });
      drop = el('div', { class: 'dropzone', style: { display: 'flex', flexDirection: 'column', gap: '8px', height: '100%', borderRadius: '12px' } },
        el('div', { class: 'row' },
          el('div', { class: 'h', text: 'Shelf' }), el('div', { class: 'dim small grow', text: 'Drop files anywhere here' }),
          el('button', { class: 'btn', onclick: async () => { const p = await api.pickFiles(); if (p && p.length) addPaths(p); } }, N.icon('plus', 14), 'Add files'),
          el('button', { class: 'btn', onclick: () => { if (items().length) { api.clipWriteText(items().map(i => i.path).join('\n')); N.toast('Paths copied'); } } }, N.icon('copy', 14), 'Copy paths'),
          el('button', { class: 'btn icon', title: 'Clear shelf', onclick: () => save([]) }, N.icon('trash', 14))),
        grid);
      ['dragenter', 'dragover'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
      drop.addEventListener('dragleave', e => { if (e.target === drop) drop.classList.remove('over'); });
      drop.addEventListener('drop', onDrop);
      root.appendChild(drop);
      render();
    },
    show() {
      // forget files that were deleted since last time
      Promise.all(items().map(i => api.fileExists(i.path).then(ok => ok ? i : null))).then(arr => {
        const keep = arr.filter(Boolean);
        if (keep.length !== items().length) save(keep); else render();
      });
    }
  });

  // dragging a file in from Explorer jumps to the shelf (unless a tab that takes drops is showing)
  document.addEventListener('dragenter', e => {
    const t = e.dataTransfer && e.dataTransfer.types ? Array.from(e.dataTransfer.types) : [];
    if (N.open && t.includes('Files') && N.cur && !['shelf', 'ai', 'apps', 'browser'].includes(N.cur.id)) N.select('shelf');
  });
  document.addEventListener('dragover', e => e.preventDefault());
  document.addEventListener('drop', e => e.preventDefault());
})();
