'use strict';
const { app, BrowserWindow, Tray, Menu, screen, ipcMain, globalShortcut, clipboard, nativeImage, shell, dialog, session, net } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { Bridge } = require('./bridge');
const { Updater } = require('./updater');
const core = require('./updater-core');

const IS_WIN = process.platform === 'win32';
if (process.env.NOTCH_USER_DATA) app.setPath('userData', process.env.NOTCH_USER_DATA);
app.setName('NOTCH');

// ---------------------------------------------------------------- logging (never shows a dialog)
let logFile = null;
function log(msg) {
  try {
    if (!logFile) logFile = path.join(app.getPath('userData'), 'notch.log');
    try { if (fs.statSync(logFile).size > 800000) fs.renameSync(logFile, logFile + '.old'); } catch (e) { /* new file */ }
    fs.appendFileSync(logFile, '[' + new Date().toISOString() + '] ' + msg + '\n');
  } catch (e) { /* ignore */ }
}
process.on('uncaughtException', e => log('uncaughtException: ' + (e && e.stack || e)));
process.on('unhandledRejection', e => log('unhandledRejection: ' + (e && e.stack || e)));

// ---------------------------------------------------------------- settings store (JSON, atomic writes)
class Store {
  constructor(file) {
    this.file = file; this.data = {}; this.t = null;
    try { this.data = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; }
    catch (e) {
      if (e.code !== 'ENOENT') { try { fs.renameSync(file, file + '.bad-' + Date.now()); } catch (e2) { /* ignore */ } }
      this.data = {};
    }
  }
  get(k, d) { return Object.prototype.hasOwnProperty.call(this.data, k) ? this.data[k] : d; }
  set(k, v) { if (v === undefined || v === null) delete this.data[k]; else this.data[k] = v; this._q(); }
  _q() { clearTimeout(this.t); this.t = setTimeout(() => this.flush(), 400); }
  flush() {
    clearTimeout(this.t);
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = this.file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(this.data));
      fs.renameSync(tmp, this.file);
    } catch (e) { log('settings save failed: ' + e.message); }
  }
}

let store, win, tray, bridge, updater;
let ready = false, quitting = false;

// ---------------------------------------------------------------- notch window
const MAX_W = 900, MAX_H = 560;
let shrinkTimer = null;
const st = { open: false, forced: false, collapsed: { w: 140, h: 8 }, panel: { w: 660, h: 210 }, closing: null, holdUntil: 0 };
let hoverSince = 0, leaveSince = 0, clickMode = false;

function disp() { return screen.getPrimaryDisplay(); }

function applyBounds() {
  if (!win || win.isDestroyed()) return;
  const b = disp().bounds;
  let w, h;
  if (st.open) { w = Math.round(st.panel.w); h = Math.round(st.panel.h); } else { w = Math.round(st.collapsed.w); h = Math.round(st.collapsed.h); }
  w = Math.max(20, Math.min(w, b.width)); h = Math.max(2, Math.min(h, b.height));
  win.setBounds({ x: Math.round(b.x + b.width / 2 - w / 2), y: b.y, width: w, height: h });
}

function send(ch, payload) {
  try { if (win && !win.isDestroyed() && !win.webContents.isDestroyed()) win.webContents.send(ch, payload); } catch (e) { /* ignore */ }
}

function openNotch(forced, goto) {
  if (!win || win.isDestroyed() || !ready) return;
  if (st.closing) { clearTimeout(st.closing); st.closing = null; }
  if (forced) st.forced = true;
  if (!st.open) {
    st.open = true;
    applyBounds();
    leaveSince = 0;
  }
  send('open', { forced: st.forced, goto: goto || null });
  if (forced) { try { win.show(); win.focus(); } catch (e) { /* ignore */ } }
}

