'use strict';
// Pure, dependency-free update rules for NOTCH for Windows (unit-tested in tests/updater-core.test.js).
//
// ISOLATION FROM THE MAC APP (one shared repo, two release streams)
// Mac releases are tagged  vX.Y.Z  and are the repo's "Latest" release. Windows releases are tagged  win-vX.Y.Z
// and are published with "Latest" switched OFF, so the Mac app's releases/latest lookup never sees them.
// The Windows app lists the repo's releases and only ever accepts a release that
//   1. is not a draft or pre-release,
//   2. has a tag of the form  win-vX.Y.Z   (a Mac tag such as v3.4.2 is ignored),
//   3. carries an asset named exactly  NOTCH-Windows-X.Y.Z.zip  whose version matches the tag,
//   4. has a SHA-256 (GitHub's digest field, or a NOTCH-Windows-X.Y.Z.zip.sha256 asset),
//   5. unpacks to a folder holding NOTCH.exe + windows-build.json (product NOTCH-Windows, platform win32)
//      and contains no build.sh / *.swift / Info.plist.

const DEFAULT_REPO = 'coooooooooooops/Notch-For-MAC';          // the one shared repo (Mac at the root, Windows in /windows)
const LEGACY_REPO = 'coooooooooooops/notch-for-windows';      // the old separate Windows repo (1.0.0 looked here)
const TAG_RE = /^win-v(\d+)\.(\d+)\.(\d+)$/i;
const ASSET_RE = /^NOTCH-Windows-(\d+)\.(\d+)\.(\d+)\.zip$/;

function normalizeRepo(s) {
  let t = String(s == null ? '' : s).trim();
  t = t.replace(/^https?:\/\/(www\.)?github\.com\//i, '').replace(/^github\.com\//i, '');
  t = t.replace(/\.git$/i, '').replace(/\/+$/, '');
  const parts = t.split('/').filter(Boolean);
  return parts.length >= 2 ? parts[0] + '/' + parts[1] : t;
}

/** Returns {ok:true, repo} or {ok:false, reason}. Only checks the shape: isolation comes from tags/assets/markers below. */
function checkRepo(input) {
  const repo = normalizeRepo(input);
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repo)) return { ok: false, reason: 'Enter the repo as owner/name' };
  return { ok: true, repo };
}

/** A saved setting that still names the retired separate Windows repo is moved to the shared repo. */
function migrateRepo(saved) {
  const n = normalizeRepo(saved);
  return n.toLowerCase() === LEGACY_REPO ? DEFAULT_REPO : saved;
}

function parseTag(tag) {
  const m = TAG_RE.exec(String(tag || ''));
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}
function parseVersion(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v || '').replace(/^v/i, ''));
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}
function cmp(a, b) {
  for (let i = 0; i < 3; i++) { if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1; }
  return 0;
}
function isNewer(a, b) {
  const x = Array.isArray(a) ? a : parseVersion(a), y = Array.isArray(b) ? b : parseVersion(b);
  if (!x || !y) return false;
  return cmp(x, y) > 0;
}

/** Looks at a GitHub /releases list and returns the newest acceptable Windows release (or null). */
function pickRelease(list) {
  if (!Array.isArray(list)) return null;
  let best = null;
  for (const r of list) {
    if (!r || r.draft || r.prerelease) continue;
    const v = parseTag(r.tag_name);
    if (!v) continue;
    const assets = Array.isArray(r.assets) ? r.assets : [];
    const zip = assets.find(a => {
      if (!a || typeof a.name !== 'string') return false;
      const m = ASSET_RE.exec(a.name);
      return !!m && cmp([Number(m[1]), Number(m[2]), Number(m[3])], v) === 0;
    });
    if (!zip || typeof zip.browser_download_url !== 'string' || !/^https:\/\//i.test(zip.browser_download_url)) continue;
    let sha = null;
    if (typeof zip.digest === 'string' && /^sha256:[0-9a-f]{64}$/i.test(zip.digest)) sha = zip.digest.slice(7).toLowerCase();
    const shaAsset = assets.find(a => a && a.name === zip.name + '.sha256' && typeof a.browser_download_url === 'string' && /^https:\/\//i.test(a.browser_download_url));
    if (!best || cmp(v, best.v) > 0) {
      best = {
        v,
        release: {
          tag: r.tag_name,
          version: v.join('.'),
          name: r.name || r.tag_name,
          body: r.body || '',
          published: r.published_at || '',
          url: r.html_url || '',
          asset: { name: zip.name, url: zip.browser_download_url, size: zip.size || 0, sha256: sha, shaUrl: shaAsset ? shaAsset.browser_download_url : null }
        }
      };
    }
  }
  return best ? best.release : null;
}

/** First 64-hex-digit token in a .sha256 file ("<hash>  filename" or just "<hash>"). */
function parseShaFile(text) {
  const m = /\b([0-9a-fA-F]{64})\b/.exec(String(text || ''));
  return m ? m[1].toLowerCase() : null;
}

/** names: list of relative paths inside an unpacked update. Returns a reason string if it must be rejected, else null. */
function foreignFileReason(names) {
  for (const n of names) {
    const base = String(n).split(/[\\/]/).pop().toLowerCase();
    if (base === 'build.sh' || base === 'info.plist' || base.endsWith('.swift') || base.endsWith('.app') || base.endsWith('.dmg')) {
      return 'The package contains Mac files (' + base + ')';
    }
  }
  return null;
}

/** marker = parsed windows-build.json. Returns a reason string if invalid, else null. */
function markerReason(marker, expectedVersion) {
  if (!marker || typeof marker !== 'object') return 'windows-build.json is missing';
  if (marker.product !== 'NOTCH-Windows') return 'This is not a NOTCH for Windows package';
  if (marker.platform !== 'win32') return 'This package is not for Windows';
  if (marker.version !== expectedVersion) return 'The package version does not match the release';
  return null;
}

module.exports = { DEFAULT_REPO, LEGACY_REPO, migrateRepo, TAG_RE, ASSET_RE, normalizeRepo, checkRepo, parseTag, parseVersion, isNewer, pickRelease, parseShaFile, foreignFileReason, markerReason };
