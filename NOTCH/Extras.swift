import SwiftUI
import AppKit
import WebKit
import AVFoundation
import EventKit
import CoreWLAN
import Darwin
import UniformTypeIdentifiers

// MARK: Browser
struct Web: NSViewRepresentable {
    let wv: WKWebView
    func makeNSView(context: Context) -> WKWebView { wv }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
final class BModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var q = ""
    @Published var canBack = false
    @Published var canFwd = false
    @Published var loading = false
    let wv: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        // Stops the page itself from rubber-banding / chaining overscroll.
        let js = "(function(){var s=document.createElement('style');s.textContent='html,body{overscroll-behavior:none !important;}';(document.head||document.documentElement).appendChild(s);})();"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        wv = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        BModel.noBounce(wv)
    }

    /// Kills the native elastic / rubber-band scrolling.
    static func noBounce(_ v: NSView) {
        if let sv = v as? NSScrollView { sv.verticalScrollElasticity = .none; sv.horizontalScrollElasticity = .none }
        for c in v.subviews { noBounce(c) }
        let sel = NSSelectorFromString("_setRubberBandingEnabled:")
        if v is WKWebView, v.responds(to: sel) { _ = v.perform(sel, with: nil) }
    }

    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        if t.contains(".") && !t.contains(" "), let u = URL(string: t.hasPrefix("http") ? t : "https://" + t) { wv.load(URLRequest(url: u)) }
        else if let e = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: "https://www.google.com/search?q=" + e) { wv.load(URLRequest(url: u)) }
    }
    func refresh() { canBack = wv.canGoBack; canFwd = wv.canGoForward }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { loading = true }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { if let u = w.url { q = u.absoluteString }; refresh() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loading = false; refresh(); BModel.noBounce(w) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loading = false; refresh() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loading = false; refresh() }
    // links that want a new tab/window just open in this same view
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if a.targetFrame == nil { w.load(a.request) }
        return nil
    }
}
let browserModel = BModel()   // kept alive so your page survives tab switches

struct BrowserView: View {
    @ObservedObject var m = browserModel
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                btn("chevron.left") { m.wv.goBack() }.opacity(m.canBack ? 1 : 0.3).disabled(!m.canBack)
                btn("chevron.right") { m.wv.goForward() }.opacity(m.canFwd ? 1 : 0.3).disabled(!m.canFwd)
                btn(m.loading ? "xmark" : "arrow.clockwise") { if m.loading { m.wv.stopLoading() } else { m.wv.reload() } }
                TextField("Search or enter address", text: $m.q).textFieldStyle(.roundedBorder).onSubmit { m.go(m.q) }
            }
            Web(wv: m.wv).clipShape(RoundedRectangle(cornerRadius: 8))
        }.onAppear {
            if m.wv.url == nil { m.wv.load(URLRequest(url: URL(string: "https://www.google.com")!)) }
            BModel.noBounce(m.wv)
        }
    }
}

// MARK: Camera mirror
final class CamView: NSView {
    let session = AVCaptureSession()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        if let d = AVCaptureDevice.default(for: .video), let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) { session.addInput(i) }
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill; l.frame = bounds; l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        l.transform = CATransform3DMakeScale(-1, 1, 1)
        layer?.addSublayer(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}
struct CameraView: NSViewRepresentable {
    func makeNSView(context: Context) -> CamView {
        let v = CamView(frame: .zero)
        AVCaptureDevice.requestAccess(for: .video) { ok in if ok { DispatchQueue.global().async { v.session.startRunning() } } }
        return v
    }
    func updateNSView(_ v: CamView, context: Context) {}
    static func dismantleNSView(_ v: CamView, coordinator: ()) { v.session.stopRunning() }
}