function closeNotch() {
  if (!st.open || st.closing) return;
  st.forced = false;
  send('close');
  // the page animates shut and tells us ('collapsed'); this is the safety net if it never does
  st.closing = setTimeout(finishClose, 600);
}
function finishClose() {
  if (st.closing) { clearTimeout(st.closing); st.closing = null; }
  st.open = false;
  applyBounds();
  try { if (win && !win.isDestroyed()) { win.setAlwaysOnTop(true, 'screen-saver'); win.showInactive(); } } catch (e) { /* ignore */ }
}

function toggleNotch(goto) {
  if (st.open && !st.closing && st.forced) closeNotch();
  else openNotch(true, goto);
}

function tick() {
  if (!win || win.isDestroyed() || !ready) return;
  const p = screen.getCursorScreenPoint();
  const b = disp().bounds;
  const cx = b.x + b.width / 2;
  if (!st.open) {
    if (clickMode) return;
    const inHot = Math.abs(p.x - cx) <= st.collapsed.w / 2 + 6 && p.y >= b.y - 2 && p.y <= b.y + Math.max(st.collapsed.h, 6) + 2;
    if (inHot) {
      if (!hoverSince) hoverSince = Date.now();
      else if (Date.now() - hoverSince >= 110) { hoverSince = 0; openNotch(false); }
    } else hoverSince = 0;
  } else if (!st.forced && !st.closing) {
    if (Date.now() < st.holdUntil) { leaveSince = 0; return; }
    const inside = Math.abs(p.x - cx) <= st.panel.w / 2 + 14 && p.y >= b.y && p.y <= b.y + st.panel.h + 14;
    if (inside) leaveSince = 0;
    else if (!leaveSince) leaveSince = Date.now();
    else if (Date.now() - leaveSince >= 260) { leaveSince = 0; closeNotch(); }
  }
}

function createWindow() {
  win = new BrowserWindow({
    width: st.collapsed.w, height: st.collapsed.h, x: 0, y: 0,
    show: false, frame: false, transparent: true, backgroundColor: '#00000000', hasShadow: false,
    resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false,
    skipTaskbar: true, alwaysOnTop: true, thickFrame: false, minWidth: 1, minHeight: 1,
    type: IS_WIN ? 'toolbar' : undefined,
    icon: path.join(__dirname, 'assets', 'icon.png'),
    title: 'NOTCH',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true, webviewTag: true, spellcheck: false,
      backgroundThrottling: false
    }
  });
  win.setMenuBarVisibility(false);
  win.setAlwaysOnTop(true, 'screen-saver');
  try { win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true }); } catch (e) { /* ignore */ }
  win.loadFile(path.join(__dirname, 'src', 'index.html'));
  win.webContents.on('did-finish-load', () => { /* renderer sends 'ready' */ });
  win.webContents.on('render-process-gone', (e, d) => {
    log('renderer gone: ' + d.reason);
    ready = false; st.open = false;
    if (!quitting && win && !win.isDestroyed()) { applyBounds(); win.webContents.reload(); }
  });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) e.preventDefault(); });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.on('blur', () => { if (st.open && st.forced) setTimeout(() => { if (st.open && st.forced && win && !win.isDestroyed() && !win.isFocused()) closeNotch(); }, 150); });
  win.on('closed', () => { win = null; });
  win.on('close', e => { if (!quitting) e.preventDefault(); });   // Alt+F4 must not kill the notch
}

// ---------------------------------------------------------------- web content safety (embedded tabs)
const WEB_PARTITION = 'persist:notch-web';
const AUTH_HOSTS = /(^|\.)(accounts\.google\.com|login\.microsoftonline\.com|login\.live\.com|appleid\.apple\.com|facebook\.com|github\.com|discord\.com|slack\.com|accounts\.spotify\.com|auth0\.com|okta\.com|openai\.com|anthropic\.com|claude\.ai|x\.com|twitter\.com)$/i;

function chromeUA() {
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/' + process.versions.chrome + ' Safari/537.36';
}

