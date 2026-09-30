NOTCH

A tiny SwiftUI app that turns your MacBook's notch into a hub for music, files, timers, notes, a mini browser and a silent game of Snake. Hover over the notch and it expands.

Mac only. Requires macOS 13 (Ventura) or newer. Runs on Apple Silicon and Intel.

Install (recommended)
Go to the Releases page.
Download NOTCH.dmg.
Open the DMG and drag NOTCH onto Applications.
Launch NOTCH from Applications. Its icon appears in your menu bar.
First launch: "NOTCH can't be opened"

NOTCH isn't notarized by Apple, so macOS may block it the first time. Either:

Right-click NOTCH in Applications, choose Open, then Open again, or
Run this in Terminal:
bash
xattr -dr com.apple.quarantine /Applications/NOTCH.app
Build from source

You need Apple's command line tools (xcode-select --install).

bash
git clone https://github.com/<your-username>/NOTCH.git
cd NOTCH
bash build.sh

This builds a universal app, installs it to /Applications, makes NOTCH.dmg, and launches it.

Features
Tab	What it does
Music	Now playing and controls for Apple Music, Spotify, and Safari / YouTube tabs
Shelf + AirDrop	Drop files to hold them, drag them out later, or click the AirDrop tile to send them
Clipboard	History of your last 20 copied items, click to copy again
Timers	Focus / break timer and a stopwatch
Tools	Notes, plus a customisable water tracker and counter (name, unit, step, goal, colour, daily reset)
Apps	Your own quick-launch shelf
Browser	Mini web browser with back, forward and reload
Camera	Mirror
Calendar	Month grid or list, events and reminders
System	CPU, memory, network and Wi-Fi
Shortcuts	Run your Shortcuts app shortcuts
Themes	Accent and clock colours, font, corner radius, live pill width
Snake	Silent, fully playable Snake with score, levels, bonus stars and Walls / Wrap modes

The live pill grows beside the notch to show music, timers, downloads and mic / call activity.

Controls
Hover the notch to expand. Choose Click to Expand in the menu-bar icon if you prefer clicking.
Right-click the clock to change its colour.
Snake: arrow keys or WASD to steer, Space or P to pause, R to restart.
Menu-bar icon: Launch at Login, Click to Expand, Quit.
Permissions

macOS will ask for these as you use the matching features: Automation (Music, Spotify, Safari), Calendars and Reminders, Camera, and Downloads folder access.

Safari / YouTube music: in Safari, turn on Settings > Advanced > "Show features for web developers", then Develop > Developer Settings > "Allow JavaScript from Apple Events".
