'use strict';
// node tests/run-all.js   - fast checks that need no Windows and no Electron.
const fs = require('fs');
const path = require('path');
const os = require('os');
const assert = require('assert');
const { execFileSync } = require('child_process');
const root = path.resolve(__dirname, '..');
const core = require(path.join(root, 'updater-core.js'));
const { validateUnpacked } = require(path.join(root, 'updater.js'));
let pass = 0, fail = 0;
function t(name, fn) { try { fn(); pass++; console.log('  ok   ' + name); } catch (e) { fail++; console.log('  FAIL ' + name + '\n       ' + (e && e.message)); } }

console.log('Update isolation (Mac vs Windows)');
const rel = (tag, assets, extra) => Object.assign({ tag_name: tag, name: tag, body: 'notes', draft: false, prerelease: false, html_url: 'https://x', published_at: '2026-01-01T00:00:00Z', assets }, extra || {});
const A = (name, extra) => Object.assign({ name, browser_download_url: 'https://github.com/o/r/releases/download/t/' + name, size: 10, digest: 'sha256:' + 'a'.repeat(64) }, extra || {});
t('accepts the shared repo in any spelling (URL, .git, trailing slash)', () => {
  for (const x of ['coooooooooooops/Notch-For-MAC', 'https://github.com/coooooooooooops/Notch-For-MAC', 'github.com/coooooooooooops/Notch-For-MAC.git', 'https://github.com/coooooooooooops/Notch-For-MAC/'])
    assert.deepStrictEqual(core.checkRepo(x), { ok: true, repo: 'coooooooooooops/Notch-For-MAC' }, x);
});
t('default repo is the shared repo; the old separate Windows repo migrates to it', () => {
  assert.strictEqual(core.DEFAULT_REPO, 'coooooooooooops/Notch-For-MAC');
  assert.strictEqual(core.migrateRepo('https://github.com/coooooooooooops/Notch-For-Windows.git'), core.DEFAULT_REPO);
  assert.strictEqual(core.migrateRepo('someone/else'), 'someone/else');
});
t('Mac release stream can never be installed by the Windows app', () => {
  const list = [rel('v3.4.2', [A('NOTCH.zip'), A('NOTCH-Windows-3.4.2.zip')]), rel('v3.4.1', [A('NOTCH-Windows-3.4.1.zip')])];
  assert.strictEqual(core.pickRelease(list), null);
});
t('rejects garbage repo strings', () => { for (const s of ['', 'abc', '../x/y/..', 'a b/c', null, undefined]) assert.strictEqual(core.checkRepo(s).ok, false, String(s)); });
t('ignores Mac-style tags (v3.4.2) even with a zip', () => { assert.strictEqual(core.pickRelease([rel('v3.4.2', [A('NOTCH.zip'), A('NOTCH-Windows-3.4.2.zip')])]), null); });
t('ignores win- tag without the exact asset name', () => { assert.strictEqual(core.pickRelease([rel('win-v1.0.1', [A('NOTCH.zip')])]), null); assert.strictEqual(core.pickRelease([rel('win-v1.0.1', [A('NOTCH-Windows-1.0.2.zip')])]), null); });
t('ignores drafts and pre-releases', () => { assert.strictEqual(core.pickRelease([rel('win-v1.0.1', [A('NOTCH-Windows-1.0.1.zip')], { draft: true }), rel('win-v1.0.2', [A('NOTCH-Windows-1.0.2.zip')], { prerelease: true })]), null); });
t('ignores non-https download URLs', () => { assert.strictEqual(core.pickRelease([rel('win-v1.0.1', [A('NOTCH-Windows-1.0.1.zip', { browser_download_url: 'http://evil/x.zip' })])]), null); });
t('picks the newest valid Windows release among Mac releases', () => {
  const r = core.pickRelease([rel('v9.9.9', [A('NOTCH.zip')]), rel('win-v1.0.1', [A('NOTCH-Windows-1.0.1.zip')]), rel('win-v1.2.0', [A('NOTCH-Windows-1.2.0.zip')]), rel('win-v1.10.0', [A('NOTCH-Windows-1.10.0.zip')])]);
  assert.strictEqual(r.version, '1.10.0'); assert.strictEqual(r.asset.name, 'NOTCH-Windows-1.10.0.zip');
});
t('version compare is numeric (1.10 > 1.9) and never newer for equal/older/garbage', () => {
  assert.ok(core.isNewer('1.10.0', '1.9.0')); assert.ok(!core.isNewer('1.0.0', '1.0.0')); assert.ok(!core.isNewer('0.9.9', '1.0.0')); assert.ok(!core.isNewer('x', '1.0.0')); assert.ok(!core.isNewer('1.0.1', 'junk'));
});
t('checksum: digest field or .sha256 asset, nothing else', () => {
  const a = core.pickRelease([rel('win-v1.0.1', [A('NOTCH-Windows-1.0.1.zip', { digest: null }), A('NOTCH-Windows-1.0.1.zip.sha256')])]);
  assert.strictEqual(a.asset.sha256, null); assert.ok(a.asset.shaUrl);
  assert.strictEqual(core.parseShaFile('ABCDEF' + '0'.repeat(58) + '  NOTCH-Windows-1.0.1.zip\n'), ('abcdef' + '0'.repeat(58)));
  assert.strictEqual(core.parseShaFile('not a hash'), null);
});
t('foreignFileReason blocks Mac files', () => {
  for (const f of ['build.sh', 'NOTCH/main.swift', 'x/Info.plist', 'NOTCH.app', 'NOTCH.dmg']) assert.ok(core.foreignFileReason(['a.txt', f]), f);
  assert.strictEqual(core.foreignFileReason(['NOTCH.exe', 'resources/app/main.js']), null);
});
t('marker must be NOTCH-Windows / win32 / same version', () => {
  const ok = { product: 'NOTCH-Windows', platform: 'win32', version: '1.0.1' };
  assert.strictEqual(core.markerReason(ok, '1.0.1'), null);
  assert.ok(core.markerReason(null, '1.0.1')); assert.ok(core.markerReason({ product: 'NOTCH', platform: 'darwin', version: '1.0.1' }, '1.0.1'));
  assert.ok(core.markerReason(Object.assign({}, ok, { platform: 'darwin' }), '1.0.1')); assert.ok(core.markerReason(ok, '1.0.2'));
});
function tmp() { return fs.mkdtempSync(path.join(os.tmpdir(), 'notch-t-')); }
t('validateUnpacked accepts a good package (flat and one folder down)', () => {
  for (const nested of [false, true]) {
    const d = tmp(), r = nested ? path.join(d, 'NOTCH-Windows-1.0.1') : d;
    fs.mkdirSync(r, { recursive: true }); fs.writeFileSync(path.join(r, 'NOTCH.exe'), 'x'); fs.writeFileSync(path.join(r, 'windows-build.json'), JSON.stringify({ product: 'NOTCH-Windows', platform: 'win32', version: '1.0.1' }));
    assert.strictEqual(validateUnpacked(d, '1.0.1').ok, true);
  }
});
t('validateUnpacked rejects the Mac zip, a Mac file inside a Windows zip, and a wrong marker', () => {
  let d = tmp(); fs.mkdirSync(path.join(d, 'NOTCH')); fs.writeFileSync(path.join(d, 'NOTCH', 'build.sh'), '#!/bin/sh'); fs.writeFileSync(path.join(d, 'NOTCH', 'main.swift'), '');
  assert.strictEqual(validateUnpacked(d, '1.0.1').ok, false);
  d = tmp(); fs.writeFileSync(path.join(d, 'NOTCH.exe'), 'x'); fs.writeFileSync(path.join(d, 'build.sh'), ''); fs.writeFileSync(path.join(d, 'windows-build.json'), JSON.stringify({ product: 'NOTCH-Windows', platform: 'win32', version: '1.0.1' }));
  assert.strictEqual(validateUnpacked(d, '1.0.1').ok, false);
  d = tmp(); fs.writeFileSync(path.join(d, 'NOTCH.exe'), 'x'); fs.writeFileSync(path.join(d, 'windows-build.json'), JSON.stringify({ product: 'NOTCH', platform: 'darwin', version: '1.0.1' }));
  assert.strictEqual(validateUnpacked(d, '1.0.1').ok, false);
  d = tmp(); fs.writeFileSync(path.join(d, 'windows-build.json'), '{}');
  assert.strictEqual(validateUnpacked(d, '1.0.1').ok, false);
});
t('the Windows app source never mentions the Mac release URL except as the blocked repo', () => {
  for (const f of ['main.js', 'updater.js', 'bridge.js', 'preload.js']) assert.ok(!/releases\/latest/.test(fs.readFileSync(path.join(root, f), 'utf8')), f + ' uses releases/latest');
});