function setupSessions() {
  const ws = session.fromPartition(WEB_PARTITION);
  ws.setUserAgent(chromeUA());
  const asked = new Map();
  ws.setPermissionRequestHandler((wc, perm, cb, details) => {
    try {
      if (perm === 'fullscreen' || perm === 'clipboard-sanitized-write' || perm === 'clipboard-read' || perm === 'notifications' || perm === 'pointerLock' || perm === 'speaker-selection') return cb(true);
      if (perm === 'media' || perm === 'mediaKeySystem') {
        let origin = ''; try { origin = new URL(details.requestingUrl || wc.getURL()).origin; } catch (e) { /* ignore */ }
        const key = perm + '|' + origin;
        const saved = store.get('permGrants', {});
        if (saved[key] === true) return cb(true);
        if (saved[key] === false) return cb(false);
        if (asked.has(key)) return asked.get(key).then(cb);
        const pr = dialog.showMessageBox({ type: 'question', buttons: ['Allow', 'Block'], defaultId: 1, cancelId: 1, title: 'NOTCH',
          message: origin + ' wants to use your camera or microphone.', detail: 'You can change this later by clearing site permissions in NOTCH > Settings.' })
          .then(r => { const ok = r.response === 0; saved[key] = ok; store.set('permGrants', saved); asked.delete(key); return ok; })
          .catch(() => false);
        asked.set(key, pr);
        return pr.then(cb);
      }
      cb(false);
    } catch (e) { cb(false); }
  });
  // the notch's own page may use the camera (Camera tab); nothing else
  session.defaultSession.setPermissionRequestHandler((wc, perm, cb) => {
    cb(!!win && !win.isDestroyed() && wc === win.webContents && perm === 'media');
  });
  session.defaultSession.setPermissionCheckHandler((wc, perm) => !!win && !win.isDestroyed() && wc === win.webContents && perm === 'media');
}

app.on('web-contents-created', (e, contents) => {
  contents.on('will-attach-webview', (ev, webPreferences, params) => {
    delete webPreferences.preload; delete webPreferences.preloadURL;
    webPreferences.nodeIntegration = false; webPreferences.nodeIntegrationInSubFrames = false;
    webPreferences.contextIsolation = true; webPreferences.sandbox = true; webPreferences.webSecurity = true;
    params.partition = WEB_PARTITION;
    if (!/^https?:/i.test(params.src || 'about:blank') && params.src !== 'about:blank') ev.preventDefault();
  });
  if (contents.getType() === 'webview') {
    contents.setWindowOpenHandler(({ url }) => {
      let u; try { u = new URL(url); } catch (e) { return { action: 'deny' }; }
      if (!/^https?:$/.test(u.protocol)) return { action: 'deny' };
      if (AUTH_HOSTS.test(u.hostname)) {
        return { action: 'allow', overrideBrowserWindowOptions: { width: 520, height: 720, autoHideMenuBar: true, alwaysOnTop: false, skipTaskbar: false, title: 'Sign in' } };
      }
      setImmediate(() => { try { contents.loadURL(url); } catch (e2) { /* ignore */ } });
      return { action: 'deny' };
    });
    contents.on('will-navigate', (ev, url) => { if (!/^(https?:|about:)/i.test(url)) ev.preventDefault(); });
  }
});

