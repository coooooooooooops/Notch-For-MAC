NOTCH

A menu-bar app that turns the MacBook notch into a pop-out shelf. Hover over the notch (or click it, if you prefer) and it expands into a set of tabs: music, file shelf, clipboard, timers, notes, an AI assistant, browser, camera, calendar, system stats, a Control Centre and more. When something is happening in the background (music, a timer, a download, a call) a slim live pill grows beside the notch.

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
Timers	A focus / break timer and a stopwatch. Set your own lengths with the − / + pills under the timer (focus 1 to 180 minutes, break 1 to 60); they are remembered. Defaults are 25 and 5.
Notes	A notes box plus two fully customisable counter cards: Water (with a progress ring toward a goal) and Counter. Tap the sliders icon on a card to change its name, unit, step size, goal and colour, set the value directly, and choose whether it resets daily.
Apps	A launcher for your favourite apps. Press + to add one, right-click to remove.
AI	Pick an AI app you already have installed (ChatGPT, Claude, Gemini, Perplexity, Copilot, Grok, DeepSeek, Le Chat or Poe) and chat with it right inside the notch, without opening the app. NOTCH scans your Applications folder and shows the icons of the ones it finds. Your pick is remembered; press Switch to choose another. It's fully free: no API key, it uses that AI's own web version, so sign in once and you stay signed in.
Browser	A small web browser with back, forward, reload, and an address/search bar. Pages open at 70% zoom so they fit the panel; use the magnifier − / + buttons to zoom from 40% to 150% (click the percentage to reset). It starts fresh every time the notch closes.
Camera	A mirror with a shutter button (or press Space). Photos are saved to Pictures/NOTCH; click the thumbnail to reveal the latest one in Finder.
Calendar	A month grid or list view, today's and tomorrow's events, and your open reminders.
System	Live download speed graph, Wi-Fi signal, CPU and memory use.
Control Centre	Wi-Fi, Bluetooth, Dark Mode, Low Power Mode, Sleep Display and System Settings tiles, plus brightness and volume sliders (tap the speaker to mute) and a battery readout. The Bluetooth tile opens a list of your paired devices so you can connect or disconnect them right from the notch. See below.
Themes	Accent colour, clock colour, font style, corner roundness and live-pill width.
Updater	Shows the latest release and installs it. See below.
Battery icon and Control Centre

The battery icon in the top-right of the notch fills to match your charge. It is white normally, green while charging, yellow in Low Power Mode and red under 20%.

Control Centre notes:

Brightness controls the built-in display only (the slider greys out if macOS won't allow it).
Bluetooth opens a list of every device your Mac has paired with (AirPods, headphones, speakers, keyboards, mice, controllers). Tap a device to connect it, tap a connected one to disconnect it; connected devices show a blue tick. Use the arrow at the top to go back. Pair new devices in System Settings first.
Dark Mode asks for Automation access to System Events the first time.
Low Power asks for your Mac password once, the first time you use it. That installs a tiny rule (/etc/sudoers.d/notch-lowpower) allowing only the Low Power Mode command without a password. After that it switches instantly with no prompts. To undo it, delete that file.
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
On GitHub, create a release with a higher tag (for example v3.1.2), write the release notes, attach the zip, and publish.

Drafts and pre-releases are ignored by the updater.

Permissions

macOS will ask the first time a feature needs access: Automation (to read and control Music and Spotify, and to switch Dark Mode), Camera, Bluetooth, Calendars and Reminders, and the Downloads folder (for download progress in the live pill).

Safari / YouTube music

In Safari: Settings > Advanced, tick "Show features for web developers", then Develop > Developer Settings > Allow JavaScript from Apple Events (older macOS: Develop > Allow JavaScript from Apple Events). Approve the Automation prompt for Safari. Play/pause work on any site; next/previous work on YouTube, YouTube Music and Spotify Web.

Recent changes
3.1.1: Low Power Mode switches without a password after a one-time setup; the Bluetooth tile is now a device picker for connecting and disconnecting your paired devices.
3.1.0: customisable focus and break timer; new AI tab that runs an AI app you already have installed inside the notch; battery icon now matches your charge and turns green, yellow or red; the Shortcuts tab is replaced by a Control Centre; larger release notes text in the Updater.
3.0.1: the browser now fits the panel, with adjustable zoom.
3.0.0: new Updater tab that installs releases from GitHub.
