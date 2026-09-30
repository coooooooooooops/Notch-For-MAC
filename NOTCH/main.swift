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
    @Published var tab = 0
    @Published var files: [URL] = []
    @Published var clips: [String] = []
    @Published var track = "Nothing playing"
    @Published var artist = ""
    @Published var art: NSImage?
    @Published var playing = false
    @Published var now = Date()
    @Published var battery = 100
    @Published var remaining = 1500
    @Published var running = false
    @Published var onBreak = false
    @Published var sw = 0
    @Published var swRunning = false
    @Published var notes = "" { didSet { UserDefaults.standard.set(notes, forKey: "notes") } }
    @Published var water = 0 { didSet { UserDefaults.standard.set(water, forKey: "water") } }
    @Published var counter = 0 { didSet { UserDefaults.standard.set(counter, forKey: "counter") } }
    @Published var apps: [String] = [] { didSet { UserDefaults.standard.set(apps, forKey: "apps") } }
    var src = "Music"
    var lastPB = NSPasteboard.general.changeCount
    var n = 0
    var safW = 1, safT = 1, safBusy = false

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["waterDaily": true, "counterDaily": false, "pillExtra": 92.0])
        if d.string(forKey: "lastDay") == nil, let old = d.string(forKey: "waterDay") { d.set(old, forKey: "lastDay") }
        notes = d.string(forKey: "notes") ?? ""
        water = d.integer(forKey: "water")
        counter = d.integer(forKey: "counter")
        apps = d.stringArray(forKey: "apps") ?? []
        rollover()
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
        now = Date(); battery = Store.batteryLevel()
        let pb = NSPasteboard.general
        if pb.changeCount != lastPB {
            lastPB = pb.changeCount
            if let t = pb.string(forType: .string), !t.isEmpty {
                clips.removeAll { $0 == t }; clips.insert(t, at: 0); clips = Array(clips.prefix(20))
            }
        }
        if running {
            if remaining > 0 { remaining -= 1 } else { onBreak.toggle(); remaining = onBreak ? 300 : 1500; NSSound.beep() }
        }
        if swRunning { sw += 1 }
        n += 1
        if n % 30 == 0 { rollover() }
        if n % 2 == 0 { pollMusic() }
    }

    static func batteryLevel() -> Int {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let c = d[kIOPSCurrentCapacityKey] as? Int { return c }
        }
        return -1
    }

    func isRunning(_ id: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id } }

    func pollMusic() {
        let cands = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")].filter { isRunning($0.1) }
        var hit = false
        for (app, _) in cands {
            let script = "tell application \"\(app)\" to if player state is playing then return (name of current track) & \"\\n\" & (artist of current track)"
            guard let r = osa(script)?.stringValue else { continue }
            let p = r.components(separatedBy: "\n")
            hit = true; src = app; playing = true
            let title = p.first ?? ""
            if title != track {
                track = title; artist = p.count > 1 ? p[1] : ""; art = nil
                if app == "Spotify", let u = osa("tell application \"Spotify\" to return artwork url of current track")?.stringValue, let url = URL(string: u) {
                    DispatchQueue.global().async {
                        if let d = try? Data(contentsOf: url), let img = NSImage(data: d) { DispatchQueue.main.async { self.art = img } }
                    }
                } else if app == "Music", let d = osa("tell application \"Music\" to return data of artwork 1 of current track")?.data {
                    art = NSImage(data: d)
                }
            }
            break
        }
        if !hit { pollSafari() }
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
    Button(action: f) { Image(systemName: n).font(.system(size: 16)).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain)
}

struct NotchShape: Shape {
    var r: CGFloat
    var animatableData: CGFloat { get { r } set { r = newValue } }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - r), control: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
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