// ---------------------------------------------------------------- tray + login item
function loginEnabled() {
  try { return !!app.getLoginItemSettings().openAtLogin; } catch (e) { return false; }
}
function setLogin(on) {
  try { app.setLoginItemSettings({ openAtLogin: !!on, path: process.execPath, args: [] }); } catch (e) { log('login item failed: ' + e.message); }
  buildTray();
}
function hotkeyLabels() {
  const hk = store.get('hotkeys', {});
  return [['Open / close NOTCH', hk.toggle], ['Ask AI', hk.ai], ['Clipboard', hk.clip]].map(([n, v]) => n + ':  ' + (v ? v.replace('Control', 'Ctrl') : 'off'));
}
function buildTray() {
  try {
    if (!tray) {
      const img = nativeImage.createFromPath(path.join(__dirname, 'assets', IS_WIN ? 'tray.png' : 'tray16.png'));
      tray = new Tray(img);
      tray.setToolTip('NOTCH');
      tray.on('click', () => toggleNotch());
    }
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open NOTCH', click: () => openNotch(true) },
      { type: 'separator' },
      { label: 'Launch at Login', type: 'checkbox', checked: loginEnabled(), click: m => setLogin(m.checked) },
      { label: 'Click to Expand (instead of hover)', type: 'checkbox', checked: clickMode, click: m => { setClickMode(m.checked); send('cfg-changed', { key: 'clickMode', value: m.checked }); } },
      { label: 'Hotkeys', submenu: hotkeyLabels().map(l => ({ label: l, enabled: false })) },
      { type: 'separator' },
      { label: 'Check for updates', click: () => { openNotch(true, 'updater'); updater && updater.check(true); } },
      { label: 'Open data folder', click: () => shell.openPath(app.getPath('userData')) },
      { type: 'separator' },
      { label: 'Quit NOTCH', click: () => { quitting = true; app.quit(); } }
    ]));
  } catch (e) { log('tray failed: ' + e.message); }
}
function setClickMode(v) { clickMode = !!v; store.set('clickMode', clickMode); buildTray(); }

// ---------------------------------------------------------------- hotkeys (Control + Alt + key only)
const DEFAULT_HK = { toggle: 'Control+Alt+N', ai: 'Control+Alt+A', clip: 'Control+Alt+V' };
const registered = {};
function validAccel(a) { return typeof a === 'string' && /^Control\+Alt\+[A-Z0-9]$/.test(a); }
function actionFor(name) {
  if (name === 'toggle') return () => toggleNotch();
  if (name === 'ai') return () => { openNotch(true, 'ai'); send('focus-ai'); };
  return () => openNotch(true, 'clip');
}
function applyHotkey(name, accel) {
  if (registered[name]) { try { globalShortcut.unregister(registered[name]); } catch (e) { /* ignore */ } registered[name] = null; }
  if (!accel) return { ok: true };
  if (!validAccel(accel)) return { ok: false, reason: 'Use Control + Alt together with a letter or number' };
  for (const k of Object.keys(registered)) if (k !== name && registered[k] === accel) return { ok: false, reason: 'Already used by another NOTCH hotkey' };
  let ok = false;
  try { ok = globalShortcut.register(accel, actionFor(name)); } catch (e) { ok = false; }
  if (!ok) return { ok: false, reason: 'Another app already uses that combination' };
  registered[name] = accel;
  return { ok: true };
}
function setupHotkeys() {
  const hk = Object.assign({}, DEFAULT_HK, store.get('hotkeys', {}));
  for (const n of Object.keys(DEFAULT_HK)) {
    const r = applyHotkey(n, hk[n]);
    if (!r.ok) log('hotkey ' + n + ' not registered: ' + r.reason);
  }
}