console.log('App consistency');
t('every JS file parses', () => {
  const files = ['main.js', 'preload.js', 'bridge.js', 'updater.js', 'updater-core.js', 'build/build-windows.js'];
  (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (/\.js$/.test(e.name)) files.push(path.relative(root, p)); } })(path.join(root, 'src'));
  for (const f of files) execFileSync(process.execPath, ['--check', path.join(root, f)]);
});
t('index.html loads only scripts that exist, each once, boot.js last', () => {
  const html = fs.readFileSync(path.join(root, 'src', 'index.html'), 'utf8');
  const srcs = [...html.matchAll(/<script src="([^"]+)"/g)].map(m => m[1]);
  assert.ok(srcs.length > 10); assert.strictEqual(new Set(srcs).size, srcs.length); assert.strictEqual(srcs[srcs.length - 1], 'boot.js'); assert.strictEqual(srcs[0], 'core.js');
  for (const s of srcs) assert.ok(fs.existsSync(path.join(root, 'src', s)), 'missing ' + s);
  const tabsOnDisk = fs.readdirSync(path.join(root, 'src', 'tabs')).map(f => 'tabs/' + f);
  for (const f of tabsOnDisk) assert.ok(srcs.includes(f), f + ' exists but is not loaded');
});
t('every preload invoke/send channel has a handler in main.js', () => {
  const pre = fs.readFileSync(path.join(root, 'preload.js'), 'utf8'), main = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
  const chans = [...pre.matchAll(/ipcRenderer\.(?:invoke|send|sendSync)\('([^']+)'/g)].map(m => m[1]);
  assert.ok(chans.length > 30);
  for (const c of chans) assert.ok(new RegExp("ipcMain\\.(?:on|handle)\\('" + c + "'").test(main), 'no handler for ' + c);
});
t('every renderer event name is whitelisted in preload', () => {
  const pre = fs.readFileSync(path.join(root, 'preload.js'), 'utf8');
  const ok = pre.match(/const ok = \[([^\]]+)\]/)[1];
  (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (/\.js$/.test(e.name)) { for (const m of fs.readFileSync(p, 'utf8').matchAll(/api\.on\('([^']+)'/g)) assert.ok(ok.includes("'" + m[1] + "'"), p + ' listens to non-whitelisted ' + m[1]); } } })(path.join(root, 'src'));
});
t('every window.notch method used by tabs exists in preload', () => {
  const pre = fs.readFileSync(path.join(root, 'preload.js'), 'utf8');
  const have = new Set([...pre.matchAll(/^\s{2}(\w+):/gm)].map(m => m[1]));
  (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (/\.js$/.test(e.name)) { for (const m of fs.readFileSync(p, 'utf8').matchAll(/\bapi\.(\w+)\(/g)) assert.ok(have.has(m[1]) || m[1] === 'on', p + ' calls missing api.' + m[1]); } } })(path.join(root, 'src'));
});
t('no forbidden dialogs or storage in the UI code', () => {
  (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (/\.js$/.test(e.name)) { const s = fs.readFileSync(p, 'utf8'); assert.ok(!/\b(window\.)?(prompt|alert|confirm)\(/.test(s.replace(/N\.toast/g, '')), p + ' uses a blocking dialog'); assert.ok(!/localStorage|sessionStorage/.test(s), p + ' uses web storage'); assert.ok(!/\sonclick=|\sonerror=|\sonload=/.test(s.replace(/onclick:|onerror:|onload:/g, '')), p + ' inline handler'); } } })(path.join(root, 'src'));
});
t('package.json / VERSION agree and use X.Y.Z', () => {
  const v = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
  assert.ok(/^\d+\.\d+\.\d+$/.test(v)); assert.strictEqual(fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim(), v);
});
console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
