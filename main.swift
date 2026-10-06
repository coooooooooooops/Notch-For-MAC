import SwiftUI
import AppKit
import CryptoKit
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
    @Published var labOn = false { didSet { UserDefaults.standard.set(labOn, forKey: "labOn") } }
    @Published var files: [URL] = []
    @Published var clips: [String] = []
    @Published var pinned: [String] = [] { didSet { UserDefaults.standard.set(pinned, forKey: "pinnedClips") } }
    var forceOpen = false             // opened with the hotkey: stays open until hotkey / click away
    var onTimerDone: (() -> Void)?    // AppDelegate hooks this to wobble the notch
    @Published var track = "Nothing playing"
    @Published var artist = ""
    @Published var art: NSImage?
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
        d.register(defaults: ["waterDaily": true, "counterDaily": false, "pillExtra": 92.0])
        if d.string(forKey: "lastDay") == nil, let old = d.string(forKey: "waterDay") { d.set(old, forKey: "lastDay") }
        labOn = (d.object(forKey: "labOn") as? Bool) ?? d.bool(forKey: unb64("Z2FtZVVubG9ja2Vk"))   // (carries over the setting from before the rename)
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

    /// Hidden commands typed into a note, then Enter. They are checked by fingerprint, so the words themselves are not stored here.
    /// If the last line was a command it is run and the text WITHOUT that line is returned (so it disappears from the note).
    static func fingerprint(_ t: String) -> String {
        SHA256.hash(data: Data(("nt:" + t).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static let cmdOn = "75008940b4ceb6fa9e2841c837c9b909752bf82cd3b834455c54271e05a15a2e"
    static let cmdOff = "0934e2b83416e72b76b5d98a62c2247896d1d8c21073b0d055bba61b6f32a189"

    func runCode(_ text: String) -> String? {
        guard text.hasSuffix("\n") else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let cmd = lines[lines.count - 2].trimmingCharacters(in: .whitespaces).lowercased()
        let fp = Store.fingerprint(cmd)
        guard fp == Store.cmdOn || fp == Store.cmdOff else { return nil }
        lines.removeLast(2)
        let cleaned = lines.joined(separator: "\n")
        DispatchQueue.main.async {
            if fp == Store.cmdOn {
                self.labOn = true
            } else {
                self.labOn = false
                if self.tab == labTab { self.tab = 0 }
                LabModel.shared.suspend()
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        }
        return cleaned
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

    func isRunning(_ id: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id } }

    func pollMusic() {
        let cands = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")].filter { isRunning($0.1) }
        var hit = false
        for (app, _) in cands {
            let script = "tell application \"\(app)\" to if player state is playing then return (name of current track) & \"\\n\" & (artist of current track) & \"\\n\" & (player position as string) & \"\\n\" & (duration of current track as string)"
            guard let r = osa(script)?.stringValue else { continue }
            let p = r.components(separatedBy: "\n")
            hit = true; src = app; playing = true
            if p.count >= 4 {
                pos = Store.num(p[2]); posAt = Date()
                let d = Store.num(p[3]); dur = app == "Spotify" ? d / 1000 : d   // Spotify reports milliseconds
            }
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

// Holds the clipboard search text. (@State is an Xcode-only macro in the newest SDKs, so Command Line Tools builds can't use it.)
final class ClipUI: ObservableObject { @Published var query = "" }

struct RootView: View {
    @EnvironmentObject var s: Store
    @AppStorage("dateColor") var dateColor = "white"
    @AppStorage("accent") var accent = "green"
    @AppStorage("fontDesign") var fd = "default"
    @AppStorage("corner") var corner = 24.0
    @AppStorage("pillExtra") var pillExtra = 92.0
    @ObservedObject var live = liveModel
    @ObservedObject var upd = Updater.shared
    @ObservedObject var prefs = TabPrefs.shared
    @StateObject var clipUI = ClipUI()
    @ObservedObject var clipImgs = ClipImages.shared
    var clipQuery: String { get { clipUI.query } nonmutating set { clipUI.query = newValue } }
    let icons = tabIcons

    /// Left-to-right order of the visible tab icons (indices into `icons`), as set in Customise tabs.
    var tabOrder: [Int] { prefs.visible(labOn: s.labOn) }

    /// If the current tab was hidden, jump to the first one that is still shown.
    func fixTab() { if !tabOrder.contains(s.tab), let f = tabOrder.first { s.tab = f } }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(r: s.expanded ? CGFloat(corner) : 10).fill(Color.black)
            if !s.expanded && s.hasLive { pill }
            if s.expanded {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(tabOrder, id: \.self) { i in
                            Button { s.tab = i; prefs.editing = false } label: {
                                Image(systemName: icons[i]).frame(minWidth: 20, maxWidth: 32).frame(height: 24)
                                    .background(s.tab == i ? presetColor(accent).opacity(0.35) : Color.clear).clipShape(Capsule())
                                    .overlay(alignment: .topTrailing) {
                                        if i == updaterTab && upd.badge { Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -2, y: 1) }
                                    }
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        if s.battery >= 0 {
                            HStack(spacing: 4) {
                                BatteryIcon(level: s.battery, charging: s.charging, lowPower: s.lowPower)
                                Text("\(s.battery)%").font(.caption).lineLimit(1)
                                    .foregroundColor(batteryTint(s.battery, s.charging, s.lowPower) == .white ? .white : batteryTint(s.battery, s.charging, s.lowPower))
                            }.fixedSize().layoutPriority(1)
                        }
                    }.frame(maxWidth: 640)
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
                        case 11: SettingsView()
                        case weatherTab: WeatherView()
                        case updaterTab: UpdaterView()
                        case labTab: if s.labOn { LabView() } else { AppsView() }
                        default: AppsView()
                        }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.padding(.top, 38).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }.foregroundColor(.white).preferredColorScheme(.dark).tint(presetColor(accent)).fontDesign(fontDesignValue(fd))
        .onAppear { fixTab() }
        .onChange(of: prefs.hidden) { _ in fixTab() }
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
                    Spacer(minLength: 8)
                    Bars(on: s.playing)
                }
                Scrubber()
            }.frame(minWidth: 250, maxWidth: 340, alignment: .leading)
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
            .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NotchPanel!
    var item: NSStatusItem!
    let s = Store.shared
    var wobbling = false

    func geometry(_ expanded: Bool) -> NSRect {
        let scr = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var nw: CGFloat = 200, nh: CGFloat = 32
        if scr.safeAreaInsets.top > 0, let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea {
            nw = r.minX - l.maxX; nh = scr.safeAreaInsets.top
        }
        let extra = CGFloat((UserDefaults.standard.object(forKey: "pillExtra") as? Double) ?? 92)
        var ew: CGFloat = 680, eh: CGFloat = 220
        switch s.tab {
        case 3: eh = 230            // timers (focus / break length pills)
        case 5: if AppsModel.shared.openKey != nil { ew = 820; eh = 460 }   // an app running inside the notch
        case 4: eh = 250            // notes + water + counter (customise panel needs room)
        case 6, 7, labTab, aiTab: ew = 820; eh = 460   // browser, camera, AI and the hidden tab share one big size
        case 10: eh = 340           // control centre
        case 2: eh = ClipImages.shared.items.isEmpty ? 250 : 296   // clipboard (search + pinned, plus the image strip)
        case 11: eh = 310           // settings (scrolls)
        case weatherTab: eh = 290   // weather
        case updaterTab: eh = 300   // updates list
        default: break
        }
        if TabPrefs.shared.editing { ew = 680; eh = 340 }   // Customise tabs screen
        let w: CGFloat = expanded ? min(ew, scr.frame.width - 24) : nw + (s.hasLive ? extra : 0), h: CGFloat = expanded ? eh : nh
        return NSRect(x: scr.frame.midX - w / 2, y: scr.frame.maxY - h, width: w, height: h)
    }

    func applicationWillTerminate(_ n: Notification) { LocalServer.cleanup() }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: geometry(false), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RootView().environmentObject(s))
        panel.orderFrontRegardless()
        s.start(); liveModel.start(); Updater.shared.start()
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.check() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in IdleSweeper.run() }
        s.onTimerDone = { [weak self] in self?.wobble() }

        // global hotkeys (Control + Option + key; customise them in Settings)
        Hotkeys.shared.onFire = { [weak self] a in self?.hotkey(a) }
        Hotkeys.shared.apply()
        // clicking anywhere else puts a hotkey-opened notch away again
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.s.forceOpen else { return }
            if !self.panel.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation) { self.s.forceOpen = false }
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
        let base = geometry(s.expanded)
        let big: CGFloat = s.expanded ? 0.45 : 1
        let start = Date()
        let dur = 1.7, freq = 3.2
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let e = Date().timeIntervalSince(start)
            if e >= dur {
                tm.invalidate(); self.wobbling = false
                self.panel.setFrame(self.geometry(self.s.expanded), display: true)
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
        if wobbling { return }
        if !s.expanded { let g = geometry(false); if abs(g.width - panel.frame.width) > 1 { panel.setFrame(g, display: true, animate: true) } }
        else { let g = geometry(true); if abs(g.width - panel.frame.width) > 1 || abs(g.height - panel.frame.height) > 1 { panel.setFrame(g, display: true, animate: true) } }
        let slop: CGFloat = (s.expanded && s.tab == labTab) ? 70 : 12   // extra room so the notch doesn't close while that tab has focus
        let near = panel.frame.insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
        let holding = s.expanded && s.tab == labTab && s.labOn && NSEvent.pressedMouseButtons != 0   // don't pull the page away mid-drag
        let inside = ((UserDefaults.standard.bool(forKey: "clickMode") && !s.expanded) ? (near && NSEvent.pressedMouseButtons & 1 != 0) : near) || s.forceOpen || holding
        if inside != s.expanded {
            withAnimation(.easeOut(duration: 0.2)) { s.expanded = inside }
            panel.setFrame(geometry(inside), display: true, animate: true)
            if inside {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                panel.makeKey()
            } else {
                browserModel.reset()        // search browser starts fresh next time
                LabModel.shared.suspend()  // silence + pause the page
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
