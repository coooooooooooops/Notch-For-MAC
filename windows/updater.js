'use strict';
// Windows updater (main process). All decisions about WHAT may be installed live in updater-core.js.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFile } = require('child_process');
const core = require('./updater-core');

const MAX_ZIP = 600 * 1024 * 1024;

function walk(dir, out, limit) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const e of entries) {
    if (out.length > limit) return;
    const p = path.join(dir, e.name);
    out.push(p);
    if (e.isDirectory()) walk(p, out, limit);
  }
}

/** Finds the folder inside an unpacked update that holds NOTCH.exe (the zip root or one folder down). */
function findRoot(dir) {
  const has = d => fs.existsSync(path.join(d, 'NOTCH.exe'));
  if (has(dir)) return dir;
  let kids = [];
  try { kids = fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isDirectory()); } catch (e) { /* none */ }
  for (const k of kids) { const p = path.join(dir, k.name); if (has(p)) return p; }
  return null;
}

/** Returns {ok:true, root} or {ok:false, reason}. Refuses anything that is not a NOTCH for Windows package. */
function validateUnpacked(dir, expectedVersion) {
  const root = findRoot(dir);
  if (!root) return { ok: false, reason: 'NOTCH.exe is not inside the update' };
  const all = [];
  walk(root, all, 200000);
  const foreign = core.foreignFileReason(all.map(p => path.relative(root, p)));
  if (foreign) return { ok: false, reason: foreign };
  let marker = null;
  for (const rel of ['windows-build.json', path.join('resources', 'app', 'windows-build.json')]) {
    try { marker = JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8')); break; } catch (e) { /* try next */ }
  }
  const bad = core.markerReason(marker, expectedVersion);
  if (bad) return { ok: false, reason: bad };
  return { ok: true, root };
}

function sha256File(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(file);
    s.on('data', d => h.update(d));
    s.on('error', reject);
    s.on('end', () => resolve(h.digest('hex')));
  });
}

function extractZip(zip, dest) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(dest, { recursive: true });
    if (process.platform === 'win32') {
      const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const cmd = "$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath $env:NOTCH_ZIP -DestinationPath $env:NOTCH_DEST -Force";
      execFile(ps, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
        { windowsHide: true, timeout: 300000, env: Object.assign({}, process.env, { NOTCH_ZIP: zip, NOTCH_DEST: dest }) },
        err => err ? reject(new Error('Could not unzip the update')) : resolve());
    } else {
      execFile('unzip', ['-q', '-o', zip, '-d', dest], { timeout: 300000 }, err => err ? reject(new Error('Could not unzip the update')) : resolve());
    }
  });
}

function isWritableDir(dir) {
  try {
    const f = path.join(dir, '.notch-write-test-' + process.pid);
    fs.writeFileSync(f, 'x');
    fs.unlinkSync(f);
    return true;
  } catch (e) { return false; }
}

class Updater {
  constructor(d) {
    this.app = d.app;
    this.net = d.net;
    this.cfg = d.cfg;                 // {get,set}
    this.emit = d.emit || (() => {});
    this.log = d.log || (() => {});
    this.support = d.support;
    this.appDir = d.appDir || path.dirname(process.execPath);
    this.current = d.version;
    this.s = { status: 'Not checked yet', release: null, hasUpdate: false, checking: false, busy: false, progress: null, current: d.version, repo: this.repo() };
    this.attempted = '';
    this.timer = null;
  }

  repo() {
    const c = core.checkRepo(core.migrateRepo(this.cfg.get('updRepo', core.DEFAULT_REPO)));
    return c.ok ? c.repo : core.DEFAULT_REPO;
  }

  state() { this.s.repo = this.repo(); return Object.assign({}, this.s); }
  _set(patch) { Object.assign(this.s, patch); this.emit(this.state()); }

  start() {
    setTimeout(() => this.check(false), 8000);
    this.timer = setInterval(() => this.check(false), 3 * 3600 * 1000);
  }

  setRepo(input) {
    const c = core.checkRepo(input);
    if (!c.ok) return { ok: false, reason: c.reason };
    this.cfg.set('updRepo', c.repo);
    this._set({ release: null, hasUpdate: false, status: 'Repo changed, checking...' });
    this.check(true);
    return { ok: true, repo: c.repo };
  }

