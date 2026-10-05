'use strict';
// Music: what Windows says is playing (Spotify, Apple Music, browsers, etc.) via the system media session.
(function () {
  const N = window.N, el = N.el, api = N.api;
  const M = N.media = { has: false, title: '', artist: '', app: '', playing: false, pos: 0, dur: 0, thumb: null, key: '', at: 0, ok: true };
  let ui = null, seeking = false, lastKeyShown = '', failStreak = 0;

  function appName(id) {
    if (!id) return '';
    let s = String(id).replace(/\.exe$/i, '').replace(/^.*!/, '').replace(/^.*\./, '');
    if (/chrome/i.test(id)) s = 'Chrome'; else if (/msedge/i.test(id)) s = 'Edge'; else if (/spotify/i.test(id)) s = 'Spotify'; else if (/firefox/i.test(id)) s = 'Firefox';
    else if (/applemusic|itunes/i.test(id)) s = 'Apple Music'; else if (/zune|media/i.test(id)) s = 'Media Player';
    return s;
  }
  function curPos() { return M.dur > 0 ? Math.min(M.dur, M.pos + (M.playing ? (Date.now() - M.at) / 1000 : 0)) : 0; }

  async function poll() {
    try {
      const r = await api.bridge('media', { haveKey: M.key });
      if (r && r.ok && r.data) {
        failStreak = 0; M.ok = true;
        const d = r.data;
        if (d.has) {
          if (d.thumb) M.thumb = d.thumb;
          if (d.key !== M.key) { M.key = d.key; if (!d.thumb) M.thumb = null; }
          Object.assign(M, { has: true, title: d.title || 'Unknown', artist: d.artist || '', app: appName(d.app), playing: !!d.playing, pos: d.pos || 0, dur: d.dur || 0, at: Date.now() });
        } else { Object.assign(M, { has: false, playing: false, key: '', thumb: null }); }
      } else if (r && r.error !== 'timeout') { failStreak++; if (failStreak > 3) { M.ok = false; M.has = false; M.playing = false; } }
    } catch (e) { /* keep last state */ }
    liveUpdate();
    if (N.open && N.cur && N.cur.id === 'music') render();
  }
  function liveUpdate() {
    if (M.has && M.playing) N.live('music', { prio: 1, bars: true, left: M.title });
    else N.live('music', null);
  }

  function render() {
    if (!ui) return;
    ui.title.textContent = M.has ? M.title : (M.ok ? 'Nothing playing' : 'Music info unavailable');
    ui.artist.textContent = M.has ? [M.artist, M.app].filter(Boolean).join('  ·  ') : (M.ok ? 'Play something in Spotify, a browser or any media app' : 'Playback controls still work with your media keys');
    if (M.thumb) { if (lastKeyShown !== M.key) { ui.art.style.backgroundImage = 'url("' + M.thumb + '")'; ui.art.textContent = ''; lastKeyShown = M.key; } }
    else { ui.art.style.backgroundImage = ''; ui.art.textContent = ''; ui.art.appendChild(N.icon('music', 34)); lastKeyShown = ''; }
    ui.bars.className = 'bars' + (M.playing ? ' on' : '');
    N.clear(ui.play); ui.play.appendChild(N.icon(M.playing ? 'pause' : 'play', 18));
    const has = M.has && M.dur > 0;
    ui.seekRow.style.visibility = has ? 'visible' : 'hidden';
    if (has && !seeking) {
      const p = curPos();
      ui.seek.max = String(Math.round(M.dur)); ui.seek.value = String(Math.round(p));
      ui.t1.textContent = N.mmss(p); ui.t2.textContent = '-' + N.mmss(M.dur - p);
    }
  }

  async function ctl(action) {
    const r = await api.bridge('mediaCtl', { action });
    if (!r || !r.ok) N.toast('Could not control playback');
    setTimeout(poll, 250);
  }

  N.register({
    id: 'music', name: 'Music', icon: 'music', size: [700, 190],
    mount(root) {
      ui = {
        art: el('div', { class: 'art' }),
        title: el('div', { class: 'mtitle' }), artist: el('div', { class: 'dim small', style: { whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } }),
        bars: el('span', { class: 'bars' }, [0, 1, 2, 3].map(() => el('i'))),
        play: el('button', { class: 'big', title: 'Play / pause', onclick: () => ctl('toggle') }),
        seek: el('input', { type: 'range', min: '0', max: '100', value: '0', step: '1' }),
        t1: el('span', { class: 'tiny dim', text: '0:00' }), t2: el('span', { class: 'tiny dim', text: '-0:00' })
      };
      ui.seek.addEventListener('input', () => { seeking = true; ui.t1.textContent = N.mmss(Number(ui.seek.value)); ui.t2.textContent = '-' + N.mmss(M.dur - Number(ui.seek.value)); });
      ui.seek.addEventListener('change', async () => {
        const v = Number(ui.seek.value);
        const r = await api.bridge('seek', { seconds: v });
        if (r && r.ok) { M.pos = v; M.at = Date.now(); } else N.toast("This app doesn't allow seeking");
        seeking = false; setTimeout(poll, 300);
      });
      ui.seekRow = el('div', { class: 'row' }, ui.t1, el('div', { class: 'grow' }, ui.seek), ui.t2);
      root.appendChild(el('div', { class: 'music' }, ui.art,
        el('div', { class: 'grow', style: { display: 'flex', flexDirection: 'column', gap: '7px', minWidth: 0 } },
          el('div', { class: 'row' }, el('div', { class: 'grow', style: { minWidth: 0 } }, ui.title), ui.bars),
          ui.artist, ui.seekRow,
          el('div', { class: 'ctl' },
            el('button', { title: 'Previous', onclick: () => ctl('prev') }, N.icon('prev', 18)), ui.play,
            el('button', { title: 'Next', onclick: () => ctl('next') }, N.icon('next', 18))))));
    },
    show() { render(); poll(); },
    hide() { seeking = false; }
  });

  N.startMusic = function () {
    poll();
    setInterval(() => { poll(); }, 1500);
    setInterval(() => { if (N.open && N.cur && N.cur.id === 'music' && M.has && M.playing && !seeking) render(); }, 500);
  };
})();
