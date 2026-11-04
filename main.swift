import SwiftUI
import AppKit
import IOKit.ps
import ServiceManagement
import UniformTypeIdentifiers

@discardableResult func osa(_ src: String) -> NSAppleEventDescriptor? {
    var e: NSDictionary?
    return NSAppleScript(source: src)?.executeAndReturnError(&e)
}
func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

final class Store: ObservableObject {
    static let shared = Store()
    @Published var expanded = false
    @Published var toast = ""                   // a short message bubble (Done, Copied 40 characters, ...)
    @Published var wob = false                  // the timer-done wobble is running: the shape follows the window
    @Published var showContent = false          // the tab contents bloom in as the shape opens
    @Published var mounted = false              // the tab contents exist (kept a moment after closing so they can fade out)
    @Published var lyricsOpen = false           // the music tab shows the full scrolling lyrics
    @Published var tw: CGFloat = 680            // size the notch is opening to
    @Published var th: CGFloat = 220
    @Published var cw: CGFloat = 200            // size of the closed notch (plus the live pill)
    @Published var ch: CGFloat = 32
    @Published var artColor: Color? = nil
    @Published var tab = 0
    @Published var files: [URL] = []
    @Published var clips: [String] = []
    @Published var pinned: [String] = [] { didSet { UserDefaults.standard.set(pinned, forKey: "pinnedClips") } }
    var forceOpen = false             // opened with the hotkey: stays open until hotkey / click away
    var onTimerDone: (() -> Void)?    // AppDelegate hooks this to wobble the notch
    @Published var track = "Nothing playing"
    @Published var artist = ""
    @Published var art: NSImage? { didSet { updateArtColor() } }
    @Published var playing = false
    @Published var pos = 0.0          // song position (seconds) at the moment of the last poll / seek
    @Published var dur = 0.0          // song length (seconds), 0 = unknown
    var posAt = Date()
    @Published var now = Date()
    @Published var battery = 100
    @Published var charging = false
    @Published var lowPower = false
    @Published var focusMins = 25 { didSet { UserDefaults.standard.set(focusMins, forKey: "focusMins") } }
    @Published var breakMins = 5 { didSet { UserDefaults.standard.set(breakMins, forKey: "breakMins") } }
    @Published var remaining = 1500
    @Published var running = false
    @Published var onBreak = false
    @Published var sw = 0
    @Published var swRunning = false
    @Published var water = 0 { didSet { UserDefaults.standard.set(water, forKey: "water") } }
    @Published var counter = 0 { didSet { UserDefaults.standard.set(counter, forKey: "counter") } }
    @Published var apps: [String] = [] { didSet { UserDefaults.standard.set(apps, forKey: "apps") } }
    var src = "Music"
    var lastPB = NSPasteboard.general.changeCount
    var n = 0
    var safW = 1, safT = 1, safBusy = false

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["waterDaily": true, "counterDaily": false, "pillExtra": 92.0,
                              "glass": true, "glassBody": false, "fluid": true, "haptics": true,
                              "lyrics": true, "artColors": false])
        if d.string(forKey: "lastDay") == nil, let old = d.string(forKey: "waterDay") { d.set(old, forKey: "lastDay") }
        water = d.integer(forKey: "water")
        counter = d.integer(forKey: "counter")
        apps = d.stringArray(forKey: "apps") ?? []
        pinned = d.stringArray(forKey: "pinnedClips") ?? []
        let fm = d.integer(forKey: "focusMins"), bm = d.integer(forKey: "breakMins")
        focusMins = fm > 0 ? fm : 25
        breakMins = bm > 0 ? bm : 5
        remaining = focusMins * 60
        rollover()
    }

    /// Focus / break length steppers: single minutes up to 5, then steps of 5.
    func stepMins(_ v: Int, up: Bool, maxV: Int) -> Int {
        if up { return min(maxV, v < 5 ? v + 1 : v + 5) }
        return max(1, v <= 5 ? v - 1 : v - 5)
    }
    func setFocus(_ m: Int) {
        focusMins = min(180, max(1, m))
        if !running && !onBreak { remaining = focusMins * 60 }
    }
    func setBreak(_ m: Int) {
        breakMins = min(60, max(1, m))
        if !running && onBreak { remaining = breakMins * 60 }
    }

    /// Resets the water / counter at midnight if their "Reset daily" switch is on.
    func rollover() {
        let d = UserDefaults.standard
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date())
        guard d.string(forKey: "lastDay") != day else { return }
        d.set(day, forKey: "lastDay")
        if d.bool(forKey: "waterDaily") { water = 0 }
        if d.bool(forKey: "counterDaily") { counter = 0 }
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        now = Date()
        let pw = Store.powerInfo()
        battery = pw.level; charging = pw.charging
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let pb = NSPasteboard.general
        if pb.changeCount != lastPB {
            lastPB = pb.changeCount
            if let t = pb.string(forType: .string) {
                if !t.isEmpty, !pinned.contains(t) {
                    clips.removeAll { $0 == t }; clips.insert(t, at: 0); clips = Array(clips.prefix(50))
                }
            } else {
                ClipImages.shared.capture(pb)      // a copied picture or screenshot
            }
        }
        if running {
            if remaining > 0 { remaining -= 1 } else {
                if !onBreak { PomoStats.record(focusMins) }      // a focus session just finished
                onBreak.toggle(); remaining = (onBreak ? breakMins : focusMins) * 60
                NSSound(named: NSSound.Name("Glass"))?.play()
                onTimerDone?()
            }
        }
        if swRunning { sw += 1 }
        n += 1
        if n % 30 == 0 { rollover() }
        if n % 2 == 0 { pollMusic() }
    }

    /// Battery percentage (-1 on a Mac without a battery) and whether it is charging right now.
    static func powerInfo() -> (level: Int, charging: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let c = d[kIOPSCurrentCapacityKey] as? Int {
                return (c, (d[kIOPSIsChargingKey] as? Bool) ?? false)
            }
        }
        return (-1, false)
    }

    /// Shows a short message in the notch for a moment.
    func say(_ text: String, hold: Double = 2.5) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            if self?.toast == text { self?.toast = "" }
        }
    }

    func isRunning(_ id: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id } }

    var musicBusy = false

    /// Asks Spotify / Music what is playing. The AppleScript runs in the background so it never freezes the notch.
    func pollMusic() {
        if musicBusy { return }
        let cands = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")].filter { isRunning($0.1) }
        if cands.isEmpty { pollSafari(); return }
        musicBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: (app: String, parts: [String])?
            for (app, _) in cands {
                let script = "tell application \"\(app)\" to if player state is playing then return (name of current track) & \"\\n\" & (artist of current track) & \"\\n\" & (player position as string) & \"\\n\" & (duration of current track as string)"
                if let r = osa(script)?.stringValue { found = (app, r.components(separatedBy: "\n")); break }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.musicBusy = false
                guard let f = found else { self.pollSafari(); return }
                let p = f.parts, app = f.app
                self.src = app; self.playing = true
                if p.count >= 4 {
                    self.pos = Store.num(p[2]); self.posAt = Date()
                    let d = Store.num(p[3]); self.dur = app == "Spotify" ? d / 1000 : d   // Spotify reports milliseconds
                }
                let title = p.first ?? ""
                if title != self.track {
                    self.track = title; self.artist = p.count > 1 ? p[1] : ""; self.art = nil
                    LyricsStore.shared.load(track: self.track, artist: self.artist, duration: self.dur)
                    DispatchQueue.global(qos: .utility).async {
                        var img: NSImage?
                        if app == "Spotify", let u = osa("tell application \"Spotify\" to return artwork url of current track")?.stringValue, let url = URL(string: u) {
                            if let d = try? Data(contentsOf: url) { img = NSImage(data: d) }
                        } else if app == "Music", let d = osa("tell application \"Music\" to return data of artwork 1 of current track")?.data {
                            img = NSImage(data: d)
                        }
                        if let img = img { DispatchQueue.main.async { if self.track == title { self.art = img } } }
                    }
                }
            }
        }
    }

    /// Picks a vivid colour from the cover so the notch can match the song.
    func updateArtColor() {
        guard let a = art, let tiff = a.tiffRepresentation else { artColor = nil; return }
        DispatchQueue.global(qos: .utility).async {
            guard let cg = NSBitmapImageRep(data: tiff)?.cgImage else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
            buf.initialize(repeating: 0, count: 256)
            defer { buf.deallocate() }
            guard let ctx = CGContext(data: buf, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
            for i in 0..<64 {
                let rr = Double(buf[i * 4]) / 255, gg = Double(buf[i * 4 + 1]) / 255, bb = Double(buf[i * 4 + 2]) / 255
                let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
                let sat = mx == 0 ? 0 : (mx - mn) / mx
                let w = sat * sat + 0.05
                r += rr * w; g += gg * w; b += bb * w; wsum += w
            }
            guard wsum > 0, let ns = NSColor(red: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1).usingColorSpace(.deviceRGB) else { return }
            var h: CGFloat = 0, sa: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
            ns.getHue(&h, saturation: &sa, brightness: &v, alpha: &al)
            let c = Color(hue: Double(h), saturation: Double(max(sa, 0.45)), brightness: Double(max(v, 0.85)))
            DispatchQueue.main.async { self.artColor = c }
        }
    }

    /// Parses "12.5" or "12,5" (some locales print a comma).
    static func num(_ t: String) -> Double { Double(t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0 }

    /// Where the song is right now (the last polled position plus the time since).
    func curPos() -> Double {
        let p = playing ? pos + Date().timeIntervalSince(posAt) : pos
        return dur > 0 ? min(dur, max(0, p)) : max(0, p)
    }

    /// Jump to a point in the song (scrubber).
    func seek(_ t: Double) {
        let t = dur > 0 ? min(max(0, t), dur) : max(0, t)
        pos = t; posAt = Date()
        if src == "Safari" { safariCtl("seek:" + String(format: "%.2f", t)); return }
        if isRunning(src == "Spotify" ? "com.spotify.client" : "com.apple.Music") {
            osa("tell application \"\(src)\" to set player position to \(String(format: "%.2f", t))")
        }
    }

    func ctl(_ cmd: String) {
        if src == "Safari" { safariCtl(cmd); return }
        if isRunning(src == "Spotify" ? "com.spotify.client" : "com.apple.Music") { osa("tell application \"\(src)\" to \(cmd)") }
        pollMusic()
    }
}

func loadURLs(_ ps: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    var out: [URL] = []; let g = DispatchGroup(); let lock = NSLock()
    for p in ps {
        g.enter()
        p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { lock.lock(); out.append(u); lock.unlock() }
            g.leave()
        }
    }
    g.notify(queue: .main) { done(out) }
}

