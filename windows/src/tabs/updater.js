'use strict';
// Updater tab: shows the latest NOTCH for Windows release. Only ever talks to the Windows repo (see updater-core.js).
(function () {
  const N = window.N, el = N.el, api = N.api;
  let S = { status: 'Not checked yet', release: null, hasUpdate: false, checking: false, busy: false, progress: null, current: N.version, repo: '' };
  let ui = null, showCfg = false;

  api.on('updater-state', s => { if (s) { S = s; paint(); N.renderTabs(); } });
  api.updaterState().then(s => { if (s) { S = s; paint(); N.renderTabs(); } }).catch(() => {});

  function notes(body) {
    return String(body || '').replace(/\r/g, '').replace(/^#+\s*/gm, '').replace(/\*\*/g, '').slice(0, 1500) || 'No release notes.';
  }

  function paint() {
    if (!ui) return;
    const r = S.release;
    ui.status.textContent = S.status;
    ui.status.style.color = S.hasUpdate ? 'var(--accent)' : '';
    ui.ver.textContent = 'Installed: ' + S.current + (r ? '    Latest: ' + r.version : '');
    ui.title.textContent = r ? (r.name || r.tag) : 'No release found yet';
    ui.date.textContent = r && r.published ? new Date(r.published).toLocaleDateString([], { day: 'numeric', month: 'short', year: 'numeric' }) : '';
    ui.notes.textContent = r ? notes(r.body) : '';
    ui.install.style.display = S.hasUpdate && !S.busy ? '' : 'none';
    ui.check.disabled = S.checking || S.busy;
    ui.prog.style.display = S.busy && S.progress != null ? '' : 'none';
    ui.prog.firstChild.style.width = Math.round((S.progress || 0) * 100) + '%';
    ui.cfg.style.display = showCfg ? 'flex' : 'none';
    if (document.activeElement !== ui.repo) ui.repo.value = S.repo || '';
    ui.auto.classList.toggle('on', !!N.get('updAuto', false));
    ui.tick.style.display = !S.hasUpdate && r && !S.checking ? '' : 'none';
  }

  N.register({
    id: 'updater', name: 'Updater', icon: 'updater', size: [700, 290],
    badge: () => !!S.hasUpdate,
    mount(root) {
      ui = {
        status: el('div', { class: 'h' }), ver: el('div', { class: 'dim small' }), title: el('div', { style: { fontWeight: '600' } }), date: el('div', { class: 'dim small' }),
        notes: el('div', { class: 'scroll grow small', style: { whiteSpace: 'pre-wrap', userSelect: 'text' } }),
        tick: el('span', { style: { color: 'var(--accent)' } }, N.icon('check', 16)),
        prog: el('div', { class: 'meter' }, el('i')),
        install: el('button', { class: 'btn primary', onclick: () => { api.holdOpen(30000); api.updaterInstall(); } }, N.icon('download', 14), 'Install'),
        check: el('button', { class: 'btn', title: 'Check now', onclick: () => api.updaterCheck() }, N.icon('reload', 14), 'Check'),
        repo: el('input', { type: 'text', placeholder: 'owner/repo (Windows releases)', style: { flex: '1' } }),
        auto: el('button', { class: 'switch', title: 'Update automatically', onclick: () => { N.set('updAuto', !N.get('updAuto', false)); paint(); } })
      };
      ui.cfg = el('div', { class: 'row', style: { display: 'none' } },
        el('span', { class: 'dim small', text: 'Repo' }), ui.repo,
        el('button', { class: 'btn', onclick: async () => { const r = await api.updaterSetRepo(ui.repo.value); if (!r || !r.ok) N.toast((r && r.reason) || 'Invalid repo'); } }, 'Save'),
        el('span', { class: 'dim small', text: 'Auto-install' }), ui.auto);
      root.appendChild(el('div', { style: { display: 'flex', flexDirection: 'column', gap: '7px', height: '100%' } },
        el('div', { class: 'row' }, ui.status, ui.tick, el('div', { class: 'grow' }), ui.check, ui.install,
          el('button', { class: 'btn icon', title: 'Update settings', onclick: () => { showCfg = !showCfg; paint(); } }, N.icon('settings', 14))),
        ui.prog, ui.ver, el('div', { class: 'row' }, ui.title, el('div', { class: 'grow' }), ui.date), ui.notes, ui.cfg));
      paint();
    },
    show() { api.updaterState().then(s => { if (s) { S = s; paint(); } }).catch(() => {}); paint(); }
  });
})();
