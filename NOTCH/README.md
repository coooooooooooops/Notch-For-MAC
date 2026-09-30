# NOTCH

## Install (Terminal)
1. Unzip NOTCH.zip, then open Terminal.
2. Install Apple's build tools (skip if you already have Xcode): `xcode-select --install`
3. Run:
       cd ~/Downloads/NOTCH
       xattr -dr com.apple.quarantine .
       bash build.sh
4. It builds a universal app, installs it to /Applications and launches it. Menu-bar icon = Launch at Login, Click-to-Expand, Quit.

## Safari / YouTube music
Safari > Settings > Advanced > tick "Show features for web developers", then
Develop menu > Developer Settings > "Allow JavaScript from Apple Events" (older macOS: Develop > "Allow JavaScript from Apple Events").
Approve the Automation prompt for Safari. Play/pause work on any site; next/previous work on YouTube, YouTube Music, Spotify Web.

## Tips
Right-click the clock/date to change its colour. The calendar tab has a month-grid / list toggle.

## v2
build.sh now also makes NOTCH.dmg (open it, drag NOTCH onto Applications). Themes tab = last icon. Live pill shows timers, music, downloads (Downloads folder permission) and mic/call use.

## v3
- **Live pill** (the bit that grows beside the notch for music / timers / downloads / mic) is much slimmer so it stops covering menu-bar items. Themes tab > "Pill width" slider lets you fine-tune it (40-170, default 92).
- **Browser tab** now opens a much bigger panel (820 x 460) with back / forward / reload, keeps your page when you switch tabs, opens "new tab" links in place, and has elastic (rubber-band) scrolling turned off.
- **Water + Counter** are fully customisable: tap the sliders icon on a card to change the name, unit, step size, goal (progress ring), set the value directly, pick a colour and choose whether it resets daily.
- **AirDrop tile**: click it to send whatever is on the shelf (or pick files if the shelf is empty), or drop files straight onto it. Falls back to the normal share menu if direct AirDrop is unavailable.
- **Snake** = last (gamepad) tab. Silent. Arrows / WASD to steer, Space or P to pause, R to restart, click the board to start / pause. Walls or Wrap mode, levels, speed ramp, golden bonus stars, best score saved per mode. The game auto-pauses when the notch closes.