// MARK: Calendar + reminders
final class Cal: ObservableObject {
    let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var reminders: [String] = []
    @Published var busy: Set<Int> = []
    func load() {
        let go: (Bool) -> Void = { ok in if ok { DispatchQueue.main.async { self.fetch() } } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in go(ok) }
            store.requestFullAccessToReminders { ok, _ in go(ok) }
        } else {
            store.requestAccess(to: .event) { ok, _ in go(ok) }
            store.requestAccess(to: .reminder) { ok, _ in go(ok) }
        }
    }
    func fetch() {
        let a = Calendar.current.startOfDay(for: Date())
        let b = Calendar.current.date(byAdding: .day, value: 2, to: a)!
        events = store.events(matching: store.predicateForEvents(withStart: a, end: b, calendars: nil)).sorted { $0.startDate < $1.startDate }
        if let mi = Calendar.current.dateInterval(of: .month, for: Date()) {
            busy = Set(store.events(matching: store.predicateForEvents(withStart: mi.start, end: mi.end, calendars: nil)).map { Calendar.current.component(.day, from: $0.startDate) })
        }
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { r in
            DispatchQueue.main.async { self.reminders = (r ?? []).prefix(8).map { $0.title ?? "" } }
        }
    }
}
struct CalendarView: View {
    @StateObject var c = Cal()
    @AppStorage("monthView") var month = true
    var eventsCol: some View {
        ScrollView { VStack(alignment: .leading, spacing: 4) {
            Text("Today & tomorrow").font(.caption).foregroundColor(.gray)
            if c.events.isEmpty { Text("No events").foregroundColor(.gray) }
            ForEach(c.events, id: \.eventIdentifier) { e in
                HStack { Text(e.startDate, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption).foregroundColor(.gray); Text(e.title ?? "").lineLimit(1) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    var remindersCol: some View {
        ScrollView { VStack(alignment: .leading, spacing: 4) {
            Text("Reminders").font(.caption).foregroundColor(.gray)
            if c.reminders.isEmpty { Text("All clear").foregroundColor(.gray) }
            ForEach(c.reminders, id: \.self) { r in Text("• " + r).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if month { MonthGrid(busy: c.busy).frame(width: 190) }
            eventsCol
            if !month { remindersCol }
            btn(month ? "list.bullet" : "calendar") { month.toggle() }
        }.onAppear { c.load() }
    }
}

// MARK: Network + system monitor
final class Sys: ObservableObject {
    @Published var down: [Double] = Array(repeating: 0, count: 40)
    @Published var cpu = 0.0
    @Published var mem = 0.0
    @Published var rssi = 0
    var last: UInt64 = 0, lastT = Date(), prev: host_cpu_load_info?, timer: Timer?
    func start() { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }; sample() }
    func stop() { timer?.invalidate() }
    static func bytesIn() -> UInt64 {
        var ifa: UnsafeMutablePointer<ifaddrs>?; var t: UInt64 = 0
        guard getifaddrs(&ifa) == 0 else { return 0 }
        var p = ifa
        while let c = p {
            if let a = c.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let d = c.pointee.ifa_data {
                t += UInt64(d.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes)
            }
            p = c.pointee.ifa_next
        }
        freeifaddrs(ifa); return t
    }
    func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var cnt = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cnt) } }
        guard r == KERN_SUCCESS else { return 0 }
        defer { prev = info }
        guard let p = prev else { return 0 }
        let u = Double(info.cpu_ticks.0 &- p.cpu_ticks.0), s = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let i = Double(info.cpu_ticks.2 &- p.cpu_ticks.2), n = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let tot = u + s + i + n
        return tot > 0 ? (u + s + n) / tot : 0
    }
    func memUsed() -> Double {
        var st = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) } }
        guard r == KERN_SUCCESS else { return 0 }
        let pages = Double(st.active_count) + Double(st.wire_count) + Double(st.compressor_page_count)
        return pages * Double(sysconf(_SC_PAGESIZE)) / Double(ProcessInfo.processInfo.physicalMemory)
    }
    func sample() {
        let now = Date(), b = Sys.bytesIn(), dt = max(now.timeIntervalSince(lastT), 0.1)
        if last > 0, b >= last { down = Array(down.dropFirst()) + [Double(b - last) / dt] }
        last = b; lastT = now
        cpu = cpuLoad(); mem = memUsed(); rssi = CWWiFiClient.shared().interface()?.rssiValue() ?? 0
    }
}
struct Spark: View {
    var v: [Double]
    var body: some View {
        GeometryReader { g in
            let m = max(v.max() ?? 1, 1)
            Path { p in
                for (i, x) in v.enumerated() {
                    let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(v.count - 1, 1)), y: g.size.height * (1 - CGFloat(x / m)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }.stroke(Color.cyan, lineWidth: 2)
        }
    }
}
struct SysView: View {
    @StateObject var y = Sys()
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading) {
                Text(String(format: "Down %.2f MB/s", (y.down.last ?? 0) / 1_048_576)).font(.caption)
                Spark(v: y.down).frame(maxHeight: .infinity)
                HStack { Image(systemName: "wifi"); Text(y.rssi == 0 ? "No Wi-Fi" : "\(y.rssi) dBm").font(.caption) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "CPU %.0f%%", y.cpu * 100)).font(.caption); ProgressView(value: y.cpu)
                Text(String(format: "Memory %.0f%%", y.mem * 100)).font(.caption); ProgressView(value: min(y.mem, 1))
            }.frame(width: 200)
        }.onAppear { y.start() }.onDisappear { y.stop() }
    }
}