  async check(manual) {
    if (this.s.checking || this.s.busy) return this.state();
    const rc = core.checkRepo(core.migrateRepo(this.cfg.get('updRepo', core.DEFAULT_REPO)));
    if (!rc.ok) { this._set({ status: rc.reason }); return this.state(); }
    this._set({ checking: true });
    try {
      // Mac and Windows releases share this repo, so look through several pages (newest first) until a Windows release shows up.
      let rel = null;
      for (let page = 1; page <= 5 && !rel; page++) {
        const res = await this.net.fetch('https://api.github.com/repos/' + rc.repo + '/releases?per_page=100&page=' + page, {
          headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'NOTCH-Windows-updater' }
        });
        if (this.s.busy) return this.state();
        if (res.status === 404) { this._set({ checking: false, release: null, hasUpdate: false, status: 'No Windows release found yet (the repo must be public)' }); return this.state(); }
        if (res.status === 403 || res.status === 429) { this._set({ checking: false, status: 'GitHub says slow down - try again in a while' }); return this.state(); }
        if (!res.ok) { this._set({ checking: false, status: 'Could not read releases (HTTP ' + res.status + ')' }); return this.state(); }
        const list = await res.json();
        rel = core.pickRelease(list);
        if (!Array.isArray(list) || list.length < 100) break;
      }
      if (!rel) { this._set({ checking: false, release: null, hasUpdate: false, status: 'No Windows release found yet' }); return this.state(); }
      const has = core.isNewer(rel.version, this.current);
      this._set({ checking: false, release: rel, hasUpdate: has, status: has ? rel.tag + ' is available' : "You're up to date" });
      if (has && this.cfg.get('updAuto', false) && this.attempted !== rel.tag) this.install();
    } catch (e) {
      this._set({ checking: false, status: "Can't reach GitHub (" + String(e && e.message || e).slice(0, 80) + ')' });
    }
    return this.state();
  }

  async _download(url, file, expectedSize) {
    const res = await this.net.fetch(url, { headers: { 'User-Agent': 'NOTCH-Windows-updater' } });
    if (!res.ok || !res.body) throw new Error('Download failed (HTTP ' + res.status + ')');
    const total = Number(res.headers.get('content-length')) || expectedSize || 0;
    if (total > MAX_ZIP) throw new Error('The download is unexpectedly large');
    const out = fs.createWriteStream(file);
    const reader = res.body.getReader();
    let got = 0, last = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        got += value.length;
        if (got > MAX_ZIP) throw new Error('The download is unexpectedly large');
        if (!out.write(Buffer.from(value))) await new Promise(r => out.once('drain', r));
        if (total && Date.now() - last > 150) { last = Date.now(); this._set({ progress: Math.min(1, got / total) }); }
      }
    } finally {
      await new Promise(r => out.end(r));
    }
    return got;
  }

  _fail(msg) {
    this.log('update failed: ' + msg);
    try { fs.rmSync(path.join(this.support, 'update'), { recursive: true, force: true }); } catch (e) { /* ignore */ }
    this._set({ busy: false, progress: null, status: msg });
  }

  async install() {
    const rel = this.s.release;
    if (this.s.busy || !rel || !this.s.hasUpdate) return;
    this.attempted = rel.tag;
    const rc = core.checkRepo(core.migrateRepo(this.cfg.get('updRepo', core.DEFAULT_REPO)));
    if (!rc.ok) return this._fail(rc.reason);
    if (process.platform !== 'win32') return this._fail('Updates can only be installed on Windows');
    if (!isWritableDir(this.appDir)) return this._fail('NOTCH is in a protected folder. Run Install.bat once to put it in your user folder, then updates work.');
    this._set({ busy: true, progress: 0, status: 'Downloading ' + rel.tag + '...' });
    const dir = path.join(this.support, 'update');
    try {
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true });
      const zip = path.join(dir, rel.asset.name);
      await this._download(rel.asset.url, zip, rel.asset.size);

      this._set({ progress: null, status: 'Checking the download...' });
      let want = rel.asset.sha256;
      if (!want && rel.asset.shaUrl) {
        const r = await this.net.fetch(rel.asset.shaUrl, { headers: { 'User-Agent': 'NOTCH-Windows-updater' } });
        if (r.ok) want = core.parseShaFile(await r.text());
      }
      if (!want) return this._fail('This release has no checksum, so it was not installed');
      const got = await sha256File(zip);
      if (got !== want) return this._fail("Download doesn't match its checksum - not installed");

      this._set({ status: 'Unpacking...' });
      const src = path.join(dir, 'src');
      await extractZip(zip, src);
      const v = validateUnpacked(src, rel.version);
      if (!v.ok) return this._fail('Update rejected: ' + v.reason);

      const script = path.join(dir, 'apply-update.ps1');
      fs.copyFileSync(path.join(__dirname, 'native', 'apply-update.ps1'), script);
      const logFile = path.join(this.support, 'update.log');
      try { fs.writeFileSync(logFile, ''); } catch (e) { /* ignore */ }
      const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      this._set({ status: 'Installing... NOTCH restarts by itself in a moment' });
      const child = spawn(ps, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script,
        '-ParentPid', String(process.pid), '-AppDir', this.appDir, '-NewDir', v.root, '-Exe', path.basename(process.execPath), '-Log', logFile],
        { detached: true, stdio: 'ignore', windowsHide: true });
      child.on('error', e => this._fail('Could not start the installer: ' + e.message));
      child.unref();
      setTimeout(() => this.app.quit(), 700);
    } catch (e) {
      this._fail(String(e && e.message || e).slice(0, 160));
    }
  }
}

module.exports = { Updater, validateUnpacked, findRoot, extractZip, sha256File, isWritableDir };
