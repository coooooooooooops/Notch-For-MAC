# NOTCH

A menu-bar app that turns the MacBook notch into a pop-out shelf. Hover over the notch (or click it, if you prefer) and it expands into a set of tabs: music, file shelf, clipboard, timers, notes, an AI assistant, browser, camera, calendar, system stats, a Control Centre and more. When something is happening in the background (music, a timer, a download, a call) a slim live pill grows beside the notch.

Works on Apple Silicon and Intel Macs running macOS 13 or newer. Personal-use project.

## Install

1. Unzip `NOTCH.zip`, then open Terminal.
2. Install Apple's build tools (skip if you already have Xcode):
   ```
   xcode-select --install
   ```
3. Build and install:
   ```
   cd ~/Downloads/NOTCH
   xattr -dr com.apple.quarantine .
   bash build.sh
   ```

If a build ever fails, run `bash build.sh 2>&1 | grep error:` in the NOTCH folder to see the first error. (From the Updater, the same log is in `~/Library/Application Support/NOTCH/update.log`.)

`build.sh` builds a universal app, installs it to `/Applications`, launches it, and also writes `NOTCH.dmg` (open it and drag NOTCH onto Applications). The menu-bar icon holds **Launch at Login**, **Click to Expand (instead of hover)**, **Hotkeys** (a list of your current hotkeys) and **Quit NOTCH**.

## Tabs