struct RootView: View {
    @EnvironmentObject var s: Store
    @AppStorage("dateColor") var dateColor = "white"
    @AppStorage("accent") var accent = "green"
    @AppStorage("fontDesign") var fd = "default"
    @AppStorage("corner") var corner = 24.0
    @AppStorage("pillExtra") var pillExtra = 92.0
    @ObservedObject var live = liveModel
    let icons = ["music.note", "tray.and.arrow.down", "doc.on.clipboard", "timer", "note.text", "square.grid.2x2", "globe", "camera", "calendar", "gauge.medium", "bolt.square", "paintpalette", "gamecontroller.fill"]

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(r: s.expanded ? CGFloat(corner) : 10).fill(Color.black)
            if !s.expanded && s.hasLive { pill }
            if s.expanded {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<icons.count, id: \.self) { i in
                            Button { s.tab = i } label: {
                                Image(systemName: icons[i]).frame(width: 32, height: 24)
                                    .background(s.tab == i ? presetColor(accent).opacity(0.35) : Color.clear).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Image(systemName: "battery.100"); Text("\(s.battery)%").font(.caption)
                    }.frame(maxWidth: 580)
                    Group {
                        switch s.tab {
                        case 0: music
                        case 1: shelf
                        case 2: clipboard
                        case 3: timers
                        case 4: tools
                        case 6: BrowserView()
                        case 7: CameraView().clipShape(RoundedRectangle(cornerRadius: 12))
                        case 8: CalendarView()
                        case 9: SysView()
                        case 10: ShortcutsView()
                        case 11: ThemeView()
                        case 12: SnakeView()
                        default: appsView
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.padding(.top, 38).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }.foregroundColor(.white).preferredColorScheme(.dark).tint(presetColor(accent)).fontDesign(fontDesignValue(fd))
    }

    var music: some View {
        HStack(spacing: 14) {
            Group {
                if let a = s.art { Image(nsImage: a).resizable().scaledToFill() }
                else { Color.white.opacity(0.1).overlay(Image(systemName: "music.note").font(.largeTitle)) }
            }.frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(s.track).font(.headline).lineLimit(1)
                Text(s.artist).font(.subheadline).foregroundColor(.gray).lineLimit(1)
                HStack(spacing: 14) {
                    btn("backward.fill") { s.ctl("previous track") }
                    btn(s.playing ? "pause.fill" : "play.fill") { s.ctl("playpause") }
                    btn("forward.fill") { s.ctl("next track") }
                }
                Bars(on: s.playing)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(s.now, format: .dateTime.hour().minute()).font(.system(size: 36, weight: .light)).foregroundColor(presetColor(dateColor)).contextMenu { colorMenu }
                Text(s.now, format: .dateTime.weekday(.wide).day().month()).font(.caption).foregroundColor(presetColor(dateColor).opacity(0.75)).contextMenu { colorMenu }
            }
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
                                .contextMenu { Button("Remove") { s.files.removeAll { $0 == u } } }
                            }
                        }.padding(8)
                    }
                }
            }.onDrop(of: [UTType.fileURL], isTargeted: nil) { ps in
                loadURLs(ps) { us in for u in us where !s.files.contains(u) { s.files.append(u) } }; return true
            }
            airdropTile
        }
    }

    var clipboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if s.clips.isEmpty { Text("Copy something...").foregroundColor(.gray) }
                ForEach(s.clips, id: \.self) { c in
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
                        s.lastPB = NSPasteboard.general.changeCount
                    } label: {
                        Text(c).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(Color.white.opacity(0.08)).cornerRadius(6)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    var timers: some View {
        HStack(spacing: 30) {
            VStack {
                Text(s.onBreak ? "Break" : "Focus").font(.caption).foregroundColor(.gray)
                Text(mmss(s.remaining)).font(.system(size: 40, weight: .light, design: .monospaced))
                HStack {
                    btn(s.running ? "pause.fill" : "play.fill") { s.running.toggle() }
                    btn("arrow.counterclockwise") { s.running = false; s.onBreak = false; s.remaining = 1500 }
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
            TextEditor(text: $s.notes).scrollContentBackground(.hidden).background(Color.white.opacity(0.08)).cornerRadius(10)
            CounterCard(id: "water", label: "Water", unit: "glasses", step: 1, goal: 8, color: "cyan", daily: true, negative: false, value: $s.water)
            CounterCard(id: "counter", label: "Counter", unit: "", step: 1, goal: 0, color: "orange", daily: false, negative: true, value: $s.counter)
        }
    }

    var appsView: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(s.apps, id: \.self) { p in
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } label: {
                        VStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 44, height: 44)
                            Text(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent).font(.caption2).lineLimit(1)
                        }.frame(width: 64)
                    }.buttonStyle(.plain).contextMenu { Button("Remove") { s.apps.removeAll { $0 == p } } }
                }
                btn("plus.circle") {
                    NSApp.activate(ignoringOtherApps: true)
                    let o = NSOpenPanel(); o.directoryURL = URL(fileURLWithPath: "/Applications"); o.allowedContentTypes = [.application]
                    if o.runModal() == .OK, let u = o.url { s.apps.append(u.path) }
                }
            }
        }
    }
}

final class NotchPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var item: NSStatusItem!
    let s = Store.shared

    func geometry(_ expanded: Bool) -> NSRect {
        let scr = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var nw: CGFloat = 200, nh: CGFloat = 32
        if scr.safeAreaInsets.top > 0, let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea {
            nw = r.minX - l.maxX; nh = scr.safeAreaInsets.top
        }
        let extra = CGFloat((UserDefaults.standard.object(forKey: "pillExtra") as? Double) ?? 92)
        var ew: CGFloat = 620, eh: CGFloat = 220
        switch s.tab {
        case 4: eh = 250            // notes + water + counter (customise panel needs room)
        case 6: ew = 820; eh = 460  // browser
        case 11: eh = 250           // themes
        case gameTab: eh = 360      // snake
        default: break
        }
        let w: CGFloat = expanded ? min(ew, scr.frame.width - 24) : nw + (s.hasLive ? extra : 0), h: CGFloat = expanded ? eh : nh
        return NSRect(x: scr.frame.midX - w / 2, y: scr.frame.maxY - h, width: w, height: h)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: geometry(false), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RootView().environmentObject(s))
        panel.orderFrontRegardless()
        s.start(); liveModel.start()
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.check() }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NOTCH")
        let m = NSMenu()
        let a = m.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: ""); a.target = self
        let c = m.addItem(withTitle: "Click to Expand (instead of hover)", action: #selector(toggleClick(_:)), keyEquivalent: ""); c.target = self
        c.state = UserDefaults.standard.bool(forKey: "clickMode") ? .on : .off
        m.addItem(withTitle: "Quit NOTCH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    func check() {
        if !s.expanded { let g = geometry(false); if abs(g.width - panel.frame.width) > 1 { panel.setFrame(g, display: true, animate: true) } }
        else { let g = geometry(true); if abs(g.width - panel.frame.width) > 1 || abs(g.height - panel.frame.height) > 1 { panel.setFrame(g, display: true, animate: true) } }
        let near = panel.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
        let inside = (UserDefaults.standard.bool(forKey: "clickMode") && !s.expanded) ? (near && NSEvent.pressedMouseButtons & 1 != 0) : near
        if inside != s.expanded {
            withAnimation(.easeOut(duration: 0.2)) { s.expanded = inside }
            panel.setFrame(geometry(inside), display: true, animate: true)
            if inside {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                panel.makeKey()
            }
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
