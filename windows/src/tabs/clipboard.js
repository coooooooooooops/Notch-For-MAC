'use strict';
// Clipboard: recent text copies (50), pinned items (kept between launches), last 10 copied images.
(function () {
  const N = window.N, el = N.el, api = N.api;
  let clips = [], images = [], q = '', list = null, thumbs = null, search = null, built = false;
  const pinned = () => N.get('pinnedClips', []);

  api.on('clip-add', p => {
    if (!p) return;
    if (p.type === 'text') {
      const t = p.text;
      if (!t || pinned().includes(t)) return;
      clips = clips.filter(c => c !== t); clips.unshift(t); clips = clips.slice(0, 50);
    } else if (p.type === 'image') {
      images.unshift(p.file); const drop = images.slice(10); images = images.slice(0, 10);
      drop.forEach(f => api.clipDeleteImage(f));
      if (N.open && N.cur && N.cur.id === 'clip') N.resize();
    }
    if (built) render();
  });

  function setPinned(v) { N.set('pinnedClips', v); render(); }
  function togglePin(t) {
    const p = pinned();
    if (p.includes(t)) { setPinned(p.filter(x => x !== t)); clips = clips.filter(c => c !== t); clips.unshift(t); }
    else { setPinned([t].concat(p)); clips = clips.filter(c => c !== t); }
    render();
  }
  async function copy(t) { await api.clipWriteText(t); N.toast('Copied'); }

  function row(t, isPinned) {
    const first = t.replace(/\s+/g, ' ').trim().slice(0, 160) || '(blank)';
    const r = el('div', { class: 'clip' + (isPinned ? ' pinned' : ''), title: t.slice(0, 600), onclick: () => copy(t) },
      el('div', { class: 'tx', text: first }),
      el('button', { class: 'pillbtn', title: isPinned ? 'Unpin' : 'Pin', style: { color: isPinned ? 'var(--accent)' : 'inherit' }, onclick: e => { e.stopPropagation(); togglePin(t); } }, N.icon('pin', 12)));
    r.addEventListener('contextmenu', e => N.menu(e, [
      { label: isPinned ? 'Unpin' : 'Pin', fn: () => togglePin(t) },
      { label: 'Delete', danger: true, fn: () => { if (isPinned) setPinned(pinned().filter(x => x !== t)); else { clips = clips.filter(c => c !== t); render(); } } }
    ]));
    return r;
  }

  function render() {
    if (!list) return;
    N.clear(list); N.clear(thumbs);
    const f = q.trim().toLowerCase();
    const match = t => !f || t.toLowerCase().includes(f);
    const p = pinned().filter(match), c = clips.filter(match);
    p.forEach(t => list.appendChild(row(t, true)));
    c.forEach(t => list.appendChild(row(t, false)));
    if (!p.length && !c.length) list.appendChild(el('div', { class: 'empty', text: f ? 'No matches' : 'Copy something and it will show up here' }));
    thumbs.style.display = images.length ? 'flex' : 'none';
    images.forEach(file => {
      const url = 'file:///' + file.replace(/\\/g, '/').replace(/^\//, '');
      const img = el('img', { src: encodeURI(url).replace(/#/g, '%23'), alt: 'copied image', draggable: 'true', title: 'Click to copy again, drag to use, right-click to delete' });
      img.addEventListener('click', async () => { if (await api.clipWriteImage(file)) N.toast('Image copied'); });
      img.addEventListener('dragstart', e => { e.preventDefault(); api.startDrag(file); });
      img.addEventListener('contextmenu', e => N.menu(e, [{ label: 'Delete image', danger: true, fn: () => { images = images.filter(x => x !== file); api.clipDeleteImage(file); render(); N.resize(); } }]));
      thumbs.appendChild(img);
    });
  }

  N.register({
    id: 'clip', name: 'Clipboard', icon: 'clip', size: () => [700, images.length ? 300 : 254],
    mount(root) {
      search = el('input', { type: 'search', placeholder: 'Search clipboard', style: { width: '100%' } });
      search.addEventListener('input', () => { q = search.value; render(); });
      list = el('div', { class: 'scroll grow' }); thumbs = el('div', { class: 'thumbs' });
      root.appendChild(el('div', { style: { display: 'flex', flexDirection: 'column', height: '100%', gap: '6px' } },
        el('div', { class: 'row' }, el('div', { class: 'grow' }, search),
          el('button', { class: 'btn', onclick: async () => { clips = []; images = []; await api.clipWipeImages(); render(); N.resize(); N.toast('History cleared (pinned items kept)'); } }, N.icon('trash', 14), 'Clear history')),
        thumbs, list));
      built = true; render();
    },
    show() { render(); if (search) setTimeout(() => { try { search.focus({ preventScroll: true }); } catch (e) { /* ignore */ } }, 50); }
  });
})();
