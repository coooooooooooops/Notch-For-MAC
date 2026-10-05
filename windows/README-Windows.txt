NOTCH for Windows
=================

A thin bar at the top-centre of your screen that expands into a pop-out shelf when you hover over it:
music, file shelf, clipboard, timers, notes, apps, AI, browser, camera, calendar, system stats,
a Control Centre, weather and settings. When something is happening (music, a timer, a download, a call)
a slim live pill grows out of the bar.

Needs: Windows 10 (version 1809 or newer) or Windows 11, 64-bit. No admin rights needed.


INSTALL
-------
1. Right-click the downloaded zip > Extract All.   (Do not run anything from inside the zip.)
2. Open the extracted folder and double-click  Install.bat
3. If Windows says "Windows protected your PC" (the app is not code-signed): click  More info > Run anyway.
4. NOTCH copies itself to  %LOCALAPPDATA%\Programs\NOTCH , adds a Start-menu shortcut and starts.
   Look for the thin bar at the top-centre of your screen and hover over it.

To remove it: run  Uninstall.bat  (or delete the folder above and the Start-menu shortcut).


USING IT
--------
Hover the bar (or click it, if you turn on "Click to Expand" in the tray menu). Move the mouse away, press Esc, or
click elsewhere to put it away. The tray icon (bottom-right, maybe under the ^ arrow) has Launch at Login,
Click to Expand, the hotkey list, Check for updates, Open data folder and Quit.

Hotkeys (change them in Settings; every hotkey must use Ctrl + Alt together):
  Ctrl+Alt+N   open / close NOTCH
  Ctrl+Alt+A   Ask AI (opens the AI tab, cursor in the chat box)
  Ctrl+Alt+V   Clipboard tab

Tabs: Music - Shelf - Clipboard - Timers - Notes - Apps - AI - Browser - Camera - Calendar - System -
Control Centre - Weather - Settings - Updater. Right-click the row of tab icons to hide or reorder tabs.

Differences from the Mac version (Windows works differently):
  * Music shows whatever Windows reports as playing (Spotify, Apple Music, Chrome/Edge tabs, VLC...), no Safari setup needed.
  * Calendar is your own events and reminders (Windows has no shared calendar API), stored on this PC.
  * Control Centre tiles open the matching Windows settings page; Dark mode, volume, brightness (laptop screens only),
    Screenshot (Windows snipping, copied to your clipboard) and Sleep display work directly. There is no keyboard-backlight slider.
  * Camera pictures are saved to  Pictures\NOTCH.
  * AI and Apps run each service's website inside the notch (sign in once and you stay signed in).


UPDATES (one shared repo, completely separate release streams)
--------------------------------------------------------------
Mac and Windows live in the same GitHub repo (coooooooooooops/Notch-For-MAC): Mac at the top level, Windows in /windows.
NOTCH for Windows only accepts a release that has ALL of these:
  * a tag like  win-v1.0.2  (Mac tags such as v3.4.2 are ignored),
  * an asset named exactly  NOTCH-Windows-1.0.2.zip  with a matching SHA-256 checksum,
  * a package that contains NOTCH.exe and windows-build.json (product NOTCH-Windows, platform win32),
  * and no Mac files (build.sh, *.swift, Info.plist ...).
Windows releases are published with "Latest" switched OFF, so the Mac app (which reads the repo's Latest release) never sees them.

To publish a new Windows version: see RELEASING.md (short version: raise the number in windows/package.json AND windows/VERSION,
commit, then push a tag  win-vX.Y.Z  - GitHub Actions tests, builds and publishes it).
Drafts and pre-releases are ignored. The app checks on launch and every 3 hours; the Updater tab has a Check button.
"Auto-update" in Settings installs new releases by itself; otherwise press Install in the Updater tab.


IF SOMETHING GOES WRONG
-----------------------
  * Logs:  %APPDATA%\NOTCH\notch.log  (app)  and  %APPDATA%\NOTCH\update.log  (updates). Tray menu > Open data folder.
  * If an update fails, the current version is left in place and keeps running.
  * Nothing appears at the top of the screen: check the tray icon; use Ctrl+Alt+N; run Install.bat again.
  * Settings and notes live in %APPDATA%\NOTCH and survive updates and re-installs.