// MARK: Shortcuts app
@discardableResult func runShortcuts(_ a: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = a
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run()
    if a.first == "list" { return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    return ""
}
final class SModel: ObservableObject { @Published var names: [String] = [] }
struct ShortcutsView: View {
    @StateObject var m = SModel()
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 6) {
                ForEach(m.names, id: \.self) { n in
                    Button { runShortcuts(["run", n]) } label: { Text(n).lineLimit(1).frame(maxWidth: .infinity).padding(6).background(Color.white.opacity(0.1)).cornerRadius(8) }.buttonStyle(.plain)
                }
            }
        }.onAppear {
            DispatchQueue.global().async {
                let o = runShortcuts(["list"])
                DispatchQueue.main.async { m.names = o.split(separator: "\n").map(String.init) }
            }
        }
    }
}

// MARK: Safari / browser music (reads media tabs via AppleScript + JavaScript)
let safariJS = #"(function(){var m=[].slice.call(document.querySelectorAll('video,audio')).filter(function(e){return !e.paused&&!e.ended&&e.currentTime>0});if(!m.length)return '';var d=navigator.mediaSession&&navigator.mediaSession.metadata;var a=d&&d.artwork&&d.artwork.length?d.artwork[d.artwork.length-1].src:'';return [(d&&d.title)||document.title,(d&&d.artist)||location.hostname,a].join('|||');})()"#
let safariScan = """
tell application "Safari"
  repeat with wi from 1 to count of windows
    repeat with ti from 1 to count of tabs of window wi
      try
        set r to do JavaScript "\(safariJS)" in tab ti of window wi
        if r is not missing value and r is not "" then return (wi as string) & "|||" & (ti as string) & "|||" & r
      end try
    end repeat
  end repeat
end tell
"""
extension Store {
    func pollSafari() {
        guard isRunning("com.apple.Safari") else { playing = false; return }
        if safBusy { return }
        safBusy = true
        DispatchQueue.global(qos: .utility).async {
            let r = osa(safariScan)?.stringValue
            DispatchQueue.main.async {
                self.safBusy = false
                guard let r = r else { self.playing = false; return }
                let p = r.components(separatedBy: "|||")
                guard p.count >= 5 else { self.playing = false; return }
                self.src = "Safari"; self.safW = Int(p[0]) ?? 1; self.safT = Int(p[1]) ?? 1; self.playing = true
                if p[2] != self.track {
                    self.track = p[2]; self.artist = p[3]; self.art = nil
                    if !p[4].isEmpty, let u = URL(string: p[4]) {
                        DispatchQueue.global().async {
                            if let d = try? Data(contentsOf: u), let i = NSImage(data: d) { DispatchQueue.main.async { self.art = i } }
                        }
                    }
                }
            }
        }
    }
    func safariCtl(_ cmd: String) {
        let js: String
        switch cmd {
        case "next track": js = "var b=document.querySelector('.ytp-next-button,.next-button,[aria-label=Next],[data-testid=control-button-skip-forward]');if(b)b.click();"
        case "previous track": js = "var b=document.querySelector('.ytp-prev-button,.previous-button,[aria-label=Previous],[data-testid=control-button-skip-back]');if(b)b.click();"
        default: js = "var l=[].slice.call(document.querySelectorAll('video,audio'));var e=l.filter(function(x){return !x.paused})[0]||l[0];if(e){e.paused?e.play():e.pause()};"
        }
        osa("tell application \"Safari\" to do JavaScript \"\(js)\" in tab \(safT) of window \(safW)")
    }
}

