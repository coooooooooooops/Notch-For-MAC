'use strict';
// Weather: Open-Meteo (no key). All network goes through api.fetchJson (main restricts it to https *.open-meteo.com).
(function () {
  const N = window.N, el = N.el, api = N.api;
  // Test/demo hook: replace N.wx.fetch to feed canned responses. Must resolve {ok:true,data} or {ok:false,error}.
  N.wx = { fetch: u => api.fetchJson(u) };

  // <pure>
  const isNum = v => typeof v === 'number' && isFinite(v);
  const num = v => isNum(v) ? v : null;
  const KEY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
  const TIME_RE = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
  // WMO weather code -> text + icon kind
  function codeInfo(code, isDay) {
    const day = isDay !== false;
    switch (code) {
      case 0: return { text: 'Clear sky', kind: day ? 'sun' : 'moon' };
      case 1: return { text: 'Mainly clear', kind: day ? 'sun' : 'moon' };
      case 2: return { text: 'Partly cloudy', kind: day ? 'partly' : 'partlynight' };
      case 3: return { text: 'Overcast', kind: 'cloud' };
      case 45: return { text: 'Fog', kind: 'fog' };
      case 48: return { text: 'Freezing fog', kind: 'fog' };
      case 51: return { text: 'Light drizzle', kind: 'drizzle' };
      case 53: return { text: 'Drizzle', kind: 'drizzle' };
      case 55: return { text: 'Heavy drizzle', kind: 'drizzle' };
      case 56: case 57: return { text: 'Freezing drizzle', kind: 'drizzle' };
      case 61: return { text: 'Light rain', kind: 'rain' };
      case 63: return { text: 'Rain', kind: 'rain' };
      case 65: return { text: 'Heavy rain', kind: 'rain' };
      case 66: case 67: return { text: 'Freezing rain', kind: 'rain' };
      case 71: return { text: 'Light snow', kind: 'snow' };
      case 73: return { text: 'Snow', kind: 'snow' };
      case 75: return { text: 'Heavy snow', kind: 'snow' };
      case 77: return { text: 'Snow grains', kind: 'snow' };
      case 80: return { text: 'Light showers', kind: 'rain' };
      case 81: return { text: 'Showers', kind: 'rain' };
      case 82: return { text: 'Violent showers', kind: 'rain' };
      case 85: case 86: return { text: 'Snow showers', kind: 'snow' };
      case 95: return { text: 'Thunderstorm', kind: 'thunder' };
      case 96: case 99: return { text: 'Thunderstorm with hail', kind: 'thunder' };
      default: return { text: 'Unknown', kind: 'cloud' };
    }
  }
  const toUnit = (c, unit) => !isNum(c) ? null : (unit === 'F' ? c * 9 / 5 + 32 : c);
  const fmtTemp = (c, unit) => { const v = toUnit(c, unit); return v === null ? '-' : String(Math.round(v) + 0) + '°'; };
  const fmtWind = (kmh, unit) => !isNum(kmh) ? '-' : unit === 'F' ? Math.round(kmh * 0.621371) + ' mph' : Math.round(kmh) + ' km/h';
  const isNightHour = h => h < 6 || h >= 20;

  function parseForecast(j, nowStr) {
    if (!j || typeof j !== 'object') return null;
    const c = j.current;
    if (!c || typeof c !== 'object' || !isNum(c.temperature_2m)) return null;
    const cur = { t: c.temperature_2m, feels: num(c.apparent_temperature), hum: num(c.relative_humidity_2m), code: num(c.weather_code),
      wind: num(c.wind_speed_10m), isDay: c.is_day !== 0, time: typeof c.time === 'string' ? c.time : '' };
    const hours = [];
    const h = j.hourly;
    if (h && typeof h === 'object' && Array.isArray(h.time)) {
      const ref = TIME_RE.test(cur.time) ? cur.time : (nowStr || '');
      const refHour = ref.slice(0, 13);
      for (let i = 0; i < h.time.length && hours.length < 12; i++) {
        const m = TIME_RE.exec(typeof h.time[i] === 'string' ? h.time[i] : '');
        if (!m) continue;
        if (refHour && h.time[i].slice(0, 13) < refHour) continue;
        hours.push({ hour: +m[2], t: num(Array.isArray(h.temperature_2m) ? h.temperature_2m[i] : null), code: num(Array.isArray(h.weather_code) ? h.weather_code[i] : null) });
      }
    }
    const days = [];
    const d = j.daily;
    if (d && typeof d === 'object' && Array.isArray(d.time)) {
      for (let i = 0; i < d.time.length && days.length < 7; i++) {
        const m = KEY_RE.exec(typeof d.time[i] === 'string' ? d.time[i] : '');
        if (!m) continue;
        days.push({ y: +m[1], m: +m[2] - 1, d: +m[3], code: num(Array.isArray(d.weather_code) ? d.weather_code[i] : null),
          max: num(Array.isArray(d.temperature_2m_max) ? d.temperature_2m_max[i] : null), min: num(Array.isArray(d.temperature_2m_min) ? d.temperature_2m_min[i] : null) });
      }
    }
    return { cur, hours, days };
  }
  const placeKey = p => p.name + '|' + p.lat.toFixed(2) + '|' + p.lon.toFixed(2);
  function cleanPlace(r) {
    if (!r || typeof r !== 'object') return null;
    const lat = r.latitude !== undefined ? r.latitude : r.lat, lon = r.longitude !== undefined ? r.longitude : r.lon;
    if (!isNum(lat) || !isNum(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
    const name = typeof r.name === 'string' ? r.name.trim().slice(0, 80) : '';
    if (!name) return null;
    return { name, admin1: typeof r.admin1 === 'string' ? r.admin1.slice(0, 80) : '', country: typeof r.country === 'string' ? r.country.slice(0, 80) : '', lat, lon };
  }
  function parseGeo(j) {
    if (!j || typeof j !== 'object' || !Array.isArray(j.results)) return [];
    return j.results.map(cleanPlace).filter(Boolean).slice(0, 6);
  }
  function sanitizePlaces(a) {
    if (!Array.isArray(a)) return [];
    const seen = new Set(), out = [];
    a.forEach(r => { const p = cleanPlace(r); if (p && !seen.has(placeKey(p))) { seen.add(placeKey(p)); out.push(p); } });
    return out.slice(0, 25);
  }
  const placeLabel = p => [p.name, p.admin1 && p.admin1 !== p.name ? p.admin1 : '', p.country].filter(Boolean).join(', ');
  const geoUrl = q => 'https://geocoding-api.open-meteo.com/v1/search?name=' + encodeURIComponent(q) + '&count=6&language=en&format=json';
  const fcUrl = p => 'https://api.open-meteo.com/v1/forecast?latitude=' + encodeURIComponent(p.lat) + '&longitude=' + encodeURIComponent(p.lon) +
    '&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day&hourly=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=7';
  // </pure>
  N.__wxTest = { codeInfo, fmtTemp, fmtWind, parseForecast, parseGeo, sanitizePlaces, placeKey, geoUrl, fcUrl, placeLabel };

  // ---------------------------------------------------------------- icons (static inline SVG strings)
  const CLOUD = '<path d="M7 18a4 4 0 0 1-.6-7.96A5.6 5.6 0 0 1 17.2 9.4 4.3 4.3 0 0 1 17 18z" fill="#cfd3da"/>';
  const CLOUDD = '<path d="M7 18a4 4 0 0 1-.6-7.96A5.6 5.6 0 0 1 17.2 9.4 4.3 4.3 0 0 1 17 18z" fill="#98a0ab"/>';
  const SUN = '<circle cx="12" cy="12" r="4.2" fill="#ffd60a"/><g stroke="#ffd60a" stroke-width="1.8" stroke-linecap="round"><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/></g>';
  const SVG_KIND = {
    sun: SUN,
    moon: '<path d="M20 14.2A8.5 8.5 0 1 1 9.8 4a6.8 6.8 0 0 0 10.2 10.2z" fill="#e9e4c9"/>',
    partly: '<circle cx="9" cy="9" r="3.6" fill="#ffd60a"/><g stroke="#ffd60a" stroke-width="1.6" stroke-linecap="round"><path d="M9 2v1.6M2 9h1.6M4 4l1.2 1.2M14 4l-1.2 1.2"/></g><g transform="translate(2.5,3.5) scale(.82)">' + CLOUD + '</g>',
    partlynight: '<path d="M13 8.2A5 5 0 1 1 6.8 2.6a4 4 0 0 0 6.2 5.6z" fill="#e9e4c9"/><g transform="translate(2.5,3.5) scale(.82)">' + CLOUD + '</g>',
    cloud: CLOUD,
    fog: '<g transform="translate(0,-3)">' + CLOUD + '</g><g stroke="#cfd3da" stroke-width="1.8" stroke-linecap="round"><path d="M4 18.5h16M6 22h12"/></g>',
    drizzle: '<g transform="translate(0,-3)">' + CLOUDD + '</g><g stroke="#64d2ff" stroke-width="1.6" stroke-linecap="round"><path d="M8 17.5l-.6 1.6M12 17.5l-.6 1.6M16 17.5l-.6 1.6M10 20.5l-.6 1.6M14 20.5l-.6 1.6"/></g>',
    rain: '<g transform="translate(0,-3)">' + CLOUDD + '</g><g stroke="#64d2ff" stroke-width="1.9" stroke-linecap="round"><path d="M8 17.5l-1 3.5M12.5 17.5l-1 3.5M17 17.5l-1 3.5"/></g>',
    snow: '<g transform="translate(0,-3)">' + CLOUDD + '</g><g fill="#fff"><circle cx="8" cy="19" r="1.4"/><circle cx="12.5" cy="21.2" r="1.4"/><circle cx="17" cy="19" r="1.4"/></g>',
    thunder: '<g transform="translate(0,-3)">' + CLOUDD + '</g><path d="M13.5 13.5L9 19.5h3.2L10.8 24 16.5 17h-3.4z" fill="#ffd60a"/>'
  };
  function wxIcon(kind, size) {
    const s = el('span', { style: { display: 'inline-grid', placeItems: 'center', lineHeight: '0', flex: 'none' } });
    s.innerHTML = '<svg width="' + (size || 24) + '" height="' + (size || 24) + '" viewBox="0 0 24 24">' + (SVG_KIND[kind] || SVG_KIND.cloud) + '</svg>';
    return s;
  }

  const st = document.createElement('style');
  st.textContent = [
    '.wx-wrap { display: flex; flex-direction: column; gap: 8px; height: 100%; min-height: 0; }',
    '.wx-head { display: flex; gap: 6px; align-items: center; flex: none; }',
    '.wx-chips { flex: 1; min-width: 0; display: flex; gap: 5px; overflow-x: auto; overflow-y: hidden; padding-bottom: 2px; scrollbar-width: none; }',
    '.wx-chips::-webkit-scrollbar { display: none; }',
    '.wx-chips .btn { flex: none; max-width: 170px; overflow: hidden; text-overflow: ellipsis; }',
    '.wx-body { flex: 1; min-height: 0; display: flex; gap: 10px; }',
    '.wx-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }',
    '.wx-cur { flex: none; display: flex; align-items: center; gap: 14px; padding: 10px 14px; }',
    '.wx-temp { font-size: 42px; font-weight: 700; line-height: 1; letter-spacing: -1px; font-variant-numeric: tabular-nums; }',
    '.wx-status { font-size: 10.5px; color: var(--dim); margin-top: 2px; }',
    '.wx-status.off { color: #ffb74d; }',
    '.wx-hours { flex: 1; min-height: 0; display: flex; gap: 2px; overflow-x: auto; overflow-y: hidden; padding: 8px 6px; }',
    '.wx-h { flex: none; width: 52px; display: flex; flex-direction: column; align-items: center; justify-content: space-between; gap: 4px; font-variant-numeric: tabular-nums; }',
    '.wx-h b { font-size: 13px; }',
    '.wx-days { width: 218px; flex: none; display: flex; flex-direction: column; justify-content: space-between; padding: 8px 10px; }',
    '.wx-d { display: flex; align-items: center; gap: 8px; font-variant-numeric: tabular-nums; }',
    '.wx-d .dn { width: 44px; color: var(--dim); }',
    '.wx-d .hi { margin-left: auto; font-weight: 600; width: 32px; text-align: right; }',
    '.wx-d .lo { color: var(--dim); width: 32px; text-align: right; }',
    '.wx-msg { margin: auto; text-align: center; color: var(--dim); display: flex; flex-direction: column; align-items: center; gap: 10px; }',
    '.wx-search { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 8px; }',
    '.wx-res { flex: 1; min-height: 0; overflow: auto; display: flex; flex-direction: column; gap: 4px; }',
    '.wx-res .r { padding: 7px 10px; border-radius: 9px; background: rgba(255,255,255,.07); cursor: pointer; display: flex; justify-content: space-between; gap: 10px; }',
    '.wx-res .r:hover { background: rgba(255,255,255,.15); }',
    '.wx-res .r span:first-child { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }'
  ].join('\n');
  document.head.appendChild(st);

  // ---------------------------------------------------------------- state
  let places = sanitizePlaces(N.get('wxPlaces', []));
  let unit = N.get('wxUnit', 'C') === 'F' ? 'F' : 'C';
  let selKey = N.get('wxSel', '');
  const cache = {};            // key -> { at, fc }
  const loading = {};          // key -> true while fetching
  const failed = {};           // key -> error text of the latest failed refresh
  let adding = false, ui = null, shown = false, refreshT = null;
  let searchGen = 0, searchTimer = null;
  const STALE = 15 * 60 * 1000;

  const curPlace = () => places.find(p => placeKey(p) === selKey) || places[0] || null;
  function persistPlaces() { N.set('wxPlaces', places); N.set('wxSel', selKey); }
  const nowStr = () => N.dayKey() + 'T' + N.pad(new Date().getHours()) + ':00';
  function hourLabel(h) { try { return new Date(2000, 0, 1, h).toLocaleTimeString([], { hour: 'numeric' }); } catch (e) { return String(h); } }
  function dayLabel(d, i) {
    if (i === 0) return 'Today';
    try { return new Date(d.y, d.m, d.d).toLocaleDateString([], { weekday: 'short' }); } catch (e) { return ''; }
  }
  function errText(e) {
    const s = String(e || '');
    return /^HTTP/.test(s) ? 'The weather service is not responding right now.' : 'Can\'t reach the weather service. Check your internet connection.';
  }

  // ---------------------------------------------------------------- loading
  async function load(p, force) {
    if (!p) return;
    const k = placeKey(p);
    if (loading[k]) return;
    const c = cache[k];
    if (!force && c && Date.now() - c.at < STALE) return;
    loading[k] = true; delete failed[k];
    render();
    try {
      const r = await N.wx.fetch(fcUrl(p));
      if (!r || r.ok !== true) throw new Error(r && r.error ? r.error : 'network');
      const fc = parseForecast(r.data, nowStr());
      if (!fc) throw new Error('bad data');
      cache[k] = { at: Date.now(), fc };
    } catch (e) {
      failed[k] = errText(e && e.message);
    } finally {
      delete loading[k];
      render();
    }
  }

  // ---------------------------------------------------------------- search
  async function runSearch() {
    const q = ui.input.value.trim();
    const my = ++searchGen;
    N.clear(ui.res);
    if (q.length < 2) { ui.res.appendChild(el('div', { class: 'wx-msg', text: 'Type at least 2 letters of a city name' })); return; }
    ui.res.appendChild(el('div', { class: 'wx-msg', text: 'Searching...' }));
    let list = null, err = '';
    try {
      const r = await N.wx.fetch(geoUrl(q));
      if (!r || r.ok !== true) err = errText(r && r.error);
      else list = parseGeo(r.data);
    } catch (e) { err = errText(e && e.message); }
    if (my !== searchGen) return;
    N.clear(ui.res);
    if (err) { ui.res.appendChild(el('div', { class: 'wx-msg err', text: err })); return; }
    if (!list.length) { ui.res.appendChild(el('div', { class: 'wx-msg', text: 'No places found for "' + q.slice(0, 40) + '"' })); return; }
    list.forEach(p => ui.res.appendChild(el('div', { class: 'r', onclick: () => addPlace(p) },
      el('span', { text: [p.name, p.admin1 && p.admin1 !== p.name ? p.admin1 : ''].filter(Boolean).join(', ') }), el('span', { class: 'dim', text: p.country }))));
  }
  function addPlace(p) {
    const k = placeKey(p);
    if (!places.some(x => placeKey(x) === k)) {
      if (places.length >= 25) { N.toast('Remove a place before adding another'); return; }
      places.push(p);
    }
    selKey = k; adding = false; persistPlaces();
    render(); load(p, true);
  }
  function removePlace(p) {
    const k = placeKey(p);
    places = places.filter(x => placeKey(x) !== k);
    delete cache[k]; delete failed[k];
    if (selKey === k) selKey = places[0] ? placeKey(places[0]) : '';
    persistPlaces();
    render();
    const c = curPlace(); if (c) load(c, false);
  }
  function openSearch() {
    adding = true; render();
    ui.input.value = ''; N.clear(ui.res);
    ui.res.appendChild(el('div', { class: 'wx-msg', text: 'Search for a city to see its weather' }));
    setTimeout(() => { try { ui.input.focus({ preventScroll: true }); } catch (e) { /* ignore */ } }, 30);
  }

  // ---------------------------------------------------------------- render
  function renderChips() {
    N.clear(ui.chips);
    places.forEach(p => {
      const k = placeKey(p), on = !adding && curPlace() && placeKey(curPlace()) === k;
      const b = el('button', { class: 'btn' + (on ? ' sel' : ''), title: placeLabel(p) + ' (right-click to remove)', text: p.name,
        onclick: () => { selKey = k; adding = false; N.set('wxSel', selKey); render(); load(p, false); } });
      b.addEventListener('contextmenu', e => N.menu(e, [{ label: 'Remove ' + p.name, danger: true, fn: () => removePlace(p) }]));
      ui.chips.appendChild(b);
    });
  }

  function renderWeather(p) {
    const box = N.clear(ui.view);
    const k = placeKey(p), c = cache[k];
    if (!c) {
      if (loading[k]) box.appendChild(el('div', { class: 'wx-msg', text: 'Loading weather...' }));
      else box.appendChild(el('div', { class: 'wx-msg' }, el('div', { class: 'err', text: failed[k] || 'No weather data yet.' }),
        el('button', { class: 'btn', onclick: () => load(p, true) }, N.icon('reload', 14), 'Try again')));
      return;
    }
    const fc = c.fc, cur = fc.cur, info = codeInfo(cur.code, cur.isDay);
    let status = 'Updated ' + new Date(c.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }), off = false;
    if (failed[k]) { status = 'Offline - showing last update'; off = true; }
    else if (loading[k]) status = 'Refreshing...';
    const curCard = el('div', { class: 'card wx-cur' },
      wxIcon(info.kind, 56),
      el('div', null, el('div', { class: 'wx-temp', text: fmtTemp(cur.t, unit) + unit })),
      el('div', { class: 'grow' },
        el('div', { class: 'h', text: info.text, style: { fontSize: '15px' } }),
        el('div', { class: 'dim small', text: placeLabel(p) }),
        el('div', { class: 'small', style: { marginTop: '3px' }, text: 'Feels ' + fmtTemp(cur.feels, unit) + '   Humidity ' + (cur.hum === null ? '-' : Math.round(cur.hum) + '%') + '   Wind ' + fmtWind(cur.wind, unit) }),
        el('div', { class: 'wx-status' + (off ? ' off' : ''), text: status })));
    const hours = el('div', { class: 'card wx-hours' });
    hours.addEventListener('wheel', e => { if (e.deltaY) { hours.scrollLeft += e.deltaY; e.preventDefault(); } }, { passive: false });
    if (!fc.hours.length) hours.appendChild(el('div', { class: 'wx-msg dim', text: 'Hourly forecast unavailable' }));
    fc.hours.forEach((h, i) => hours.appendChild(el('div', { class: 'wx-h' },
      el('span', { class: 'dim small', text: i === 0 ? 'Now' : hourLabel(h.hour) }),
      wxIcon(codeInfo(h.code, !isNightHour(h.hour)).kind, 22),
      el('b', { text: fmtTemp(h.t, unit) }))));
    const days = el('div', { class: 'card wx-days' });
    if (!fc.days.length) days.appendChild(el('div', { class: 'wx-msg dim', text: '7-day forecast unavailable' }));
    fc.days.forEach((d, i) => days.appendChild(el('div', { class: 'wx-d', title: codeInfo(d.code, true).text },
      el('span', { class: 'dn', text: dayLabel(d, i) }), wxIcon(codeInfo(d.code, true).kind, 20),
      el('span', { class: 'hi', text: fmtTemp(d.max, unit) }), el('span', { class: 'lo', text: fmtTemp(d.min, unit) }))));
    box.appendChild(el('div', { class: 'wx-body' }, el('div', { class: 'wx-main' }, curCard, hours), days));
  }

  function render() {
    if (!ui) return;
    const p = curPlace();
    const search = adding || !p;
    ui.search.style.display = search ? 'flex' : 'none';
    ui.view.style.display = search ? 'none' : 'flex';
    ui.unitBtn.textContent = '°' + unit;
    ui.cancel.style.display = adding && p ? '' : 'none';
    ui.add.style.display = adding || !p ? 'none' : '';
    ui.refresh.style.display = search ? 'none' : '';
    ui.unitBtn.style.display = search ? 'none' : '';
    renderChips();
    if (!search) renderWeather(p);
    else if (!p && !adding && !ui.input.value && !ui.res.firstChild) {
      ui.res.appendChild(el('div', { class: 'wx-msg', text: 'Search for a city to see its weather' }));
    }
  }

  N.register({
    id: 'weather', name: 'Weather', icon: 'weather', size: [700, 330],
    mount(root) {
      ui = {};
      ui.chips = el('div', { class: 'wx-chips' });
      ui.add = el('button', { class: 'btn icon', title: 'Add a place', 'aria-label': 'Add a place', onclick: openSearch }, N.icon('plus', 14));
      ui.cancel = el('button', { class: 'btn icon', title: 'Cancel', 'aria-label': 'Cancel', style: { display: 'none' }, onclick: () => { adding = false; searchGen++; render(); const c = curPlace(); if (c) load(c, false); } }, N.icon('x', 14));
      ui.refresh = el('button', { class: 'btn icon', title: 'Refresh', 'aria-label': 'Refresh', onclick: () => { const c = curPlace(); if (c) load(c, true); } }, N.icon('reload', 14));
      ui.unitBtn = el('button', { class: 'btn', title: 'Switch between Celsius and Fahrenheit', onclick: () => { unit = unit === 'C' ? 'F' : 'C'; N.set('wxUnit', unit); render(); } });
      ui.view = el('div', { style: { flex: '1', minHeight: '0', display: 'flex', flexDirection: 'column' } });
      ui.input = el('input', { type: 'search', placeholder: 'Search for a city', maxlength: '60', style: { flex: '1' } });
      ui.input.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') { e.preventDefault(); clearTimeout(searchTimer); runSearch(); } });
      ui.input.addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { if (ui.input.value.trim().length >= 2) runSearch(); }, 450); });
      ui.res = el('div', { class: 'wx-res' });
      ui.search = el('div', { class: 'wx-search', style: { display: 'none' } },
        el('div', { class: 'row' }, ui.input, el('button', { class: 'btn primary', onclick: () => { clearTimeout(searchTimer); runSearch(); } }, N.icon('search', 14), 'Search')), ui.res);
      root.appendChild(el('div', { class: 'wx-wrap' },
        el('div', { class: 'wx-head' }, ui.chips, ui.add, ui.cancel, ui.refresh, ui.unitBtn), ui.view, ui.search));
      render();
    },
    show() {
      shown = true;
      render();
      const p = curPlace();
      if (p && !adding) load(p, false);
      clearInterval(refreshT);
      refreshT = setInterval(() => { const c = curPlace(); if (shown && c && !adding) load(c, false); }, 5 * 60 * 1000);
    },
    hide() { shown = false; clearInterval(refreshT); refreshT = null; clearTimeout(searchTimer); }
  });
})();
