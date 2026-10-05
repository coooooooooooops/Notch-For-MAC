'use strict';
// NOTCH for Windows - boot: runs after every tab script has registered itself.
(function () {
  const N = window.N, api = N.api;
  window.addEventListener('error', e => { try { console.error('window error:', e.message); } catch (x) { /* ignore */ } });
  window.addEventListener('unhandledrejection', e => { try { console.error('unhandled rejection:', e.reason); } catch (x) { /* ignore */ } });
  try { N.applyAppearance(); } catch (e) { console.error('appearance', e); }
  try { N.initTop(); } catch (e) { console.error('top bar', e); }
  // every tab may expose N.startXxx() for background work (polling, timers); one failing never blocks the rest
  Object.keys(N).filter(k => /^start[A-Z]/.test(k) && typeof N[k] === 'function').forEach(k => {
    try { N[k](); } catch (e) { console.error(k, e); }
  });
  try { N.renderTabs(); } catch (e) { console.error('tabs', e); }
  api.ready();
})();