// MARK: Date colour presets (right-click the clock/date)
let colorNames = ["white", "green", "cyan", "pink", "orange", "yellow", "purple", "red"]
func presetColor(_ n: String) -> Color {
    switch n {
    case "green": return .green
    case "cyan": return .cyan
    case "pink": return .pink
    case "orange": return .orange
    case "yellow": return .yellow
    case "purple": return .purple
    case "red": return .red
    default: return .white
    }
}
extension RootView {
    var colorMenu: some View {
        ForEach(colorNames, id: \.self) { n in Button("Date colour: " + n.capitalized) { dateColor = n } }
    }
}

// MARK: Month grid
struct MonthGrid: View {
    var busy: Set<Int>
    var body: some View {
        let cal = Calendar.current, now = Date()
        let first = cal.dateInterval(of: .month, for: now)!.start
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let today = cal.component(.day, from: now)
        let syms = cal.veryShortWeekdaySymbols
        let heads = (0..<7).map { syms[($0 + cal.firstWeekday - 1) % 7] }
        VStack(spacing: 2) {
            Text(now, format: .dateTime.month(.wide).year()).font(.caption.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(0..<7, id: \.self) { i in Text(heads[i]).font(.system(size: 9)).foregroundColor(.gray) }
                ForEach(0..<(lead + days), id: \.self) { i in
                    if i < lead { Color.clear.frame(height: 15) }
                    else {
                        let d = i - lead + 1
                        Text("\(d)").font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 15)
                            .background(Circle().fill(d == today ? Color.blue : Color.clear))
                            .overlay(alignment: .bottom) { if busy.contains(d) { Circle().fill(Color.orange).frame(width: 3, height: 3) } }
                    }
                }
            }
        }
    }
}