func btn(_ n: String, _ f: @escaping () -> Void) -> some View {
    Button(action: f) { Image(systemName: n).font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(PressStyle())
}

/// The notch body: square top (it hangs from the screen edge), round bottom corners drawn as true circular arcs.
/// `inset` pulls every edge in evenly, so a stroke of width 2 * inset sits exactly inside the fill with the same thickness all round.
struct NotchShape: Shape {
    var r: CGFloat
    var inset: CGFloat = 0
    var animatableData: CGFloat { get { r } set { r = newValue } }
    func path(in rect: CGRect) -> Path {
        let rc = rect.insetBy(dx: inset, dy: inset)
        let rr = max(0, min(r - inset, min(rc.width, rc.height) / 2))
        let k = rr * 0.4477                    // circular-arc handle length for a cubic curve
        var p = Path()
        p.move(to: CGPoint(x: rc.minX, y: rc.minY))
        p.addLine(to: CGPoint(x: rc.maxX, y: rc.minY))
        p.addLine(to: CGPoint(x: rc.maxX, y: rc.maxY - rr))
        p.addCurve(to: CGPoint(x: rc.maxX - rr, y: rc.maxY),
                   control1: CGPoint(x: rc.maxX, y: rc.maxY - k), control2: CGPoint(x: rc.maxX - k, y: rc.maxY))
        p.addLine(to: CGPoint(x: rc.minX + rr, y: rc.maxY))
        p.addCurve(to: CGPoint(x: rc.minX, y: rc.maxY - rr),
                   control1: CGPoint(x: rc.minX + k, y: rc.maxY), control2: CGPoint(x: rc.minX, y: rc.maxY - k))
        p.closeSubpath()
        return p
    }
}

/// Open outline of the notch (left side, bottom, right side) with no line along the top screen edge.
/// Uses exactly the same arcs as NotchShape, so the line is the same thickness everywhere, corners included.
struct NotchOutline: Shape {
    var r: CGFloat
    var inset: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(r, inset) }
        set { r = newValue.first; inset = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let rc = rect.insetBy(dx: inset, dy: inset)
        let rr = max(0, min(r - inset, min(rc.width, rc.height) / 2))
        let k = rr * 0.4477
        var p = Path()
        p.move(to: CGPoint(x: rc.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rc.minX, y: rc.maxY - rr))
        p.addCurve(to: CGPoint(x: rc.minX + rr, y: rc.maxY),
                   control1: CGPoint(x: rc.minX, y: rc.maxY - k), control2: CGPoint(x: rc.minX + k, y: rc.maxY))
        p.addLine(to: CGPoint(x: rc.maxX - rr, y: rc.maxY))
        p.addCurve(to: CGPoint(x: rc.maxX, y: rc.maxY - rr),
                   control1: CGPoint(x: rc.maxX - k, y: rc.maxY), control2: CGPoint(x: rc.maxX, y: rc.maxY - k))
        p.addLine(to: CGPoint(x: rc.maxX, y: rect.minY))
        return p
    }
}

