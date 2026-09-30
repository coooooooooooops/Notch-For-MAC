NOTCH

A menu-bar app that turns the MacBook notch into a pop-out shelf. Hover over the notch (or click it, if you prefer) and it expands into a set of tabs: music, file shelf, clipboard, timers, notes, browser, camera, calendar, system stats and more. When something is happening in the background (music, a timer, a download, a call) a slim live pill grows beside the notch.

Works on Apple Silicon and Intel Macs running macOS 13 or newer. Personal-use project.

Install
Unzip NOTCH.zip, then open Terminal.
Install Apple's build tools (skip if you already have Xcode):
   xcode-select --install
Build and install:
   cd ~/Downloads/NOTCH
   xattr -dr com.apple.quarantine .
   bash build.sh

build.sh builds a universal app, installs it to /Applications, launches it, and also writes NOTCH.dmg (open it and drag NOTCH onto Applications). The menu-bar icon holds Launch at Login, Click to Expand (instead of hover) and Quit NOTCH.

Tabs
Tab	What it does
Music	Now playing from Spotify, Apple Music, or Safari (YouTube, YouTube Music, Spotify Web). Play/pause, next/previous, a draggable song-position bar with elapsed and remaining time, and live animated bars. Right-click the clock or date to change its colour.
Shelf	Drop files on the shelf, drag them back out later, right-click to remove. The AirDrop tile sends whatever is on the shelf, or lets you pick files, or takes files dropped straight onto it.
Clipboard	The last 20 things you copied. Click one to copy it again.
Timers	A focus / break timer (25 and 5 minutes) and a stopwatch.
Notes	A notes box plus two fully customisable counter cards: Water (with a progress ring toward a goal) and Counter. Tap the sliders icon on a card to change its name, unit, step size, goal and colour, set the value directly, and choose whether it resets daily.
Apps	A launcher for your favourite apps. Press + to add one, right-click to remove.
Browser	A small web browser with back, forward, reload, and an address/search bar. Pages open at 70% zoom so they fit the panel; use the magnifier − / + buttons to zoom from 40% to 150% (click the percentage to reset). It starts fresh every time the notch closes.
Camera	A mirror with a shutter button (or press Space). Photos are saved to Pictures/NOTCH; click the thumbnail to reveal the latest one in Finder.
Calendar	A month grid or list view, today's and tomorrow's events, and your open reminders.
System	Live download speed graph, Wi-Fi signal, CPU and memory use.
Shortcuts	Run your Apple Shortcuts from the notch.
Themes	Accent colour, clock colour, font style, corner roundness and live-pill width.
Updater	Shows the latest release and installs it. See below.
Live pill

When the notch is closed, a slim pill grows beside it for: music playing, a running timer or stopwatch, a download in progress (from your Downloads folder), and microphone or call activity (FaceTime, Zoom, Teams, Discord). Adjust its width in Themes > Pill width.

Updates

The Updater tab shows the latest release: its name, tag, date and notes, and a green tick when you are up to date. A red dot on the tab icon means a newer version is ready.

Ask me first: press Install when you are ready.
Update automatically: NOTCH downloads, rebuilds and restarts itself as soon as a new release is posted.

Change this with the gear icon in the tab. NOTCH checks on launch and every 3 hours; the circular arrow checks right now. Installing needs Xcode Command Line Tools (same as a normal build). If an update fails to build, your current NOTCH is left untouched and the log is saved to ~/Library/Application Support/NOTCH/update.log.

Publishing a new version
Change the number in the VERSION file.
Zip the whole NOTCH folder.
On GitHub, create a release with a higher tag (for example v3.0.2), write the release notes, attach the zip, and publish.

Drafts and pre-releases are ignored by the updater.

Permissions

macOS will ask the first time a feature needs access: Automation (to read and control Music and Spotify), Camera, Calendars and Reminders, and the Downloads folder (for download progress in the live pill).

Safari / YouTube music

In Safari: Settings > Advanced, tick "Show features for web developers", then Develop > Developer Settings > Allow JavaScript from Apple Events (older macOS: Develop > Allow JavaScript from Apple Events). Approve the Automation prompt for Safari. Play/pause work on any site; next/previous work on YouTube, YouTube Music and Spotify Web.

Recent changes
3.0.1: the browser now fits the panel, with adjustable zoom.
3.0.0: new Updater tab that installs releases from GitHub.