// ---------------------------------------------------------------- clipboard watcher
const clipDir = () => path.join(app.getPath('userData'), 'clipimg');
let lastText = null, lastImgHash = null, clipPrimed = false, ignoreClip = 0;
function clipTick() {
  if (!ready) return;
  try {
    if (Date.now() < ignoreClip) { lastText = clipboard.readText(); return; }
    const fmts = clipboard.availableFormats();
    const text = clipboard.readText();
    const hasImg = fmts.some(f => f.startsWith('image/'));
    if (text && text !== lastText) {
      lastText = text;
      if (clipPrimed) send('clip-add', { type: 'text', text: text.slice(0, 20000) });
      else send('clip-add', { type: 'text', text: text.slice(0, 20000), initial: true });
      clipPrimed = true;
      return;
    }
    if (!text && hasImg) {
      const img = clipboard.readImage();
      if (!img.isEmpty()) {
        const bmp = img.toBitmap();
        const h = crypto.createHash('md5').update(bmp).digest('hex');
        if (h !== lastImgHash) {
          lastImgHash = h;
          if (clipPrimed) {
            fs.mkdirSync(clipDir(), { recursive: true });
            const f = path.join(clipDir(), Date.now() + '.png');
            fs.writeFileSync(f, img.toPNG());
            send('clip-add', { type: 'image', file: f });
          }
        }
      }
    }
    if (!text) lastText = '';
    clipPrimed = true;
  } catch (e) { /* clipboard busy: try again next tick */ }
}

// ---------------------------------------------------------------- system stats
let lastCpu = null, lastNet = null;
function cpuPercent() {
  const cpus = os.cpus();
  let idle = 0, total = 0;
  for (const c of cpus) { for (const k in c.times) total += c.times[k]; idle += c.times.idle; }
  const cur = { idle, total };
  let pct = 0;
  if (lastCpu && cur.total > lastCpu.total) pct = Math.round(100 * (1 - (cur.idle - lastCpu.idle) / (cur.total - lastCpu.total)));
  lastCpu = cur;
  return Math.max(0, Math.min(100, pct));
}
function run(cmd, args, timeout) {
  return new Promise(res => {
    try { execFile(cmd, args, { windowsHide: true, timeout: timeout || 4000, maxBuffer: 1 << 20 }, (err, out) => res(err ? '' : String(out))); }
    catch (e) { res(''); }
  });
}
async function netBytes() {
  if (!IS_WIN) return null;
  const out = await run('netstat', ['-e'], 3000);
  for (const line of out.split(/\r?\n/)) {
    const m = /^\s*\D+?\s+(\d+)\s+(\d+)\s*$/.exec(line);
    if (m) return { rx: Number(m[1]), tx: Number(m[2]) };
  }
  return null;
}
let wifiCache = { at: 0, v: null };
async function wifiSignal() {
  if (!IS_WIN) return null;
  if (Date.now() - wifiCache.at < 6000) return wifiCache.v;
  const out = await run('netsh', ['wlan', 'show', 'interfaces'], 3000);
  let v = null;
  const m = /(\d{1,3})\s?%/.exec(out);
  if (m) v = Math.min(100, Number(m[1]));
  wifiCache = { at: Date.now(), v };
  return v;
}
async function sysStats() {
  const total = os.totalmem(), free = os.freemem();
  let down = null, up = null;
  const nb = await netBytes();
  const now = Date.now();
  if (nb && lastNet && now > lastNet.t) {
    const dt = (now - lastNet.t) / 1000;
    down = Math.max(0, (nb.rx - lastNet.rx) / dt); up = Math.max(0, (nb.tx - lastNet.tx) / dt);
  }
  if (nb) lastNet = { rx: nb.rx, tx: nb.tx, t: now };
  return { cpu: cpuPercent(), memUsed: total - free, memTotal: total, down, up, wifi: await wifiSignal() };
}

// ---------------------------------------------------------------- installed apps (Start menu shortcuts)
function listApps() {
  const roots = [];
  if (process.env.ProgramData) roots.push(path.join(process.env.ProgramData, 'Microsoft', 'Windows', 'Start Menu', 'Programs'));
  if (process.env.APPDATA) roots.push(path.join(process.env.APPDATA, 'Microsoft', 'Windows', 'Start Menu', 'Programs'));
  const out = new Map();
  const skip = /(uninstall|readme|release notes|help|documentation|license|website|manual|changelog)/i;
  const walk = (dir, depth) => {
    let es; try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    for (const e of es) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { if (depth < 3) walk(p, depth + 1); }
      else if (/\.lnk$/i.test(e.name)) {
        const name = e.name.replace(/\.lnk$/i, '');
        if (!skip.test(name) && !out.has(name.toLowerCase())) out.set(name.toLowerCase(), { name, path: p });
      }
    }
  };
  roots.forEach(r => walk(r, 0));
  return Array.from(out.values()).sort((a, b) => a.name.localeCompare(b.name)).slice(0, 600);
}