// MARK: Themes
func fontDesignValue(_ n: String) -> Font.Design {
    switch n {
    case "rounded": return .rounded
    case "serif": return .serif
    case "monospaced": return .monospaced
    default: return .default
    }
}
struct ThemeView: View {
    @AppStorage("accent") var accent = "green"
    @AppStorage("dateColor") var dateColor = "white"
    @AppStorage("fontDesign") var fd = "default"
    @AppStorage("corner") var corner = 24.0
    @AppStorage("pillExtra") var pillExtra = 92.0
    func swatches(_ b: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(colorNames, id: \.self) { n in
                Circle().fill(presetColor(n)).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: b.wrappedValue == n ? 2.5 : 0))
                    .onTapGesture { b.wrappedValue = n }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Accent").frame(width: 70, alignment: .leading); swatches($accent) }
            HStack { Text("Clock").frame(width: 70, alignment: .leading); swatches($dateColor) }
            HStack {
                Text("Font").frame(width: 70, alignment: .leading)
                Picker("", selection: $fd) { ForEach(["default", "rounded", "serif", "monospaced"], id: \.self) { Text($0.capitalized).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 320)
            }
            HStack { Text("Corners").frame(width: 70, alignment: .leading); Slider(value: $corner, in: 6...40).frame(width: 320) }
            HStack { Text("Pill width").frame(width: 70, alignment: .leading); Slider(value: $pillExtra, in: 40...170).frame(width: 320); Text("\(Int(pillExtra))").font(.caption).foregroundColor(.gray) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Live activities (downloads, calls/mic, timers, music) shown as a pill around the notch
import CoreAudio
struct DL { var name: String; var mb: Double; var speed: Double }
func micActive() -> Bool {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &dev) == noErr else { return false }
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    var run: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &run) == noErr else { return false }
    return run != 0
}
func sizeOf(_ u: URL) -> Int {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
    if !isDir.boolValue { return (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    var t = 0
    if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let x as URL in e { t += (try? x.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    }
    return t
}
final class LiveModel: ObservableObject {
    @Published var mic = false
    @Published var callApp = ""
    @Published var dl: DL?
    var lastSize = 0.0, lastName = "", lastT = Date(), timer: Timer?
    func start() { timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() } }
    func poll() {
        mic = micActive()
        let known = ["com.apple.FaceTime": "FaceTime", "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.hnc.Discord": "Discord"]
        callApp = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }.compactMap { known[$0] }.first ?? ""
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let exts = ["crdownload", "download", "part", "opdownload"]
        let now = Date()
        let hit = items.first { u in
            guard exts.contains(u.pathExtension) else { return false }
            if u.pathExtension == "download" { return true }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return now.timeIntervalSince(m) < 8
        }
        if let f = hit {
            let mb = Double(sizeOf(f)) / 1_048_576
            let dt = max(now.timeIntervalSince(lastT), 0.1)
            let sp = lastName == f.lastPathComponent ? max(mb - lastSize, 0) / dt : 0
            lastSize = mb; lastName = f.lastPathComponent; lastT = now
            dl = DL(name: f.deletingPathExtension().lastPathComponent, mb: mb, speed: sp)
        } else { dl = nil; lastName = "" }
    }
}
let liveModel = LiveModel()
extension Store {
    var hasLive: Bool { playing || running || swRunning || liveModel.mic || liveModel.dl != nil }
}
extension RootView {
    var pill: some View {
        let e = CGFloat(pillExtra) / 2          // width of the strip on each side of the notch
        return HStack(spacing: 0) {
            ear(true).frame(width: max(e - 4, 12))
            Spacer(minLength: 0)
            ear(false).frame(width: max(e - 4, 12))
        }.padding(.horizontal, 2)
    }
    @ViewBuilder func ear(_ left: Bool) -> some View {
        earContent(left).lineLimit(1).minimumScaleFactor(0.55)
    }
    @ViewBuilder func earContent(_ left: Bool) -> some View {
        let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
        if left {
            if live.mic { Image(systemName: "mic.fill").foregroundColor(.orange) }
            else if live.dl != nil { Image(systemName: "arrow.down.circle.fill").foregroundColor(presetColor(accent)) }
            else if s.playing, let a = s.art { Image(nsImage: a).resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5)) }
            else if s.playing { Bars(on: true).scaleEffect(0.6) }
            else { Image(systemName: "timer").foregroundColor(presetColor(accent)) }
        } else {
            if s.running { Text(mmss(s.remaining)).font(mono) }
            else if s.swRunning { Text(mmss(s.sw)).font(mono) }
            else if let d = live.dl { Text(String(format: "%.1fMB/s", d.speed)).font(.system(size: 9, weight: .medium, design: .monospaced)) }
            else if live.mic { Text(live.callApp.isEmpty ? "Mic" : live.callApp).font(.system(size: 10)) }
            else if s.playing { Bars(on: true).scaleEffect(0.6) }
        }
    }
}

// MARK: AirDrop (click the tile to send the shelf, or drop files straight onto it)
final class AirDrop: NSObject, NSSharingServiceDelegate {
    static let shared = AirDrop()
    var service: NSSharingService?

