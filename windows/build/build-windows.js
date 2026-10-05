'use strict';
// Builds the shippable NOTCH for Windows package:  dist/NOTCH-Windows-<version>.zip  (+ .sha256)
// Works on Linux, macOS or Windows with Node 18+. It needs internet once, to fetch the Windows build of Electron.
//   node build/build-windows.js
// Optional: ELECTRON_WIN_DIST=<folder that already contains electron.exe> skips the download.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync, spawnSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const version = pkg.version;
const electronVersion = pkg.devDependencies.electron;
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('package.json version must be X.Y.Z');
if (fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim() !== version) throw new Error('VERSION file and package.json version differ');

const dist = path.join(root, 'dist');
const stage = path.join(dist, 'NOTCH-Windows-' + version);
const zipPath = path.join(dist, 'NOTCH-Windows-' + version + '.zip');

function rmrf(p) { fs.rmSync(p, { recursive: true, force: true }); }
function copyDir(src, dst, filter) {
  fs.mkdirSync(dst, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, e.name), d = path.join(dst, e.name);
    if (filter && !filter(s, e)) continue;
    if (e.isDirectory()) copyDir(s, d, filter); else fs.copyFileSync(s, d);
  }
}

function getElectronDist() {
  if (process.env.ELECTRON_WIN_DIST) return path.resolve(process.env.ELECTRON_WIN_DIST);
  const cache = path.join(__dirname, '.cache');
  const dir = path.join(cache, 'node_modules', 'electron', 'dist');
  if (fs.existsSync(path.join(dir, 'electron.exe')) && fs.existsSync(path.join(dir, 'version')) &&
      fs.readFileSync(path.join(dir, 'version'), 'utf8').trim().replace(/^v/, '') === electronVersion) return dir;
  console.log('Downloading Electron ' + electronVersion + ' for Windows (about 100 MB)...');
  rmrf(cache); fs.mkdirSync(cache, { recursive: true });
  fs.writeFileSync(path.join(cache, 'package.json'), '{"name":"cache","private":true}');
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const env = Object.assign({}, process.env, { npm_config_platform: 'win32', npm_config_arch: 'x64' });
  const opt = { cwd: cache, env, stdio: 'inherit', shell: process.platform === 'win32' };
  execFileSync(npm, ['install', '--no-audit', '--no-fund', 'electron@' + electronVersion], opt);
  if (!fs.existsSync(path.join(dir, 'electron.exe'))) execFileSync(process.execPath, [path.join(cache, 'node_modules', 'electron', 'install.js')], opt);
  if (!fs.existsSync(path.join(dir, 'electron.exe'))) throw new Error('Could not download the Windows build of Electron');
  return dir;
}

function zipFolder(folder, out) {
  rmrf(out);
  if (process.platform === 'win32') {
    const r = spawnSync('powershell.exe', ['-NoProfile', '-Command', "Compress-Archive -Path '" + folder + "\\*' -DestinationPath '" + out + "' -Force"], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error('Compress-Archive failed');
  } else {
    const r = spawnSync('zip', ['-q', '-r', '-X', out, '.'], { cwd: folder, stdio: 'inherit' });
    if (r.status !== 0) throw new Error('zip failed (install the "zip" tool)');
  }
}

console.log('Building NOTCH for Windows ' + version);
rmrf(stage); fs.mkdirSync(dist, { recursive: true });
const ed = getElectronDist();
copyDir(ed, stage, (s, e) => e.name !== 'default_app.asar');
fs.renameSync(path.join(stage, 'electron.exe'), path.join(stage, 'NOTCH.exe'));

const app = path.join(stage, 'resources', 'app');
for (const f of ['main.js', 'preload.js', 'bridge.js', 'updater.js', 'updater-core.js', 'package.json', 'VERSION']) {
  fs.mkdirSync(app, { recursive: true });
  fs.copyFileSync(path.join(root, f), path.join(app, f));
}
copyDir(path.join(root, 'src'), path.join(app, 'src'));
copyDir(path.join(root, 'native'), path.join(app, 'native'));
copyDir(path.join(root, 'assets'), path.join(app, 'assets'));
// the shipped package.json must not ask anyone to install Electron
const shipped = JSON.parse(fs.readFileSync(path.join(app, 'package.json'), 'utf8'));
delete shipped.devDependencies; delete shipped.scripts;
fs.writeFileSync(path.join(app, 'package.json'), JSON.stringify(shipped, null, 2));

const marker = JSON.stringify({ product: 'NOTCH-Windows', platform: 'win32', arch: 'x64', version, electron: electronVersion }, null, 2);
fs.writeFileSync(path.join(stage, 'windows-build.json'), marker);
fs.writeFileSync(path.join(app, 'windows-build.json'), marker);
for (const f of ['Install.bat', 'Uninstall.bat']) fs.writeFileSync(path.join(stage, f), fs.readFileSync(path.join(root, f), 'utf8').replace(/\r?\n/g, '\r\n'));
fs.writeFileSync(path.join(stage, 'README-Windows.txt'), fs.readFileSync(path.join(root, 'README-Windows.txt'), 'utf8').replace(/\r?\n/g, '\r\n'));
// the PowerShell scripts get a UTF-8 BOM + CRLF so Windows PowerShell 5.1 reads them correctly
for (const f of fs.readdirSync(path.join(app, 'native'))) {
  if (!/\.ps1$/.test(f)) continue;
  const p = path.join(app, 'native', f);
  const txt = fs.readFileSync(p, 'utf8').replace(/^﻿/, '').replace(/\r?\n/g, '\r\n');
  fs.writeFileSync(p, '﻿' + txt, 'utf8');
}

// sanity: nothing from the Mac app may ever be in this package
(function scan(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (/^(build\.sh|Info\.plist|.*\.swift|.*\.dmg|Install\.command)$/i.test(e.name)) throw new Error('Mac file in package: ' + p);
    if (e.isDirectory()) scan(p);
  }
})(stage);

zipFolder(stage, zipPath);
const sha = crypto.createHash('sha256').update(fs.readFileSync(zipPath)).digest('hex');
fs.writeFileSync(zipPath + '.sha256', sha + '  ' + path.basename(zipPath) + '\n');
console.log('\nDone:\n  ' + zipPath + '\n  sha256 ' + sha + '\n  ' + (fs.statSync(zipPath).size / 1048576).toFixed(1) + ' MB');