// ---------------------------------------------------------------- IPC
const SAFE_SCHEMES = /^(https?:|mailto:|ms-settings:|ms-screenclip:)/i;
const TEXT_EXT = /\.(txt|md|json|js|ts|jsx|tsx|py|c|cpp|h|hpp|cs|java|go|rs|rb|php|html|css|scss|xml|yml|yaml|toml|ini|cfg|csv|log|sh|bat|ps1|sql|swift|kt|lua)$/i;
const iconCache = new Map();

function inside(base, file) {
  const r = path.relative(base, file);
  return !!r && !r.startsWith('..') && !path.isAbsolute(r);
}

function setupIpc() {
  ipcMain.on('cfg-all', e => { e.returnValue = Object.assign({}, store.data, { __version: app.getVersion(), __platform: process.platform, __login: loginEnabled() }); });
  ipcMain.on('cfg-set', (e, k, v) => { if (typeof k === 'string' && k.length < 80) store.set(k, v); });

  ipcMain.on('ready', () => {
    ready = true;
    log('renderer ready');
    send('cfg-changed', { key: 'hotkeys', value: Object.assign({}, DEFAULT_HK, store.get('hotkeys', {})) });
  });
  ipcMain.on('open-request', () => openNotch(false));
  ipcMain.on('close-request', () => closeNotch());
  ipcMain.on('collapsed', () => { if (st.closing) finishClose(); });
  ipcMain.on('panel-size', (e, w, h) => {
    if (!(w > 100 && h > 40)) return;
    const prev = st.panel;
    st.panel = { w: Math.min(Math.round(w), MAX_W), h: Math.min(Math.round(h), MAX_H) };
    if (!st.open || st.closing) return;
    clearTimeout(shrinkTimer);
    if (st.panel.w >= prev.w && st.panel.h >= prev.h) applyBounds();        // growing: the window must be big first
    else shrinkTimer = setTimeout(() => { if (st.open && !st.closing) applyBounds(); }, 300);   // shrinking: let the page animate first
  });
  ipcMain.on('collapsed-size', (e, w, h) => {
    if (w > 10 && h > 1) { st.collapsed = { w: Math.min(w, 700), h: Math.min(h, 80) }; if (!st.open) applyBounds(); }
  });
  ipcMain.on('hold-open', (e, ms) => { st.holdUntil = Date.now() + Math.min(Number(ms) || 0, 30000); });
  ipcMain.on('click-mode', (e, v) => setClickMode(v));

  ipcMain.handle('login-set', (e, on) => { setLogin(on); return loginEnabled(); });
  ipcMain.handle('hotkey-set', (e, name, accel) => {
    if (!DEFAULT_HK[name]) return { ok: false, reason: 'Unknown hotkey' };
    const r = applyHotkey(name, accel || null);
    if (r.ok) { const hk = Object.assign({}, DEFAULT_HK, store.get('hotkeys', {})); hk[name] = accel || null; store.set('hotkeys', hk); buildTray(); }
    return r;
  });

  ipcMain.handle('bridge', (e, cmd, args) => (typeof cmd === 'string' && bridge) ? bridge.call(cmd, args, cmd === 'media' ? 5000 : 8000) : { ok: false, error: 'unavailable' });
  ipcMain.handle('bridge-caps', () => (bridge && bridge.caps) || {});

  ipcMain.handle('open-external', (e, url) => {
    if (typeof url === 'string' && SAFE_SCHEMES.test(url)) { shell.openExternal(url).catch(() => {}); return true; }
    return false;
  });
  ipcMain.handle('open-path', async (e, p) => { if (typeof p !== 'string' || !p) return 'bad path'; return shell.openPath(p); });
  ipcMain.on('reveal', (e, p) => { if (typeof p === 'string') { try { shell.showItemInFolder(p); } catch (e2) { /* ignore */ } } });

  ipcMain.handle('clip-write-text', (e, t) => { ignoreClip = Date.now() + 900; clipboard.writeText(String(t)); lastText = String(t); return true; });
  ipcMain.handle('clip-write-image', (e, f) => {
    if (typeof f !== 'string' || !inside(clipDir(), path.resolve(f))) return false;
    const img = nativeImage.createFromPath(f);
    if (img.isEmpty()) return false;
    ignoreClip = Date.now() + 900; clipboard.writeImage(img); return true;
  });
  ipcMain.handle('clip-delete-image', (e, f) => { try { if (typeof f === 'string' && inside(clipDir(), path.resolve(f))) fs.unlinkSync(f); } catch (e2) { /* ignore */ } return true; });
  ipcMain.handle('clip-wipe-images', () => { try { fs.rmSync(clipDir(), { recursive: true, force: true }); } catch (e2) { /* ignore */ } return true; });

  ipcMain.handle('file-icon', async (e, p) => {
    if (typeof p !== 'string') return null;
    if (iconCache.has(p)) return iconCache.get(p);
    let url = null;
    try {
      if (/\.(png|jpe?g|gif|webp|bmp)$/i.test(p) && fs.existsSync(p)) {
        const t = nativeImage.createFromPath(p);
        if (!t.isEmpty()) url = t.resize({ width: 64, quality: 'good' }).toDataURL();
      }
      if (!url) { const i = await app.getFileIcon(p, { size: 'large' }); if (!i.isEmpty()) url = i.toDataURL(); }
    } catch (e2) { /* no icon */ }
    if (iconCache.size > 400) iconCache.clear();
    iconCache.set(p, url);
    return url;
  });
  ipcMain.handle('file-exists', (e, p) => { try { return typeof p === 'string' && fs.existsSync(p); } catch (e2) { return false; } });
  ipcMain.on('start-drag', async (e, p) => {
    try {
      if (typeof p !== 'string' || !fs.existsSync(p)) return;
      st.holdUntil = Date.now() + 5000;
      let icon = null;
      try { icon = await app.getFileIcon(p, { size: 'normal' }); } catch (e2) { /* fallback below */ }
      if (!icon || icon.isEmpty()) icon = nativeImage.createFromPath(path.join(__dirname, 'assets', 'tray.png'));
      e.sender.startDrag({ file: p, icon });
    } catch (e2) { log('startDrag failed: ' + e2.message); }
  });
  ipcMain.handle('read-text-file', (e, p) => {
    try {
      if (typeof p !== 'string' || !TEXT_EXT.test(p)) return { ok: false, reason: 'type' };
      const s = fs.statSync(p);
      if (!s.isFile() || s.size > 300 * 1024) return { ok: false, reason: 'size' };
      return { ok: true, text: fs.readFileSync(p, 'utf8') };
    } catch (e2) { return { ok: false, reason: 'read' }; }
  });
  ipcMain.handle('pick-files', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'] });
    return r.canceled ? [] : r.filePaths;
  });
  ipcMain.handle('pick-app', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Apps', extensions: ['exe', 'lnk', 'bat', 'cmd'] }] });
    return r.canceled ? null : r.filePaths[0];
  });
  ipcMain.handle('list-apps', () => listApps());

  ipcMain.handle('photo-save', (e, buf) => {
    try {
      const dir = path.join(app.getPath('pictures'), 'NOTCH');
      fs.mkdirSync(dir, { recursive: true });
      const d = new Date(), z = n => String(n).padStart(2, '0');
      const f = path.join(dir, 'NOTCH-' + d.getFullYear() + z(d.getMonth() + 1) + z(d.getDate()) + '-' + z(d.getHours()) + z(d.getMinutes()) + z(d.getSeconds()) + '.png');
      fs.writeFileSync(f, Buffer.from(buf));
      return f;
    } catch (e2) { log('photo save failed: ' + e2.message); return null; }
  });

  ipcMain.handle('sys-stats', () => sysStats());
  ipcMain.handle('fetch-json', async (e, url) => {
    try {
      const u = new URL(url);
      if (u.protocol !== 'https:' || !/(^|\.)open-meteo\.com$/.test(u.hostname)) return { ok: false, error: 'blocked' };
      const r = await net.fetch(url, { headers: { 'User-Agent': 'NOTCH-Windows' } });
      if (!r.ok) return { ok: false, error: 'HTTP ' + r.status };
      return { ok: true, data: await r.json() };
    } catch (e2) { return { ok: false, error: String(e2 && e2.message || e2).slice(0, 100) }; }
  });
  ipcMain.handle('downloads-active', () => {
    try {
      const dir = app.getPath('downloads');
      const now = Date.now();
      for (const n of fs.readdirSync(dir)) {
        if (/\.(crdownload|part|download|partial|opdownload)$/i.test(n)) {
          const s = fs.statSync(path.join(dir, n));
          if (now - s.mtimeMs < 6000) return n.replace(/\.(crdownload|part|download|partial|opdownload)$/i, '');
        }
      }
    } catch (e) { /* ignore */ }
    return null;
  });

  ipcMain.handle('updater-state', () => updater ? updater.state() : null);
  ipcMain.handle('updater-check', () => updater ? updater.check(true) : null);
  ipcMain.handle('updater-install', () => { if (updater) updater.install(); return true; });
  ipcMain.handle('updater-set-repo', (e, r) => updater ? updater.setRepo(r) : { ok: false, reason: 'unavailable' });
  ipcMain.handle('app-info', () => ({ version: app.getVersion(), electron: process.versions.electron, userData: app.getPath('userData'), execPath: process.execPath }));
  ipcMain.on('quit', () => { quitting = true; app.quit(); });
}

