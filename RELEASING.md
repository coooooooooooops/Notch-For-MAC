# Releasing (Mac + Windows in one repo)

Repo layout
- repo root = Mac app (build.sh, the .swift files ...). Kept at the top level so installed Macs keep updating.
- /windows  = NOTCH for Windows
- /.github/workflows = two robots: mac-release.yml (tags v3.4.2) and windows-release.yml (tags win-v1.0.2)

Two release streams, never mixed
| | Mac | Windows |
|---|---|---|
| Tag | v3.4.2 | win-v1.0.2 |
| Marked "Latest" | YES (automatic) | NO (automatic) |
| Asset | NOTCH.zip (Mac files only) | NOTCH-Windows-1.0.2.zip + .sha256 |
| Who reads it | Mac app | Windows app |

## New Mac version
1. Change the number in `VERSION` (root).  Optional notes: `release-notes/X.Y.Z.md` (the Updater tab shows them).
2. Test it: `bash build.sh` in the repo folder.
3. Commit and push, then create the tag `vX.Y.Z` on that commit and push the tag.
4. The robot checks tag = VERSION, zips the Mac files, publishes with Latest ON, and fails if Latest ends up anywhere else.

## New Windows version
1. Change the number in `windows/package.json` AND `windows/VERSION` (same X.Y.Z).  Optional notes: `windows/release-notes/X.Y.Z.md`.
2. Commit and push, then create the tag `win-vX.Y.Z` and push it.
3. The robot checks tag = version, runs the tests, builds, publishes with Latest OFF, and fails if a Windows release is Latest.

## If a robot fails
Open the repo's Actions tab, click the red run, and read the red step. Fix it, delete the tag and the half-made release, and tag again.
If a Windows release ever shows as "Latest": open the newest Mac release > Edit > tick "Set as the latest release" > Update release.
(Macs on 3.4.1 or older rely on that rule; from 3.4.2 on the Mac app also ignores win- tags by itself.)