/// Which tab icon the pointer is over (for the little hover pop).
final class HoverTracker: ObservableObject { @Published var tab: Int? = nil }

/// Press feedback for every round button: a quick squash and a springy release.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Bars: View {
    @AppStorage("accent") var accent = "green"
    var on: Bool
    var body: some View {
        TimelineView(.animation) { ctx in
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    Capsule().fill(presetColor(accent)).frame(width: 4, height: on ? 5 + 18 * abs(sin(ctx.date.timeIntervalSinceReferenceDate * 5 + Double(i) * 0.8)) : 4)
                }
            }.frame(height: 24)
        }
    }
}

// Holds the clipboard search text. (@State is an Xcode-only macro in the newest SDKs, so Command Line Tools builds can't use it.)
final class ClipUI: ObservableObject { @Published var query = "" }

struct RootView: View {
    @EnvironmentObject var s: Store
    @AppStorage("dateColor") var dateColor = "white"
    @AppStorage("accent") var accent = "green"
    @AppStorage("fontDesign") var fd = "default"
    @AppStorage("corner") var corner = 24.0
    @AppStorage("pillExtra") var pillExtra = 92.0
    @AppStorage("outline") var outline = "white"
    @AppStorage("outlineWidth") var outlineWidth = 1.5
    @AppStorage("glassBody") var glassBody = false
    @AppStorage("artColors") var artColors = false
    @AppStorage("fluid") var fluid = true
    @AppStorage("outlineTop") var outlineTop = true
    @ObservedObject var bass = BassBoost.shared
    @StateObject var hover = HoverTracker()
    @StateObject var tabFrames = TabFrames()
    @ObservedObject var live = liveModel
    @ObservedObject var pillModel = LivePillModel.shared
    @ObservedObject var upd = Updater.shared
    @ObservedObject var prefs = TabPrefs.shared
    @StateObject var clipUI = ClipUI()
    @ObservedObject var clipImgs = ClipImages.shared
    var clipQuery: String { get { clipUI.query } nonmutating set { clipUI.query = newValue } }
    let icons = tabIcons

    /// Left-to-right order of the visible tab icons (indices into `icons`), as set in Customise tabs.
    var tabOrder: [Int] { prefs.visible() }

    /// If the current tab was hidden, jump to the first one that is still shown.
    func fixTab() { if !tabOrder.contains(s.tab), let f = tabOrder.first { s.tab = f } }

    /// Colour used for the selected tab and the outline; follows the album cover when that is switched on.
    var tintColor: Color { (artColors && s.playing) ? (s.artColor ?? presetColor(accent)) : presetColor(accent) }
    var outlineColor: Color { (artColors && s.playing && s.artColor != nil) ? tintColor : presetColor(outline) }

    var body: some View { GeometryReader { g in layered(g.size) } }

