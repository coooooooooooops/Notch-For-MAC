'use strict';
// Camera: mirror + shutter. The camera is only on while this tab is showing.
(function () {
  const N = window.N, el = N.el, api = N.api;
  const st = document.createElement('style');
  st.textContent = [
    '.cam-msg { position: absolute; inset: 0; display: none; flex-direction: column; align-items: center; justify-content: center; gap: 10px; padding: 16px; text-align: center; color: var(--dim); }',
    '.cam-msg.on { display: flex; }',
    '.cam-flash { position: absolute; inset: 0; background: #fff; opacity: 0; pointer-events: none; }',
    '.cam-flash.go { animation: camflash .35s ease-out; }',
    '@keyframes camflash { 0% { opacity: .85 } 100% { opacity: 0 } }',
    '.cam .shutter.cam-off { display: none; }',
    '.cam .camthumb.cam-on { display: block; }'
  ].join('\n');
  document.head.appendChild(st);

  let video = null, msg = null, msgText = null, msgBtn = null, shutter = null, thumb = null, flash = null;
  let stream = null, gen = 0, active = false, holdT = null, lastPhoto = null, busy = false;

  function setMsg(text, withBtn) {
    if (!msg) return;
    if (!text) { msg.classList.remove('on'); return; }
    msgText.textContent = text;
    msgBtn.style.display = withBtn ? '' : 'none';
    msg.classList.add('on');
  }

  function stopStream() {
    const s = stream; stream = null;
    if (s) { try { s.getTracks().forEach(t => { try { t.stop(); } catch (e) { /* ignore */ } }); } catch (e) { /* ignore */ } }
    if (video) { try { video.pause(); } catch (e) { /* ignore */ } try { video.srcObject = null; } catch (e) { /* ignore */ } }
  }

  function setHold(on) {
    clearInterval(holdT); holdT = null;
    if (on) { try { api.holdOpen(20000); } catch (e) { /* ignore */ } holdT = setInterval(() => { try { api.holdOpen(20000); } catch (e) { /* ignore */ } }, 8000); }
  }

  function fail(e) {
    const name = e && e.name || '';
    if (name === 'NotFoundError' || name === 'OverconstrainedError' || name === 'DevicesNotFoundError') setMsg('No camera found', false);
    else if (name === 'NotReadableError' || name === 'AbortError' || name === 'TrackStartError') setMsg('Camera is in use by another app', false);
    else if (name === 'NotAllowedError' || name === 'SecurityError' || name === 'PermissionDeniedError') setMsg('Camera access is blocked in Windows Settings > Privacy > Camera', true);
    else setMsg('Camera is not available', false);
    if (shutter) shutter.classList.add('cam-off');
  }

  async function startCam() {
    const my = ++gen;
    active = true;
    setHold(true);
    setMsg('Starting camera...', false);
    if (shutter) shutter.classList.add('cam-off');
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { setMsg('No camera found', false); return; }
      const s = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
      if (my !== gen || !active) { try { s.getTracks().forEach(t => t.stop()); } catch (e) { /* ignore */ } return; }
      stopStream();
      stream = s;
      video.srcObject = s;
      try { await video.play(); } catch (e) { if (my !== gen) return; /* autoplay quirks: still try to show */ }
      if (my !== gen || !active) return;
      setMsg('', false);
      shutter.classList.remove('cam-off');
      s.getTracks().forEach(t => t.addEventListener('ended', () => { if (my === gen && active) { stopStream(); setMsg('Camera disconnected', false); shutter.classList.add('cam-off'); } }));
    } catch (e) {
      if (my !== gen || !active) return;
      fail(e);
    }
  }

  function stopCam() {
    gen++; active = false;
    setHold(false);
    stopStream();
    if (shutter) shutter.classList.add('cam-off');
  }

  function fileUrl(p) { return encodeURI('file:///' + String(p).replace(/\\/g, '/').replace(/^\//, '')).replace(/#/g, '%23'); }

  async function checkThumb() {
    if (!thumb) return;
    if (!lastPhoto) { thumb.classList.remove('cam-on'); return; }
    let ok = false;
    try { ok = !!(await api.fileExists(lastPhoto)); } catch (e) { ok = false; }
    if (!ok) { lastPhoto = null; thumb.classList.remove('cam-on'); thumb.removeAttribute('src'); return; }
    thumb.classList.add('cam-on');
  }

  function canShoot() { return active && stream && video && video.videoWidth > 0 && video.videoHeight > 0; }

  async function snap() {
    if (busy || !canShoot()) return;
    busy = true;
    try {
      const w = video.videoWidth, h = video.videoHeight;
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      const ctx = c.getContext('2d');
      if (!ctx) throw new Error('no canvas');
      ctx.drawImage(video, 0, 0, w, h); // raw frame = not mirrored
      flash.classList.remove('go'); void flash.offsetWidth; flash.classList.add('go');
      const blob = await new Promise(res => { try { c.toBlob(res, 'image/png'); } catch (e) { res(null); } });
      if (!blob) { N.toast('Could not take the photo'); return; }
      const buf = await blob.arrayBuffer();
      const p = await api.photoSave(buf);
      if (!p) { N.toast('Could not save the photo'); return; }
      lastPhoto = p;
      thumb.src = fileUrl(p);
      thumb.classList.add('cam-on');
      N.toast('Saved to Pictures\\NOTCH');
    } catch (e) {
      N.toast('Could not take the photo');
    } finally { busy = false; }
  }

  async function openThumb() {
    if (!lastPhoto) return;
    let ok = false;
    try { ok = !!(await api.fileExists(lastPhoto)); } catch (e) { ok = false; }
    if (!ok) { await checkThumb(); N.toast('That photo was deleted'); return; }
    try { api.reveal(lastPhoto); } catch (e) { /* ignore */ }
  }

  document.addEventListener('keydown', e => {
    try {
      if (e.code !== 'Space' && e.key !== ' ') return;
      if (!N.open || !N.cur || N.cur.id !== 'camera') return;
      const t = e.target, tag = t && t.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable)) return;
      e.preventDefault();
      if (!e.repeat) snap();
    } catch (err) { /* ignore */ }
  });

  N.register({
    id: 'camera', name: 'Camera', icon: 'camera', size: [700, 300],
    mount(root) {
      video = el('video', { playsinline: '', muted: true, autoplay: true });
      video.muted = true;
      msgText = el('div', { text: '' });
      msgBtn = el('button', { class: 'btn', style: { display: 'none' }, onclick: () => { try { api.openExternal('ms-settings:privacy-webcam'); } catch (e) { /* ignore */ } } }, N.icon('external', 14), 'Open Privacy settings');
      msg = el('div', { class: 'cam-msg' }, N.icon('camera', 28), msgText, msgBtn);
      shutter = el('button', { class: 'shutter cam-off', title: 'Take photo (Space)', 'aria-label': 'Take photo', onclick: snap });
      thumb = el('img', { class: 'camthumb', alt: 'Last photo', title: 'Show in folder', onclick: openThumb });
      thumb.addEventListener('error', () => { thumb.classList.remove('cam-on'); });
      flash = el('div', { class: 'cam-flash' });
      root.appendChild(el('div', { class: 'cam' }, video, msg, flash, shutter, thumb));
    },
    show() { startCam(); checkThumb(); },
    hide() { stopCam(); }
  });
})();
