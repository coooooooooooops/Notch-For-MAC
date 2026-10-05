'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');

const on = (ch, fn) => { ipcRenderer.on(ch, (e, p) => { try { fn(p); } catch (err) { console.error(ch, err); } }); };

contextBridge.exposeInMainWorld('notch', {
  cfgAll: () => ipcRenderer.sendSync('cfg-all'),
  cfgSet: (k, v) => ipcRenderer.send('cfg-set', k, v),
  ready: () => ipcRenderer.send('ready'),
  openRequest: () => ipcRenderer.send('open-request'),
  closeRequest: () => ipcRenderer.send('close-request'),
  collapsedAck: () => ipcRenderer.send('collapsed'),
  panelSize: (w, h) => ipcRenderer.send('panel-size', w, h),
  collapsedSize: (w, h) => ipcRenderer.send('collapsed-size', w, h),
  holdOpen: ms => ipcRenderer.send('hold-open', ms),
  setClickMode: v => ipcRenderer.send('click-mode', !!v),
  setLogin: v => ipcRenderer.invoke('login-set', !!v),
  setHotkey: (n, a) => ipcRenderer.invoke('hotkey-set', n, a),
  bridge: (cmd, args) => ipcRenderer.invoke('bridge', cmd, args),
  bridgeCaps: () => ipcRenderer.invoke('bridge-caps'),
  openExternal: u => ipcRenderer.invoke('open-external', u),
  openPath: p => ipcRenderer.invoke('open-path', p),
  reveal: p => ipcRenderer.send('reveal', p),
  clipWriteText: t => ipcRenderer.invoke('clip-write-text', t),
  clipWriteImage: f => ipcRenderer.invoke('clip-write-image', f),
  clipDeleteImage: f => ipcRenderer.invoke('clip-delete-image', f),
  clipWipeImages: () => ipcRenderer.invoke('clip-wipe-images'),
  fileIcon: p => ipcRenderer.invoke('file-icon', p),
  fileExists: p => ipcRenderer.invoke('file-exists', p),
  startDrag: p => ipcRenderer.send('start-drag', p),
  readTextFile: p => ipcRenderer.invoke('read-text-file', p),
  pickFiles: () => ipcRenderer.invoke('pick-files'),
  pickApp: () => ipcRenderer.invoke('pick-app'),
  listApps: () => ipcRenderer.invoke('list-apps'),
  pathForFile: f => { try { return webUtils.getPathForFile(f) || ''; } catch (e) { return ''; } },
  photoSave: buf => ipcRenderer.invoke('photo-save', buf),
  sysStats: () => ipcRenderer.invoke('sys-stats'),
  fetchJson: u => ipcRenderer.invoke('fetch-json', u),
  downloadsActive: () => ipcRenderer.invoke('downloads-active'),
  updaterState: () => ipcRenderer.invoke('updater-state'),
  updaterCheck: () => ipcRenderer.invoke('updater-check'),
  updaterInstall: () => ipcRenderer.invoke('updater-install'),
  updaterSetRepo: r => ipcRenderer.invoke('updater-set-repo', r),
  appInfo: () => ipcRenderer.invoke('app-info'),
  quit: () => ipcRenderer.send('quit'),
  on: (ch, fn) => {
    const ok = ['open', 'close', 'clip-add', 'cfg-changed', 'updater-state', 'focus-ai'];
    if (ok.includes(ch)) on(ch, fn);
  }
});