    /// The window is a fixed size; only the black shape inside it grows and shrinks (a cheap animation).
    /// The tab contents are always laid out at their final size and revealed through a mask the same shape as the
    /// notch, so everything appears to grow out of the notch instead of popping in.
    @ViewBuilder func layered(_ win: CGSize) -> some View {
        let aw: CGFloat = s.wob ? win.width : (s.expanded ? min(s.tw, win.width) : min(s.cw, win.width))
        let ah: CGFloat = s.wob ? win.height : (s.expanded ? min(s.th, win.height) : min(s.ch, win.height))
        let rad: CGFloat = s.expanded ? CGFloat(corner) : 10
        let sp: Animation? = s.wob ? nil : (fluid ? Animation.spring(response: 0.42, dampingFraction: 0.82) : Animation.easeOut(duration: 0.2))
        let lw = CGFloat(outlineWidth)
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if glassBody && s.expanded {
                    NotchShape(r: rad).fill(Color.black.opacity(0.55))
                        .glassSurface(NotchShape(r: rad))
                } else {
                    NotchShape(r: rad).fill(Color.black)
                }
                ambientGlow(rad)
                if outline != "none" { outlineShape(rad, lw) }
                if !s.expanded && pillModel.show { pill }
            }
            .frame(width: aw, height: ah)
            .animation(sp, value: aw)
            .animation(sp, value: ah)
            if s.mounted {
                expandedBody
                    .frame(width: min(s.tw, win.width), height: min(s.th, win.height), alignment: .top)
                    .scaleEffect(s.showContent ? 1 : 0.92, anchor: .top)
                    .opacity(s.showContent ? 1 : 0)
                    .animation(s.showContent ? Animation.spring(response: 0.46, dampingFraction: 0.84).delay(0.05) : Animation.easeIn(duration: 0.12), value: s.showContent)
                    .mask(alignment: .top) {
                        NotchShape(r: rad)
                            .frame(width: aw, height: ah)
                            .animation(sp, value: aw)
                            .animation(sp, value: ah)
                    }
                    .allowsHitTesting(s.showContent)
            }
        }.frame(width: win.width, height: win.height, alignment: .top)
        .foregroundColor(.white).preferredColorScheme(.dark).tint(presetColor(accent)).fontDesign(fontDesignValue(fd))
        .onAppear { fixTab() }
        .onChange(of: prefs.hidden) { _ in fixTab() }
    }

    /// The outline: a closed loop that runs over the top (the notch itself) too, or an open one without the top line.
    /// Both use the notch's own arcs, so the thickness is even all the way round.
    @ViewBuilder func outlineShape(_ rad: CGFloat, _ lw: CGFloat) -> some View {
        if outlineTop {
            NotchShape(r: rad + lw / 2, inset: -lw / 2)
                .stroke(outlineColor, style: StrokeStyle(lineWidth: lw, lineJoin: .miter))
                .allowsHitTesting(false)
        } else {
            NotchOutline(r: rad + lw / 2, inset: -lw / 2)
                .stroke(outlineColor, style: StrokeStyle(lineWidth: lw, lineCap: .butt, lineJoin: .round))
                .allowsHitTesting(false)
        }
    }

    /// A soft wash of the album colour inside the open notch while music plays.
    @ViewBuilder func ambientGlow(_ rad: CGFloat) -> some View {
        let on = s.expanded && s.tab == 0 && s.playing && !prefs.editing
        let c = s.artColor ?? presetColor(accent)
        RadialGradient(colors: [c.opacity(0.30), c.opacity(0.0)], center: UnitPoint(x: 0.14, y: 0.62), startRadius: 0, endRadius: 380)
            .clipShape(NotchShape(r: rad))
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: on)
            .allowsHitTesting(false)
    }

    /// Everything inside the open notch: the tab strip and the current tab.
    @ViewBuilder var expandedBody: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(tabOrder, id: \.self) { i in
                    Button {
                        if s.tab != i { tapHaptic() }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { s.tab = i; prefs.editing = false }
                    } label: {
                        Image(systemName: icons[i]).frame(minWidth: 20, maxWidth: 32).frame(height: 24)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TabFrameKey.self, value: [i: g.frame(in: .named("tabbar"))])
                            })
                            .contentShape(Capsule())
                            .overlay(alignment: .topTrailing) {
                                if i == updaterTab && upd.badge { Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -2, y: 1) }
                            }
                            .scaleEffect(hover.tab == i && s.tab != i ? 1.16 : 1)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover.tab)
                    }
                    .buttonStyle(PressStyle())
                    .onHover { h in if h { hover.tab = i } else if hover.tab == i { hover.tab = nil } }
                }
                Spacer()
                if s.battery >= 0 {
                    HStack(spacing: 4) {
                        BatteryIcon(level: s.battery, charging: s.charging, lowPower: s.lowPower)
                        Text("\(s.battery)%").font(.caption).lineLimit(1)
                            .contentTransition(.numericText())
                            .foregroundColor(batteryTint(s.battery, s.charging, s.lowPower) == .white ? .white : batteryTint(s.battery, s.charging, s.lowPower))
                    }.fixedSize().layoutPriority(1)
                }
            }
            .coordinateSpace(name: "tabbar")
            .background(alignment: .topLeading) { tabHighlight }
            .onPreferenceChange(TabFrameKey.self) { v in DispatchQueue.main.async { if tabFrames.f != v { tabFrames.f = v } } }
            .frame(maxWidth: 640)
            .contextMenu { Button("Customise tabs...") { prefs.editing = true } }
            Group {
                if prefs.editing { TabsEditor() } else {
                switch s.tab {
                case 0: music
                case 1: shelf
                case 2: clipboard
                case 3: timers
                case 4: tools
                case 6: BrowserView()
                case 7: CameraTab()
                case 8: CalendarView()
                case 9: SysView()
                case 10: ControlCentreView()
                case aiTab: AIView()
                case quickTab: QuickActionsView()
                case dictateTab: DictateView()
                case todoTab: TodoView()
                case termTab: TerminalView()
                case prompterTab: PrompterView()
                case 11: SettingsView()
                case weatherTab: WeatherView()
                case updaterTab: UpdaterView()
                default: AppsView()
                }
                }
            }
            .id(prefs.editing ? -1 : s.tab)
            .transition(.asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(x: 0, y: 8)), removal: .identity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(.top, 38).padding(.horizontal, 20).padding(.bottom, 12)
        .overlay(alignment: .bottom) { toastView }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: s.toast)
    }

    /// The coloured capsule behind the selected tab. One view that glides from tab to tab.
    @ViewBuilder var tabHighlight: some View {
        if let r = tabFrames.f[s.tab] {
            Color.clear.frame(width: r.width, height: r.height)
                .modifier(GlassIf(shape: Capsule(), tint: tintColor.opacity(0.6), interactive: false, classic: tintColor.opacity(0.35)))
                .offset(x: r.minX, y: r.minY)
                .animation(.spring(response: 0.38, dampingFraction: 0.78), value: s.tab)
        }
    }

    // MARK: Music tab

    /// Album cover with a glow in the cover's own colour. It settles back a little when the music is paused.
    func artView(_ size: CGFloat) -> some View {
        ZStack {
            if let a = s.art { Image(nsImage: a).resizable().scaledToFill().transition(.opacity) }
            else { Color.white.opacity(0.1).overlay(Image(systemName: "music.note").font(.largeTitle)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 12 : 9, style: .continuous))
        .shadow(color: (s.artColor ?? Color.black).opacity(s.playing && s.art != nil ? 0.5 : 0), radius: 14, x: 0, y: 6)
        .scaleEffect(s.playing ? 1 : 0.94)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: s.playing)
        .animation(.easeInOut(duration: 0.35), value: s.track)
    }

    func extraToggle(_ icon: String, on: Bool, help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(on ? presetColor(accent) : Color.white.opacity(0.55))
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? presetColor(accent).opacity(0.2) : Color.white.opacity(0.08)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.2), value: on)
        }.buttonStyle(PressStyle()).help(help)
    }

    var playButton: some View {
        Button { s.ctl("playpause") } label: {
            Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34).contentShape(Circle())
                .modifier(GlassIf(shape: Circle(), tint: nil, interactive: true, classic: Color.white.opacity(0.14)))
        }.buttonStyle(PressStyle())
    }

    func musicControls(bars: Bool) -> some View {
        HStack(spacing: 10) {
            btn("backward.fill") { s.ctl("previous track") }
            playButton
            btn("forward.fill") { s.ctl("next track") }
            Spacer(minLength: 4)
            extraToggle("text.quote", on: s.lyricsOpen, help: "Full lyrics") {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { s.lyricsOpen.toggle() }
            }
            extraToggle("speaker.wave.3.fill", on: bass.on, help: "Bass booster (strength in Settings)") {
                bass.toggle()
                s.say(bass.on ? "Bass booster on" : "Bass booster off")
            }
            if bars { Bars(on: s.playing) }
        }
    }

    var music: some View {
        Group { if s.lyricsOpen { musicLyrics } else { musicMain } }
            .transition(.opacity)
    }

    var musicMain: some View {
        HStack(spacing: 14) {
            artView(96)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.track).font(.headline).lineLimit(1).id("t" + s.track)
                    .transition(.asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(x: 0, y: 6)), removal: .opacity))
                Text(s.artist).font(.subheadline).foregroundColor(.gray).lineLimit(1).id("a" + s.track + s.artist)
                    .transition(.asymmetric(insertion: AnyTransition.opacity.combined(with: .offset(x: 0, y: 6)), removal: .opacity))
                LyricsLine()
                musicControls(bars: true)
                Scrubber()
            }.frame(minWidth: 250, maxWidth: 340, alignment: .leading)
            .animation(.easeOut(duration: 0.28), value: s.track)
            Spacer()
            VStack(alignment: .trailing) {
                Text(s.now, format: .dateTime.hour().minute()).font(.system(size: 36, weight: .light)).foregroundColor(presetColor(dateColor))
                    .contentTransition(.numericText()).contextMenu { colorMenu }
                Text(s.now, format: .dateTime.weekday(.wide).day().month()).font(.caption).foregroundColor(presetColor(dateColor).opacity(0.75)).contextMenu { colorMenu }
            }
        }
    }

    /// The music tab with the full lyrics open: the song on the left, every line sung so far on the right.
    var musicLyrics: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    artView(64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.track).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(s.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                musicControls(bars: false)
                Scrubber()
            }.frame(width: 250).frame(maxHeight: .infinity)
            LyricsPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var shelf: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
                if s.files.isEmpty { Text("Drop files here").foregroundColor(.gray) }
                else {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(s.files, id: \.self) { u in
                                VStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 44, height: 44)
                                    Text(u.lastPathComponent).font(.caption2).lineLimit(1)
                                }.frame(width: 70)
                                .onDrag { NSItemProvider(contentsOf: u) ?? NSItemProvider() }
                                .contextMenu { shelfMenu(u) }
                            }
                        }.padding(8)
                    }
                }
            }.onDrop(of: [UTType.fileURL], isTargeted: nil) { ps in
                loadURLs(ps) { us in for u in us where !s.files.contains(u) { s.files.append(u) } }; return true
            }
            shelfTools
            airdropTile
        }
    }

    var shownPinned: [String] { s.pinned.filter { clipQuery.isEmpty || $0.localizedCaseInsensitiveContains(clipQuery) } }
    var shownClips: [String] { s.clips.filter { clipQuery.isEmpty || $0.localizedCaseInsensitiveContains(clipQuery) } }

    func clipRow(_ c: String, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
                s.lastPB = NSPasteboard.general.changeCount
            } label: {
                Text(c.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                if pinned { s.pinned.removeAll { $0 == c }; if !s.clips.contains(c) { s.clips.insert(c, at: 0) } }
                else { s.clips.removeAll { $0 == c }; s.pinned.insert(c, at: 0) }
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 11))
                    .foregroundColor(pinned ? presetColor(accent) : Color.gray).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(pinned ? presetColor(accent).opacity(0.14) : Color.white.opacity(0.08)).cornerRadius(7)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") {
                if pinned { s.pinned.removeAll { $0 == c } } else { s.clips.removeAll { $0 == c }; s.pinned.insert(c, at: 0) }
            }
            Button("Delete") { s.pinned.removeAll { $0 == c }; s.clips.removeAll { $0 == c } }
        }
    }

    var clipboard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.gray).font(.system(size: 11))
                TextField("Search clipboard", text: $clipUI.query).textFieldStyle(.plain).font(.system(size: 12))
                if !clipQuery.isEmpty {
                    Button { clipQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { s.clips.removeAll(); ClipImages.shared.clear() } label: {
                    Text("Clear history").font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.1)).clipShape(Capsule())
                }.buttonStyle(.plain).disabled(s.clips.isEmpty && clipImgs.items.isEmpty).opacity(s.clips.isEmpty && clipImgs.items.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .panelCard(9, classic: Color.white.opacity(0.08))
            if !clipImgs.items.isEmpty && clipQuery.isEmpty { ClipImageStrip() }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if s.clips.isEmpty && s.pinned.isEmpty { Text("Copy something... pin the ones you want to keep").foregroundColor(.gray).font(.system(size: 12)) }
                    else if shownPinned.isEmpty && shownClips.isEmpty { Text("Nothing matches").foregroundColor(.gray).font(.system(size: 12)) }
                    ForEach(shownPinned, id: \.self) { clipRow($0, pinned: true) }
                    ForEach(shownClips, id: \.self) { clipRow($0, pinned: false) }
                }
            }
        }
    }

    func smallBtn(_ n: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: n).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func lengthPill(_ title: String, _ v: Int, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.gray).padding(.leading, 6)
            smallBtn("minus", dec)
            Text("\(v)m").font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 30)
            smallBtn("plus", inc)
        }.padding(.horizontal, 2).background(Color.white.opacity(0.1)).clipShape(Capsule())
    }

    var timers: some View {
        HStack(spacing: 40) {
            VStack(spacing: 6) {
                Text(s.onBreak ? "Break" : "Focus").font(.caption).foregroundColor(.gray)
                Text(mmss(s.remaining)).font(.system(size: 40, weight: .light, design: .monospaced))
                    .contentTransition(.numericText()).animation(.easeInOut(duration: 0.25), value: s.remaining)
                HStack {
                    btn(s.running ? "pause.fill" : "play.fill") { s.running.toggle() }
                    btn("arrow.counterclockwise") { s.running = false; s.onBreak = false; s.remaining = s.focusMins * 60 }
                }
                HStack(spacing: 8) {
                    lengthPill("Focus", s.focusMins,
                               dec: { s.setFocus(s.stepMins(s.focusMins, up: false, maxV: 180)) },
                               inc: { s.setFocus(s.stepMins(s.focusMins, up: true, maxV: 180)) })
                    lengthPill("Break", s.breakMins,
                               dec: { s.setBreak(s.stepMins(s.breakMins, up: false, maxV: 60)) },
                               inc: { s.setBreak(s.stepMins(s.breakMins, up: true, maxV: 60)) })
                }
            }
            VStack {
                Text("Stopwatch").font(.caption).foregroundColor(.gray)
                Text(mmss(s.sw)).font(.system(size: 40, weight: .light, design: .monospaced))
                HStack {
                    btn(s.swRunning ? "pause.fill" : "play.fill") { s.swRunning.toggle() }
                    btn("arrow.counterclockwise") { s.swRunning = false; s.sw = 0 }
                }
            }
        }
    }

    var tools: some View {
        HStack(spacing: 10) {
            NotesPane().frame(maxWidth: .infinity)
            CounterCard(id: "water", label: "Water", unit: "glasses", step: 1, goal: 8, color: "cyan", daily: true, negative: false, value: $s.water)
            CounterCard(id: "counter", label: "Counter", unit: "", step: 1, goal: 0, color: "orange", daily: false, negative: true, value: $s.counter)
            DaysCard()
        }
    }
}