// ---------------------------------------------------------------- lifecycle
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => { openNotch(true); });
  app.on('window-all-closed', () => { /* tray app: keep running */ });
  app.on('before-quit', () => { quitting = true; try { store && store.flush(); } catch (e) { /* ignore */ } });
  app.on('will-quit', () => { try { globalShortcut.unregisterAll(); } catch (e) { /* ignore */ } try { bridge && bridge.stop(); } catch (e) { /* ignore */ } });

  app.whenReady().then(() => {
    store = new Store(path.join(app.getPath('userData'), 'config.json'));
    clickMode = !!store.get('clickMode', false);
    try { fs.rmSync(clipDir(), { recursive: true, force: true }); } catch (e) { /* ignore */ }   // clipboard images never outlive a launch
    setupSessions();
    setupIpc();
    bridge = new Bridge(log);
    bridge.start();
    updater = new Updater({
      app, net, cfg: store, support: app.getPath('userData'), version: app.getVersion(), log,
      emit: s => send('updater-state', s)
    });
    createWindow();
    applyBounds();
    win.once('ready-to-show', () => { try { win.showInactive(); } catch (e) { /* ignore */ } });
    buildTray();
    setupHotkeys();
    setInterval(tick, 50);
    setInterval(clipTick, 700);
    updater.start();
    screen.on('display-metrics-changed', () => applyBounds());
    screen.on('display-added', () => applyBounds());
    screen.on('display-removed', () => applyBounds());
    log('NOTCH ' + app.getVersion() + ' started (electron ' + process.versions.electron + ', ' + process.platform + ')');
  }).catch(e => log('startup failed: ' + (e && e.stack || e)));
}
