'use strict';
// Pure, dependency-free update rules for NOTCH for Windows (unit-tested in tests/updater-core.test.js).
//
// ISOLATION FROM THE MAC APP
// The Mac app asks GitHub for "releases/latest" of its own repo and then runs build.sh from the download.
// The Windows app never touches that repo and only ever accepts a release that
//   1. lives in a repo that is not the Mac repo (and has no "mac" in its name),
//   2. has a tag of the form  win-vX.Y.Z   (a Mac tag such as v3.4.2 is ignored),
//   3. carries an asset named exactly  NOTCH-Windows-X.Y.Z.zip  whose version matches the tag,
//   4. has a SHA-256 (GitHub's digest field, or a NOTCH-Windows-X.Y.Z.zip.sha256 asset),
//   5. unpacks to a folder holding NOTCH.exe + windows-build.json (product NOTCH-Windows, platform win32)
//      and contains no build.sh / *.swift / Info.plist.

const MAC_REPO = 'coooooooooooops/notch-for-mac';
const DEFAULT_REPO = 'coooooooooooops/Notch-For-Windows';
const TAG_RE = /^win-v(\d+)\.(\d+)\.(\d+)$/i;
const ASSET_RE = /^NOTCH-Windows-(\d+)\.(\d+)\.(\d+)\.zip$/;

function normalizeRepo(s) {
  let t = String(s == null ? '' : s).trim();
  t = t.replace(/^https?:\/\/(www\.)?github\.com\//i, '').replace(/^github\.com\//i, '');
  t = t.replace(/\.git$/i, '').replace(/\/+$/, '');
  const parts = t.split('/').filter(Boolean);
  return parts.length >= 2 ? parts[0] + '/' + parts[1] : t;
}

/** Returns {ok:true, repo} or {ok:false, reason}. */
function checkRepo(input) {
  const repo = normalizeRepo(input);
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repo)) return { ok: false, reason: 'Enter the repo as owner/name' };
  if (repo.toLowerCase() === MAC_REPO) return { ok: false, reason: 'That is the Mac app\'s repo. Windows updates must live in their own repo.' };
  if (/mac/i.test(repo.split('/')[1])) return { ok: false, reason: 'The repo name looks like the Mac one. Use a separate Windows repo.' };
  return { ok: true, repo };
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

module.exports = { MAC_REPO, DEFAULT_REPO, TAG_RE, ASSET_RE, normalizeRepo, checkRepo, parseTag, parseVersion, isNewer, pickRelease, parseShaFile, foreignFileReason, markerReason };