/// Draggable song-position bar with elapsed / remaining time.
final class ScrubState: ObservableObject {
    @Published var drag: Double? = nil
    @Published var hover = false
}
struct Scrubber: View {
    @EnvironmentObject var s: Store
    @AppStorage("accent") var accent = "green"
    @StateObject var st = ScrubState()

    func clock(_ t: Double) -> String { let n = Int(max(0, t)); return String(format: "%d:%02d", n / 60, n % 60) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let dur = s.dur
            let shown = st.drag ?? s.curPos()
            let frac = dur > 0 ? min(1, max(0, shown / dur)) : 0
            let active = st.hover || st.drag != nil
            HStack(spacing: 8) {
                Text(clock(shown)).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).frame(width: 32, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(height: active ? 6 : 4)
                        Capsule().fill(presetColor(accent)).frame(width: max(0, g.size.width * CGFloat(frac)), height: active ? 6 : 4)
                        Circle().fill(Color.white).frame(width: 12, height: 12)
                            .offset(x: g.size.width * CGFloat(frac) - 6).opacity(active ? 1 : 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard dur > 0, g.size.width > 0 else { return }
                            st.drag = Double(min(1, max(0, v.location.x / g.size.width))) * dur
                        }
                        .onEnded { v in
                            if dur > 0, g.size.width > 0 { s.seek(Double(min(1, max(0, v.location.x / g.size.width))) * dur) }
                            st.drag = nil
                        })
                    .onHover { st.hover = $0 }
                }.frame(height: 18)
                Text("-" + clock(dur - shown)).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).frame(width: 38, alignment: .leading)
            }.opacity(dur > 0 ? 1 : 0.35)
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The app has no menu bar, so Cmd+V / C / X / A / Z would do nothing. Route them to whatever has focus.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: e) { return true }
        guard e.type == .keyDown else { return false }
        if e.keyCode == 53, Store.shared.forceOpen { Store.shared.forceOpen = false; return true }   // Esc closes a hotkey-opened notch
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
        var sel: String?
        switch k {
        case "v": sel = "paste:"
        case "c": sel = "copy:"
        case "x": sel = "cut:"
        case "a": sel = "selectAll:"
        case "z": sel = mods.contains(.shift) ? "redo:" : "undo:"
        default: break
        }
        guard let name = sel, (mods == .command || k == "z") else { return false }
        return firstResponder?.tryToPerform(Selector((name)), with: nil) ?? false
    }
}

