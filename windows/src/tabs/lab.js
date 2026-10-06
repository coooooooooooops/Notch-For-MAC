'use strict';
// Lab: a locally hosted page shown inside the notch. It only appears after it has been switched on from Notes.
(function () {
  const N = window.N, el = N.el, api = N.api;
  const KEY = 'labOn', HOLD = 20000;
  const ON = '75008940b4ceb6fa9e2841c837c9b909752bf82cd3b834455c54271e05a15a2e';
  const OFF = '0934e2b83416e72b76b5d98a62c2247896d1d8c21073b0d055bba61b6f32a189';

  async function fp(t) {
    const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('nt:' + t));
    return Array.from(new Uint8Array(d)).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  // Resolves to the note text without its last (command) line if that line was a command, otherwise null.
  N.labRun = async function (text) {
    if (typeof text !== 'string' || !text.endsWith('\n')) return null;
    const lines = text.split('\n');
    if (lines.length < 2) return null;
    const h = await fp(lines[lines.length - 2].trim().toLowerCase());
    if (h !== ON && h !== OFF) return null;
    lines.splice(-2, 2);
    if (h === ON) { N.set(KEY, true); }
    else {
      N.set(KEY, false);
      if (N.cur && N.cur.id === 'lab') { const f = N.visibleTabs()[0]; if (f) N.select(f.id); }
      tab.hide();
    }
    N.renderTabs();
    return lines.join('\n');
  };

  let root = null, view = null, box = null, msg = null, loaded = false, loading = false, holdT = null, ready = false;
  const hold = () => { try { api.holdOpen(HOLD); } catch (e) { /* ignore */ } };

  function fail(t) { if (msg) { msg.textContent = t; msg.style.display = 'grid'; } }

  async function load() {
    if (loaded || loading) return;
    loading = true;
    if (msg) { msg.textContent = 'Loading...'; msg.style.display = 'grid'; }
    let r = null;
    try { r = await api.labStart(); } catch (e) { r = null; }
    loading = false;
    if (!r || !r.ok) { fail(r && r.error === 'missing' ? 'Nothing to show here yet.' : 'Could not open this page. Try again.'); return; }
    loaded = true;
    try {
      view = document.createElement('webview');
      view.setAttribute('src', r.url);
      view.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;border:0;border-radius:10px;background:#000;';
      view.addEventListener('dom-ready', () => { ready = true; if (msg) msg.style.display = 'none'; });
      view.addEventListener('did-fail-load', e => { if (e.isMainFrame !== false && Number(e.errorCode) !== -3) { loaded = false; fail('Could not open this page. Press to retry.'); } });
      view.addEventListener('render-process-gone', () => { loaded = false; ready = false; try { view.remove(); } catch (e) { /* ignore */ } view = null; fail('This page stopped working. Press to retry.'); });
      view.addEventListener('focus', () => { hold(); if (!holdT) holdT = setInterval(hold, 8000); });
      view.addEventListener('blur', () => { if (holdT) { clearInterval(holdT); holdT = null; } });
      box.insertBefore(view, msg);
    } catch (e) { loaded = false; fail('Could not open this page.'); }
  }

  const tab = {
    id: 'lab', name: 'Lab', icon: 'sliders', gated: KEY, keep: true, size: [820, 460],
    mount(r) {
      root = r;
      msg = el('div', { style: { position: 'absolute', inset: '0', display: 'grid', placeItems: 'center', color: 'var(--dim)', fontSize: '12px', cursor: 'pointer' }, onclick: () => load() });
      box = el('div', { style: { position: 'relative', flex: '1', minHeight: '0' } }, msg);
      root.appendChild(el('div', { style: { display: 'flex', flexDirection: 'column', height: '100%' } }, box));
    },
    show() { load(); hold(); try { if (view && ready) view.focus(); } catch (e) { /* ignore */ } },
    hide() {
      if (holdT) { clearInterval(holdT); holdT = null; }
      try { if (view && ready) { view.setAudioMuted(true); view.executeJavaScript('try{window.dispatchEvent(new Event("blur"))}catch(e){}').catch(() => {}); } } catch (e) { /* ignore */ }
      if (!N.get(KEY, false) && view) { try { view.remove(); } catch (e) { /* ignore */ } view = null; loaded = false; ready = false; }
    }
  };
  const origShow = tab.show;
  tab.show = function () { try { if (view) view.setAudioMuted(false); } catch (e) { /* ignore */ } origShow(); };
  N.register(tab);
})();
