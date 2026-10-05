'use strict';
// Test harness (NOT shipped to users). Runs the real main.js, opens the notch, selects a tab, saves a screenshot.
//   xvfb-run -a -s "-screen 0 1600x900x24" electron --no-sandbox tests/harness.js <tabId> <out.png> [js-to-run-before-shot]
// Always set NOTCH_USER_DATA to a fresh folder and NOTCH_FAKE_BRIDGE=1.
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');
const tab = process.argv.find((a, i) => i >= 2 && !a.startsWith('-') && !a.endsWith('harness.js')) || 'music';
const idx = process.argv.indexOf(tab);
const out = process.argv[idx + 1] || path.join(process.env.NOTCH_USER_DATA || '.', tab + '.png');
const extra = process.argv[idx + 2] || '';
const logs = [];
app.on('web-contents-created', (e, wc) => {
  wc.on('console-message', (ev, level, msg, line, src) => { if (level >= 2) logs.push('[' + level + '] ' + msg + ' (' + path.basename(String(src)) + ':' + line + ')'); });
});
require('../main.js');
const sleep = ms => new Promise(r => setTimeout(r, ms));
app.whenReady().then(async () => {
  let w;
  for (let i = 0; i < 60 && !w; i++) { await sleep(250); w = BrowserWindow.getAllWindows()[0]; }
  const ex = js => w.webContents.executeJavaScript(js, true);
  try {
    await sleep(2000);
    await ex('window.notch.holdOpen(30000); window.notch.openRequest(); 1');
    await sleep(900);
    const r = await ex('(function(){ if(!window.N.byId[' + JSON.stringify(tab) + ']) return "NO SUCH TAB: " + Object.keys(window.N.byId).join(","); window.N.select(' + JSON.stringify(tab) + '); return "ok"; })()');
    if (r !== 'ok') console.log('select:', r);
    await sleep(1200);
    if (extra) { const v = await ex(extra); if (v !== undefined) console.log('extra ->', JSON.stringify(v)); await sleep(800); }
    const img = await w.webContents.capturePage();
    fs.writeFileSync(out, img.toPNG());
    console.log('saved', out, w.getBounds());
  } catch (e) { console.log('HARNESS ERROR', e && e.message); }
  console.log('CONSOLE ERRORS:', logs.length ? '\n' + logs.join('\n') : 'none');
  process.exit(0);
});