/// Puts the notch window into its own always-visible layer that belongs to no desktop, so it is simply there on every
/// desktop and full-screen app (nothing spawns in, nothing freezes when you switch). Uses macOS's window server calls,
/// looked up at run time: if they ever go missing the app still works with the normal all-desktops behaviour.
enum AllSpaces {
    private static var space = 0
    private typealias Conn = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, UnsafeRawPointer?, CFDictionary?) -> Int
    private typealias Level = @convention(c) (Int32, Int, Int32) -> Void
    private typealias AddWin = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias Show = @convention(c) (Int32, CFArray) -> Void

    static func pin(_ w: NSWindow) {
        guard w.windowNumber > 0,
              let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "CGSMainConnectionID"), let cr = dlsym(h, "CGSSpaceCreate"),
              let lv = dlsym(h, "CGSSpaceSetAbsoluteLevel"), let ad = dlsym(h, "CGSAddWindowsToSpaces"),
              let sh = dlsym(h, "CGSShowSpaces") else { return }
        let conn = unsafeBitCast(c, to: Conn.self)()
        if space == 0 {
            space = unsafeBitCast(cr, to: Create.self)(conn, UnsafeRawPointer(bitPattern: 1), nil)
            guard space != 0 else { return }
            unsafeBitCast(lv, to: Level.self)(conn, space, 2147483647)
        }
        unsafeBitCast(ad, to: AddWin.self)(conn, [w.windowNumber] as CFArray, [space] as CFArray)
        unsafeBitCast(sh, to: Show.self)(conn, [space] as CFArray)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let notchLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)   // above full-screen apps and every window
    var panel: NotchPanel!
    var item: NSStatusItem!
    let s = Store.shared
    var wobbling = false
    var tickN = 0
    var shrinkSince: Date?
    var unmountWork: DispatchWorkItem?

    var padUntil = Date.distantPast
    /// Transparent breathing room round the shape while it is open or still settling, so a spring overshoot is never cut off.
    func pad() -> CGFloat { (s.expanded || Date() < padUntil) ? 36 : basePad() }
    /// Even when closed the window is a few points bigger than the shape, so the outline can sit just outside it and hug it.
    func basePad() -> CGFloat {
        let d = UserDefaults.standard
        if (d.string(forKey: "outline") ?? "white") == "none" { return 0 }
        return CGFloat((d.object(forKey: "outlineWidth") as? Double) ?? 1.5) + 3
    }
    func windowRect(_ t: NSRect) -> NSRect {
        let p = pad()
        return NSRect(x: t.minX - p, y: t.minY - p, width: t.width + 2 * p, height: t.height + p)
    }

    /// The window only ever jumps (never animates, which was the lag). It grows straight away so the shape has room
    /// to open, and shrinks a moment after the shape has finished closing. The visible animation is all in SwiftUI.
    func syncFrame(_ rawTarget: NSRect) {
        let target = windowRect(rawTarget)
        let f = panel.frame
        let w = max(f.width, target.width), h = max(f.height, target.height)
        if abs(w - f.width) > 1 || abs(h - f.height) > 1 || abs(f.midX - target.midX) > 1 || abs(f.maxY - target.maxY) > 1 {
            panel.setFrame(NSRect(x: target.midX - w / 2, y: target.maxY - h, width: w, height: h), display: true)
        }
        if abs(w - target.width) > 1 || abs(h - target.height) > 1 {
            if let t = shrinkSince {
                if Date().timeIntervalSince(t) > 0.8 { panel.setFrame(target, display: true); shrinkSince = nil }
            } else { shrinkSince = Date() }
        } else { shrinkSince = nil }
    }

    func geometry(_ expanded: Bool) -> NSRect {
        let pick = UserDefaults.standard.string(forKey: "notchScreen") ?? "auto"
        let chosen = pick == "auto" ? nil : NSScreen.screens.first { $0.localizedName == pick }
        let scr = chosen ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var nw: CGFloat = 200, nh: CGFloat = 32
        if scr.safeAreaInsets.top > 0, let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea {
            nw = r.minX - l.maxX; nh = scr.safeAreaInsets.top
        }
        let extra = CGFloat((UserDefaults.standard.object(forKey: "pillExtra") as? Double) ?? 92)
        var ew: CGFloat = 680, eh: CGFloat = 220
        switch s.tab {
        case 0: if s.lyricsOpen { eh = 330 }   // music with the full lyrics open
        case 3: eh = 230            // timers (focus / break length pills)
        case 5: if AppsModel.shared.openKey != nil { ew = 820; eh = 460 }   // an app running inside the notch
        case 4: ew = 820; eh = 250   // notes + water + counter + days (customise panel needs room)
        case 6, 7, aiTab: ew = 820; eh = 460   // browser, camera and AI share one big size
        case 10: eh = 340           // control centre
        case 2: eh = ClipImages.shared.items.isEmpty ? 250 : 296   // clipboard (search + pinned, plus the image strip)
        case 11: eh = 310           // settings (scrolls)
        case weatherTab: eh = 290   // weather
        case quickTab: eh = 250     // shortcuts + quick actions
        case dictateTab: eh = 250   // dictation
        case todoTab: eh = 290      // to-do + focus stats
        case termTab: ew = 820; eh = 330
        case prompterTab: ew = 820; eh = 340
        case updaterTab: eh = 300   // updates list
        default: break
        }
        if TabPrefs.shared.editing { ew = 680; eh = 340 }   // Customise tabs screen
        let w: CGFloat = expanded ? min(ew, scr.frame.width - 24) : nw + (s.hasLive ? extra : 0), h: CGFloat = expanded ? eh : nh
        return NSRect(x: scr.frame.midX - w / 2, y: scr.frame.maxY - h, width: w, height: h)
    }


    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: windowRect(geometry(false)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = AppDelegate.notchLevel
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isMovable = false; panel.worksWhenModal = true
        // Stay put on every desktop, over full-screen apps, and whichever app or window is in front.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        panel.isFloatingPanel = true
        panel.canHide = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RootView().environmentObject(s))
        panel.orderFrontRegardless()
        AllSpaces.pin(panel)
        s.start(); liveModel.start(); AlertCenter.shared.start(); Updater.shared.start(); BassBoost.shared.restore()
        // keep the notch (and its live pill) in place when you swipe between desktops, wake the Mac or change displays
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.reassert() }
        wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.reassert() }
        wsc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reassert() }
        wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reassert() }
        // switching to another app or window must never knock the notch off the screen
        wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.keepOnTop() }
        wsc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.keepOnTop() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reassert() }
        // always on screen, on every desktop and over full-screen apps, live from the moment you arrive (no waiting for focus)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in self?.keepOnTop() }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.keepOnTop() }
        let tick = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(tick, forMode: .common)   // keeps running while menus are open or the Mac is switching desktops
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in IdleSweeper.run() }
        s.onTimerDone = { [weak self] in self?.wobble() }

        // global hotkeys (Control + Option + key; customise them in Settings)
        Hotkeys.shared.onFire = { [weak self] a in self?.hotkey(a) }
        Hotkeys.shared.apply()
        // clicking anywhere else puts a hotkey-opened notch away again
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.s.forceOpen else { return }
            if !self.geometry(true).insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation) { self.s.forceOpen = false }
        }

        // A minimal Edit menu: without one, Cut / Copy / Paste do nothing in pop-up text boxes.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); appMenuItem.submenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        let editMenuItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = edit
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NOTCH")
        let m = NSMenu()
        let a = m.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: ""); a.target = self
        let c = m.addItem(withTitle: "Click to Expand (instead of hover)", action: #selector(toggleClick(_:)), keyEquivalent: ""); c.target = self
        c.state = UserDefaults.standard.bool(forKey: "clickMode") ? .on : .off
        let hk = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
        let hm = NSMenu(title: "Hotkeys")
        hm.delegate = self                 // rebuilt every time it opens, so it always shows your current keys
        hk.submenu = hm
        m.addItem(hk)
        m.addItem(withTitle: "Quit NOTCH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    /// Jelly wobble of the notch (timer finished). It squishes and bounces, then settles. No expanding.
    func wobble() {
        guard !wobbling else { return }
        wobbling = true
        s.wob = true
        let base = geometry(s.expanded)
        let big: CGFloat = s.expanded ? 0.45 : 1
        let start = Date()
        let dur = 1.7, freq = 3.2
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let e = Date().timeIntervalSince(start)
            if e >= dur {
                tm.invalidate(); self.wobbling = false; self.s.wob = false
                self.panel.setFrame(self.windowRect(self.geometry(self.s.expanded)), display: true)
                return
            }
            let decay = CGFloat(exp(-2.4 * e)), ph = CGFloat(2 * Double.pi * freq * e)
            let w = base.width + 34 * big * decay * sin(ph)
            let h = base.height + 20 * big * decay * (0.5 - 0.5 * cos(ph * 0.98 + 0.6))
            self.panel.setFrame(NSRect(x: base.midX - w / 2, y: base.maxY - h, width: w, height: h), display: true)
        }
        RunLoop.main.add(t, forMode: .common)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    /// What each hotkey does.
    func hotkey(_ a: HKAction) {
        switch a {
        case .notch: s.forceOpen.toggle()
        case .ai: openTab(aiTab)
        case .clipboard: openTab(2)
        }
    }

    func openTab(_ t: Int) {
        if s.expanded && s.forceOpen && s.tab == t && !TabPrefs.shared.editing { s.forceOpen = false; return }   // second press puts it away
        TabPrefs.shared.editing = false
        s.tab = t
        s.forceOpen = true
        if t == aiTab { AIModel.shared.focusChat() }
    }

    @objc func openSettingsTab() {
        TabPrefs.shared.editing = false
        s.tab = 11
        s.forceOpen = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Hotkeys" else { return }
        menu.removeAllItems()
        for a in HKAction.allCases {
            let i = menu.addItem(withTitle: "\(a.title):  \(HK.text(Hotkeys.shared.combo(a)))", action: nil, keyEquivalent: "")
            i.isEnabled = false
        }
        menu.addItem(NSMenuItem.separator())
        let c = menu.addItem(withTitle: "Change in Settings...", action: #selector(openSettingsTab), keyEquivalent: "")
        c.target = self
    }

    func check() {
        LivePillModel.shared.refresh(s, liveModel)
        tickN += 1
        if tickN % 6 == 0, !panel.isVisible || !panel.isOnActiveSpace || !panel.occlusionState.contains(.visible) { keepOnTop() }
        if wobbling { return }
        let ge = geometry(true), gc = geometry(false)
        if s.tw != ge.width { s.tw = ge.width }
        if s.th != ge.height { s.th = ge.height }
        if s.cw != gc.width { s.cw = gc.width }
        if s.ch != gc.height { s.ch = gc.height }
        let target = s.expanded ? ge : gc
        syncFrame(target)
        // Judge the mouse against where the notch is going, not the window mid-animation, so it can never fight itself.
        let near = target.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
        let inside = ((UserDefaults.standard.bool(forKey: "clickMode") && !s.expanded) ? (near && NSEvent.pressedMouseButtons & 1 != 0) : near) || s.forceOpen
        if inside != s.expanded {
            let fluid = UserDefaults.standard.bool(forKey: "fluid")
            unmountWork?.cancel()
            if inside { s.mounted = true }        // the contents exist before the shape starts to grow
            withAnimation(fluid ? .spring(response: 0.42, dampingFraction: 0.82) : .easeOut(duration: 0.2)) { s.expanded = inside }
            syncFrame(inside ? ge : gc)
            if inside {
                tapHaptic()
                panel.makeKey()
                // the contents bloom in as the shape grows out of the notch
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.s.expanded else { return }
                    self.s.showContent = true
                }
            } else {
                padUntil = Date().addingTimeInterval(1.2)
                s.showContent = false
                DictationModel.shared.stop()        // the mic never stays on after the notch is put away
                browserModel.reset()                // search browser starts fresh next time
                // take the contents away once the shape has finished closing
                let w = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.s.expanded else { return }
                    self.s.mounted = false
                }
                unmountWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
            }
        }
    }

    /// Makes sure the notch is still on screen and in front (it is, unless macOS moved it). Cheap, safe to call often.
    func keepOnTop() {
        AllSpaces.pin(panel)
        if panel.level != AppDelegate.notchLevel { panel.level = AppDelegate.notchLevel }
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ n: Notification) {
        BassBoost.shared.shutdown()
        DictationModel.shared.forceOff()
    }

    /// Puts the panel back at the notch and on top. Run right away and again once a desktop swipe has settled.
    func reassert() {
        panel.setFrame(windowRect(geometry(s.expanded)), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.panel.setFrame(self.windowRect(self.geometry(self.s.expanded)), display: true)
            self.panel.orderFrontRegardless()
        }
    }

    @objc func toggleClick(_ i: NSMenuItem) {
        let v = !UserDefaults.standard.bool(forKey: "clickMode")
        UserDefaults.standard.set(v, forKey: "clickMode"); i.state = v ? .on : .off
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
