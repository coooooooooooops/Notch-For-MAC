'use strict';
// Control Centre: quick tiles that open the matching Windows settings, dark mode, screenshot, sleep display, and sliders.
(function () {
  const N = window.N, el = N.el, api = N.api;
  let ui = null, caps = {}, dark = null, vol = { volume: 50, mute: false, ok: false }, bright = { v: 50, ok: false };
  let dragging = false;

  const open = async (url, msg) => { const ok = await api.openExternal(url); if (!ok) N.toast('Could not open that'); else if (msg) N.toast(msg); };

  function tile(icon, label, onclick, id) {
    const b = el('button', { class: 'ctile', 'data-id': id || label, onclick: () => { try { onclick(b); } catch (e) { console.error(e); } } }, N.icon(icon, 20), el('span', { text: label }));
    return b;
  }

  async function refresh() {
    try {
      caps = (await api.bridgeCaps()) || {};
      const d = await api.bridge('getDark');
      dark = d && d.ok ? !!d.data : null;
      const v = await api.bridge('getVolume');
      vol = v && v.ok && v.data ? { volume: Number(v.data.volume) || 0, mute: !!v.data.mute, ok: true } : { volume: 0, mute: false, ok: false };
      const b = await api.bridge('getBrightness');
      bright = b && b.ok ? { v: Number(b.data) || 0, ok: true } : { v: 0, ok: false };
    } catch (e) { /* keep defaults */ }
    paint();
  }

  function paint() {
    if (!ui) return;
    ui.dark.classList.toggle('on', dark === true);
    ui.dark.disabled = dark === null;
    ui.dark.lastChild.textContent = dark === null ? 'Dark mode (n/a)' : 'Dark mode';
    ui.vol.disabled = !vol.ok; ui.bri.disabled = !bright.ok;
    if (!dragging) { ui.vol.value = String(vol.mute ? 0 : vol.volume); ui.bri.value = String(bright.v); }
    N.clear(ui.speaker); ui.speaker.appendChild(N.icon(vol.mute || vol.volume === 0 ? 'mute' : 'volume', 18));
    ui.speaker.disabled = !vol.ok;
    ui.volTxt.textContent = vol.ok ? (vol.mute ? 'Muted' : vol.volume + '%') : 'Unavailable';
    ui.briTxt.textContent = bright.ok ? bright.v + '%' : 'Built-in display only';
    const b = N.battery;
    ui.batt.textContent = b ? 'Battery ' + b.pct + '%' + (b.charging ? ' - charging' : '') : 'No battery';
  }

  const sendVol = N.debounce(async v => { const r = await api.bridge('setVolume', { value: v }); if (r && r.ok) { vol.volume = v; vol.mute = false; } paint(); }, 80);
  const sendBri = N.debounce(async v => { const r = await api.bridge('setBrightness', { value: v }); if (r && r.ok) bright.v = v; else N.toast("Windows won't change this display's brightness"); paint(); }, 120);

  N.register({
    id: 'control', name: 'Control Centre', icon: 'control', size: [700, 300],
    mount(root) {
      ui = {};
      ui.dark = tile('moon', 'Dark mode', async () => {
        const r = await api.bridge('setDark', { value: !dark });
        if (r && r.ok) { dark = !dark; paint(); } else N.toast("Couldn't change the theme");
      }, 'dark');
      const grid = el('div', { style: { display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '8px' } },
        tile('wifi', 'Wi-Fi', () => open('ms-settings:network-wifi'), 'wifi'),
        tile('bt', 'Bluetooth', () => open('ms-settings:bluetooth'), 'bt'),
        ui.dark,
        tile('moon', 'Night light', () => open('ms-settings:nightlight'), 'night'),
        tile('power', 'Battery saver', () => open('ms-settings:batterysaver'), 'saver'),
        tile('shot', 'Screenshot', () => { api.holdOpen(8000); open('ms-screenclip:', 'Drag to snip - it goes to your clipboard'); setTimeout(() => N.requestClose(), 400); }, 'shot'),
        tile('eyeoff', 'Sleep display', async () => { const r = await api.bridge('screenOff'); if (!r || !r.ok) N.toast("Couldn't turn the display off"); }, 'screenoff'),
        tile('settings', 'Settings', () => open('ms-settings:'), 'winset'));
      ui.vol = el('input', { type: 'range', min: '0', max: '100', step: '1', value: '50' });
      ui.bri = el('input', { type: 'range', min: '0', max: '100', step: '1', value: '50' });
      ui.vol.addEventListener('input', () => { dragging = true; ui.volTxt.textContent = ui.vol.value + '%'; sendVol(Number(ui.vol.value)); });
      ui.bri.addEventListener('input', () => { dragging = true; ui.briTxt.textContent = ui.bri.value + '%'; sendBri(Number(ui.bri.value)); });
      ['change', 'pointerup'].forEach(ev => { ui.vol.addEventListener(ev, () => { dragging = false; }); ui.bri.addEventListener(ev, () => { dragging = false; }); });
      ui.speaker = el('button', { class: 'pillbtn', title: 'Mute / unmute', onclick: async () => {
        const r = await api.bridge('setMute', { value: !vol.mute }); if (r && r.ok) { vol.mute = !vol.mute; paint(); } else N.toast("Couldn't change the volume");
      } });
      ui.volTxt = el('span', { class: 'dim small', style: { width: '70px', textAlign: 'right' } });
      ui.briTxt = el('span', { class: 'dim small', style: { width: '70px', textAlign: 'right' } });
      ui.batt = el('span', { class: 'dim small' });
      root.appendChild(el('div', { style: { display: 'flex', flexDirection: 'column', gap: '12px', height: '100%' } }, grid,
        el('div', { class: 'row' }, el('span', { style: { width: '26px', display: 'grid', placeItems: 'center' } }, N.icon('sun', 18)), el('div', { class: 'grow' }, ui.bri), ui.briTxt),
        el('div', { class: 'row' }, ui.speaker, el('div', { class: 'grow' }, ui.vol), ui.volTxt),
        ui.batt));
      paint();
    },
    show() { refresh(); },
    hide() { dragging = false; }
  });
})();