    static func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { shared.run(urls) }
    }

    func run(_ urls: [URL]) {
        // The AirDrop sheet only comes to the front if the app is active.
        NSApp.activate(ignoringOtherApps: true)
        if let svc = NSSharingService(named: .sendViaAirDrop), svc.canPerform(withItems: urls) {
            svc.delegate = self
            service = svc
            svc.perform(withItems: urls)
        } else if let v = (NSApp.delegate as? AppDelegate)?.panel.contentView {
            // AirDrop not directly available -> fall back to the normal share menu
            NSSharingServicePicker(items: urls).show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.maxY - 4, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { service = nil }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { service = nil }
}

extension RootView {
    var airdropTile: some View {
        VStack(spacing: 4) {
            Button { airdropTap() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.title2)
                    Text("AirDrop").font(.caption.bold())
                    Text(s.files.isEmpty ? "Click or drop" : "Send \(s.files.count) file\(s.files.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundColor(.white.opacity(0.7))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button("Clear") { s.files.removeAll() }.font(.caption2).buttonStyle(.plain).foregroundColor(.gray).padding(.bottom, 6)
        }
        .frame(width: 100).frame(maxHeight: .infinity)
        .background(Color.blue.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { ps in
            loadURLs(ps) { us in AirDrop.send(us) }; return true
        }
    }

    func airdropTap() {
        if !s.files.isEmpty { AirDrop.send(s.files); return }
        // nothing on the shelf yet -> pick files to send
        NSApp.activate(ignoringOtherApps: true)
        let o = NSOpenPanel()
        o.allowsMultipleSelection = true; o.canChooseDirectories = true; o.prompt = "AirDrop"
        if o.runModal() == .OK, !o.urls.isEmpty { AirDrop.send(o.urls) }
    }
}

// MARK: Customisable counter card (water glasses + counter)
final class CardUI: ObservableObject { @Published var editing = false }

struct CounterCard: View {
    let id: String
    let negative: Bool
    @Binding var value: Int
    @AppStorage private var label: String
    @AppStorage private var unit: String
    @AppStorage private var step: Int
    @AppStorage private var goal: Int
    @AppStorage private var colorName: String
    @AppStorage private var daily: Bool
    @StateObject private var ui = CardUI()

    init(id: String, label: String, unit: String, step: Int, goal: Int, color: String, daily: Bool, negative: Bool, value: Binding<Int>) {
        self.id = id
        self.negative = negative
        _value = value
        _label = AppStorage(wrappedValue: label, id + "Label")
        _unit = AppStorage(wrappedValue: unit, id + "Unit")
        _step = AppStorage(wrappedValue: step, id + "Step")
        _goal = AppStorage(wrappedValue: goal, id + "Goal")
        _colorName = AppStorage(wrappedValue: color, id + "Color")
        _daily = AppStorage(wrappedValue: daily, id + "Daily")
    }

    var tint: Color { presetColor(colorName) }
    var frac: Double { goal > 0 ? min(1, max(0, Double(value) / Double(goal))) : 0 }
    var reached: Bool { goal > 0 && value >= goal }

    var body: some View {
        Group { if ui.editing { settings } else { face } }
            .padding(10)
            .frame(width: ui.editing ? 230 : 156)
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.08)).cornerRadius(10)
            .animation(.easeOut(duration: 0.18), value: ui.editing)
    }

    var face: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundColor(.gray).lineLimit(1)
                Spacer(minLength: 0)
                Button { ui.editing = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundColor(.gray).frame(width: 20, height: 16).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ZStack {
                if goal > 0 {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                    Circle().trim(from: 0, to: frac)
                        .stroke(reached ? Color.yellow : tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: frac)
                }
                VStack(spacing: 0) {
                    Text("\(value)").font(.system(size: goal > 0 ? 24 : 34, weight: .light)).lineLimit(1).minimumScaleFactor(0.5)
                    if goal > 0 { Text("/ \(goal)" + (unit.isEmpty ? "" : " " + unit)).font(.system(size: 9)).foregroundColor(.gray).lineLimit(1) }
                    else if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundColor(.gray).lineLimit(1) }
                }.padding(.horizontal, 8)
            }.padding(2).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 14) {
                btn("minus.circle") { value = negative ? value - step : max(0, value - step) }
                btn("plus.circle") { value += step }
            }
        }
    }

    func row(_ t: String) -> some View { Text(t).font(.caption).foregroundColor(.gray).frame(width: 34, alignment: .leading) }

    var settings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                TextField("Name", text: $label).textFieldStyle(.roundedBorder).font(.caption)
                TextField("Unit", text: $unit).textFieldStyle(.roundedBorder).font(.caption).frame(width: 64)
            }
            HStack { row("Step"); Stepper("\(step)", value: $step, in: 1...500).font(.caption) }
            HStack { row("Goal"); Stepper(goal == 0 ? "Off" : "\(goal)", value: $goal, in: 0...5000).font(.caption) }
            HStack(spacing: 6) {
                row("Now")
                TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).font(.caption).frame(width: 58)
                Toggle("Daily reset", isOn: $daily).toggleStyle(.checkbox).font(.caption)
            }
            HStack(spacing: 3) {
                ForEach(colorNames, id: \.self) { n in
                    Circle().fill(presetColor(n)).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: colorName == n ? 2 : 0))
                        .onTapGesture { colorName = n }
                }
                Spacer(minLength: 0)
                Button("Done") { ui.editing = false }.font(.caption)
            }
        }
    }
}