| Tab | What it does |
|---|---|
| **Music** | Now playing from Spotify, Apple Music, or Safari (YouTube, YouTube Music, Spotify Web). Play/pause, next/previous, a draggable song-position bar with elapsed and remaining time, and live animated bars. Right-click the clock or date to change its colour. |
| **Shelf** | Drop files on the shelf, drag them back out later, right-click to remove. The AirDrop tile sends whatever is on the shelf, or lets you pick files, or takes files dropped straight onto it. |
| **Clipboard** | Your recent copies (up to 50), plus a small strip of thumbnails of the last 10 copied **images** and screenshots (click one to copy it again, drag it out, or right-click to delete; images live on disk, not in memory, and are wiped each time NOTCH starts). Click one to copy it again. Press the **pin** to keep something: pinned items sit at the top, are saved between launches, and never get pushed out. A search box filters both pinned and recent items, and **Clear history** wipes the unpinned text and all images. Right-click an item to pin or delete it. |
| **Timers** | A focus / break timer and a stopwatch. Set your own lengths with the − / + pills under the timer (focus 1 to 180 minutes, break 1 to 60); they are remembered. Defaults are 25 and 5. When a focus or break period ends the notch plays a chime and does a short jelly **wobble** (it squishes and bounces without expanding). |
| **Notes** | As many notes as you like. Give each one a name at the top, press the list button to see them all (most recent first), the **+** for a new one, and the trash to delete. The note you were on stays open, even after the notch closes, until you press the list button yourself. Next to it are two fully customisable counter cards: **Water** (with a progress ring toward a goal) and **Counter**. Tap the sliders icon on a card to change its name, unit, step size, goal and colour, set the value directly, and choose whether it resets daily. |
| **Apps** | Your favourite apps and websites. Press **+** to add a Mac app or any website. Apps with a web version (Spotify, WhatsApp, Discord, Slack, Notion, Telegram, Teams, Outlook, Office, YouTube, Apple's Notes, Reminders, Calendar, Mail and many more) open **inside the notch**, so you never have to open the Mac app; they show a small notch badge. Other apps launch as normal. Right-click an app to give it a web address, switch back to the Mac app, or remove it. Press **Apps** to go back to the grid. Pages stay loaded when the notch closes, so music keeps playing. See below. |
| **AI** | Pick an AI app you already have installed (ChatGPT, Claude, Gemini, Perplexity, Copilot, Grok, DeepSeek, Le Chat or Poe) and chat with it right inside the notch, without opening the app. NOTCH scans your Applications folder and shows the icons of the ones it finds. Your pick is remembered; press **Switch** to choose another. It's fully free: no API key, it uses that AI's own web version, so sign in once and you stay signed in. **Drag a file or selected text onto the chat** and it is pasted into the message box (small text and code files are pasted as text, images and other files as attachments if the site accepts them). |
| **Browser** | A small web browser with back, forward, reload, and an address/search bar. Pages open at 60% zoom so they fit the panel; use the magnifier − / + buttons to zoom from 40% to 150% (click the percentage to reset). It starts fresh every time the notch closes. |
| **Camera** | A mirror with a shutter button (or press Space). Photos are saved to `Pictures/NOTCH`; click the thumbnail to reveal the latest one in Finder. |
| **Calendar** | A month grid or list view and your open reminders. Click any day to see its events (with times and calendar colours); the arrows move between months and clicking the month name jumps back to today. Orange dots mark days that have something on. |
| **System** | Live download speed graph, Wi-Fi signal, CPU and memory use. |
| **Control Centre** | Wi-Fi, Bluetooth, Dark Mode, Night Shift, Low Power Mode, Screenshot, Sleep Display and System Settings tiles, plus brightness, keyboard backlight and volume sliders (tap the speaker to mute) and a battery readout. The Bluetooth tile opens a list of your paired devices so you can connect or disconnect them right from the notch. See below. |
| **Weather** | Search for any city or town and save as many places as you like (free data from Open-Meteo, no account needed). Shows the current conditions, the next 12 hours and a 7-day forecast, with a °C / °F button. Your places, your pick and your unit are remembered, and the tab stays on the place you chose until you change it. Right-click a place to remove it, or use the + to add another. |
| **Settings** (cog icon) | Accent colour, clock colour, font style, corner roundness, live-pill width, **Customise tabs**, the **Ask me first / Update automatically** choice, and your **hotkeys**. |
| **Updater** | Shows the latest release and installs it. See below. |

## Battery icon and Control Centre

The battery icon in the top-right of the notch fills to match your charge. It is **white** normally, **green** while charging, **yellow** in Low Power Mode and **red** under 20%.

Control Centre notes:

- **Brightness** controls the built-in display only (the slider greys out if macOS won't allow it).
- **Bluetooth** opens a list of every device your Mac has paired with (AirPods, headphones, speakers, keyboards, mice, controllers). Tap a device to connect it, tap a connected one to disconnect it; connected devices show a blue tick. Use the arrow at the top to go back. Pair new devices in System Settings first.
- **Dark Mode** asks for Automation access to System Events the first time.
- **Night Shift** and the **keyboard backlight** slider use private macOS calls. If your macOS version doesn't allow them, the tile says "Unavailable" or the slider greys out.
- **Screenshot** lets you drag-select an area. It is saved to your Desktop like a normal macOS screenshot and also added to your Shelf so you can drag it straight into a message. macOS will ask for Screen Recording permission the first time.
- **Low Power** asks for your Mac password **once**, the first time you use it. That installs a tiny rule (`/etc/sudoers.d/notch-lowpower`) allowing only the Low Power Mode command without a password. After that it switches instantly with no prompts. If something goes wrong the tile says so, and every step is logged to `~/Library/Application Support/NOTCH/lowpower.log`. To undo the setup, delete the rule file.

## Customise tabs, hotkeys and memory

- **Hide and reorder tabs:** right-click the row of tab icons, or press **Customise tabs** in Settings. Use the arrows to move a tab, the eye to hide it, and **Reset** to put everything back. At least one tab always stays visible.
- **Hotkeys:** three global hotkeys work from any app. Press one again (or click elsewhere, or press Esc) to put the notch away.

  | Hotkey | Does |
  |---|---|
  | **⌃⌥N** (Control + Option + N) | Opens or closes the notch |
  | **⌃⌥A** | Ask AI: opens the AI tab with the cursor in the chat box |
  | **⌃⌥V** | Opens the Clipboard tab |

  Change or turn off any of them in **Settings > Hotkeys**: click a key box, then press the combination you want (the arrow resets it, the × turns it off). Every hotkey has to use **Control + Option together**. That rule keeps them from clashing with ⌘ shortcuts such as ⌘⇧4 (screenshots), ⌘Space (Spotlight) or ⌘Tab, with Option+letter typing special characters, and with Ctrl+A / Ctrl+E text editing. NOTCH tells you if a combination is already taken. (If you use VoiceOver, which also uses Control + Option, change them here.) The menu-bar icon has a **Hotkeys** list that always shows your current keys.
- **Pasting:** Cmd+V, Cmd+C, Cmd+X, Cmd+A and Cmd+Z now work in every tab (notes, address bar, search box, web pages).
- **Memory:** pages in the AI and Apps tabs stay loaded so chats and music carry on, but a page you haven't looked at for 30 minutes is unloaded to free memory (never while it is playing audio). It reloads next time you open it. Change the delay, or turn this off, in **Customise tabs**.

## Apps inside the notch

macOS doesn't let one app place another app's window inside its own, so NOTCH runs each app's **web version** instead (the same way the AI tab works). Sign in once and you stay signed in.

- Known apps are matched automatically by name. For any other Mac app, right-click it and choose **Open inside the notch**, then enter its web address.
- **Add a website as an app** lets you add anything with an address (for example `notion.so`), with its own icon.
- Apps open at 60% zoom; use the magnifier buttons to zoom (40% to 150%, click the percentage to reset). The arrow button opens the real Mac app.
- Web versions behave like Safari, so a few features (such as some copy-protected media) can differ from the Mac app.

## Live pill

When the notch is closed, a slim pill grows beside it for: music playing, a running timer or stopwatch, a download in progress (from your Downloads folder), and microphone or call activity (FaceTime, Zoom, Teams, Discord). Adjust its width in **Settings > Pill width**.

## Updates

The **Updater** tab shows the latest release: its name, tag, date and notes, and a green tick when you are up to date. A red dot on the tab icon means a newer version is ready.

- **Ask me first:** press **Install** when you are ready.
- **Update automatically:** NOTCH downloads, rebuilds and restarts itself as soon as a new release is posted.

Change this with the gear icon in the tab. NOTCH checks on launch and every 3 hours; the circular arrow checks right now. Installing needs Xcode Command Line Tools (same as a normal build). If an update fails to build, your current NOTCH is left untouched and the log is saved to `~/Library/Application Support/NOTCH/update.log`.

## Publishing a new version

1. Change the number in the `VERSION` file.
2. Zip the whole `NOTCH` folder.
3. On GitHub, create a release with a higher tag (for example `v3.3.2`), write the release notes, attach the zip, and publish.

Drafts and pre-releases are ignored by the updater.

## Permissions

macOS will ask the first time a feature needs access: Automation (to read and control Music and Spotify, and to switch Dark Mode), Camera, Bluetooth, Calendars and Reminders, and the Downloads folder (for download progress in the live pill).

## Safari / YouTube music

In Safari: **Settings > Advanced**, tick "Show features for web developers", then **Develop > Developer Settings > Allow JavaScript from Apple Events** (older macOS: **Develop > Allow JavaScript from Apple Events**). Approve the Automation prompt for Safari. Play/pause work on any site; next/previous work on YouTube, YouTube Music and Spotify Web.

## Recent changes

- **3.4.0**: Notes now supports many named notes with a list view; the clipboard keeps a small history of copied images; new Weather tab with search and saved places; the Themes tab (palette icon) is now **Settings** (cog icon) and also holds the update choice and hotkeys; hotkeys are customisable, gain **Ask AI** and **Clipboard** hotkeys, and are restricted to Control + Option combinations so they can't clash with standard shortcuts.
- **3.3.3**: fixes the "Build failed" error when installing 3.3.x with the newest Apple build tools. Two things stopped it compiling: the clipboard search box used SwiftUI's `@State`, which newer SDKs turned into an Xcode-only macro, and the drag-and-drop handlers for the AI and Apps pages now need the `override` keyword. Both are fixed, so NOTCH builds with Command Line Tools alone again.
- **3.3.2**: fixes a build error in 3.3.0 and 3.3.1 (the update could not compile); the Calendar tab now lets you click any day to see its events and use the arrows to move between months; Cmd+V now works inside pop-up boxes such as "Add a website as an app"; the Apps and Browser tabs now open at 60% zoom by default; a failed update now shows the first compiler error in the Updater tab.
- **3.3.1**: removed the Focus tile from Control Centre (macOS doesn't let an app switch Do Not Disturb without a Shortcut).
- **3.3.0**: tabs can be hidden and reordered; clipboard pinning and search; drag files or text onto the AI and Apps pages; idle web pages are unloaded to save memory; global hotkey; Control Centre gains Night Shift, Screenshot and keyboard backlight; the notch wobbles when a timer ends; Cmd+V (and copy, cut, select all, undo) now works everywhere.
- **3.2.0**: the Apps tab can now run apps inside the notch using their web versions, with support for adding any website as an app.
- **3.1.2**: more reliable Low Power Mode switching (it now judges success by whether the mode really changed, not by a command's exit code, and reports problems on the tile and in a log).
- **3.1.1**: Low Power Mode switches without a password after a one-time setup; the Bluetooth tile is now a device picker for connecting and disconnecting your paired devices.
- **3.1.0**: customisable focus and break timer; new AI tab that runs an AI app you already have installed inside the notch; battery icon now matches your charge and turns green, yellow or red; the Shortcuts tab is replaced by a Control Centre; larger release notes text in the Updater.
- **3.0.1**: the browser now fits the panel, with adjustable zoom.
- **3.0.0**: new Updater tab that installs releases from GitHub.
