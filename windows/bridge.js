'use strict';
// Talks to native/bridge.ps1, ONE long-lived hidden PowerShell process that handles media info, volume,
// brightness, dark mode, etc. Every call has a timeout and can never throw: on any problem it resolves
// {ok:false, error}. If PowerShell dies it is restarted a few times, then the features simply report "unavailable".

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

class Bridge {
  constructor(log) {
    this.log = log || (() => {});
    this.proc = null;
    this.buf = '';
    this.seq = 0;
    this.pending = new Map();
    this.caps = null;
    this.restarts = 0;
    this.dead = false;
    this.stopping = false;
    this.lastStart = 0;
    this.onEvent = null;
  }

  static script() {
    return path.join(__dirname, 'native', 'bridge.ps1');
  }

  start() {
    if (this.stopping || this.dead || this.proc) return;
    if (process.env.NOTCH_FAKE_BRIDGE) { this._fake(); return; }
    if (process.platform !== 'win32') { this.dead = true; this.caps = {}; return; }
    const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const exe = fs.existsSync(ps) ? ps : 'powershell.exe';
    let p;
    try {
      p = spawn(exe, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', Bridge.script()],
        { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (e) { this.log('bridge spawn failed: ' + e.message); this._died(); return; }
    this.proc = p;
    this.lastStart = Date.now();
    this.buf = '';
    p.stdout.setEncoding('utf8');
    p.stdout.on('data', d => this._data(d));
    p.stderr.on('data', d => this.log('bridge stderr: ' + String(d).slice(0, 400)));
    p.stdin.on('error', () => {});
    p.on('error', e => { this.log('bridge error: ' + e.message); });
    p.on('exit', () => { if (this.proc === p) { this.proc = null; this._died(); } });
  }

  _died() {
    for (const [, v] of this.pending) { clearTimeout(v.t); v.res({ ok: false, error: 'bridge stopped' }); }
    this.pending.clear();
    if (this.stopping) return;
    if (Date.now() - this.lastStart > 60000) this.restarts = 0;   // it ran fine for a while: forgive earlier crashes
    if (++this.restarts > 4) { this.dead = true; this.log('bridge disabled after repeated crashes'); return; }
    setTimeout(() => this.start(), 1500 * this.restarts);
  }

  _data(d) {
    this.buf += d;
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim();
      this.buf = this.buf.slice(i + 1);
      if (!line || line[0] !== '{') continue;
      let m;
      try { m = JSON.parse(line); } catch (e) { continue; }
      if (m.event === 'caps') { this.caps = m.caps || {}; if (this.onEvent) this.onEvent(m); continue; }
      const w = this.pending.get(m.id);
      if (w) { clearTimeout(w.t); this.pending.delete(m.id); w.res(m.ok ? { ok: true, data: m.data } : { ok: false, error: m.error || 'failed' }); }
    }
  }

  call(cmd, args, timeoutMs) {
    return new Promise(res => {
      try {
        if (!this.proc || this.dead) return res({ ok: false, error: 'unavailable' });
        const id = ++this.seq;
        const t = setTimeout(() => { this.pending.delete(id); res({ ok: false, error: 'timeout' }); }, timeoutMs || 6000);
        this.pending.set(id, { res, t });
        this.proc.stdin.write(JSON.stringify(Object.assign({ id, cmd }, args || {})) + '\n', err => {
          if (err) { clearTimeout(t); this.pending.delete(id); res({ ok: false, error: 'write failed' }); }
        });
      } catch (e) { res({ ok: false, error: String(e && e.message || e) }); }
    });
  }

  stop() {
    this.stopping = true;
    try { if (this.proc) { this.proc.stdin.end(); this.proc.kill(); } } catch (e) { /* ignore */ }
    this.proc = null;
  }

  // ---- test double (NOTCH_FAKE_BRIDGE=1): lets the whole UI be exercised on a machine without Windows ----
  _fake() {
    const st = { vol: 40, mute: false, bright: 70, dark: true, playing: true, pos: 30 };
    this.caps = { media: true, volume: true, brightness: true, theme: true, mic: true, keys: true };
    this.proc = { stdin: { write: () => {}, end: () => {} }, kill: () => {} };
    this.call = async (cmd, args) => {
      args = args || {};
      switch (cmd) {
        case 'media': return { ok: true, data: { has: true, title: 'Test Song', artist: 'Test Artist', app: 'Spotify.exe', playing: st.playing, pos: st.pos, dur: 180, thumb: null, key: 'k1' } };
        case 'mediaCtl': if (args.action === 'toggle') st.playing = !st.playing; return { ok: true, data: true };
        case 'seek': st.pos = args.seconds; return { ok: true, data: true };
        case 'getVolume': return { ok: true, data: { volume: st.vol, mute: st.mute } };
        case 'setVolume': st.vol = args.value; return { ok: true, data: true };
        case 'setMute': st.mute = !!args.value; return { ok: true, data: true };
        case 'getBrightness': return { ok: true, data: st.bright };
        case 'setBrightness': st.bright = args.value; return { ok: true, data: true };
        case 'getDark': return { ok: true, data: st.dark };
        case 'setDark': st.dark = !!args.value; return { ok: true, data: true };
        case 'mic': return { ok: true, data: false };
        case 'screenOff': return { ok: true, data: true };
        default: return { ok: false, error: 'unknown' };
      }
    };
  }
}

module.exports = { Bridge };
