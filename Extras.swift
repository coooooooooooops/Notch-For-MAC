import Combine
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
    @Published var wv: WKWebView
    @Published var gen = 0          // bumps on reset so SwiftUI swaps in the fresh web view
    @Published var zoom: Double = BModel.savedZoom()   // page zoom (default 60% so a normal page fits the small panel)

    static func savedZoom() -> Double {
        let z = UserDefaults.standard.double(forKey: "browserZoom")
        return z == 0 ? 0.6 : min(1.5, max(0.4, z))
    }
    func setZoom(_ z: Double) {
        let c = min(1.5, max(0.4, (z * 10).rounded() / 10))
        zoom = c
        UserDefaults.standard.set(c, forKey: "browserZoom")
        wv.pageZoom = CGFloat(c)
    }

    static func makeWV() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Stops the page itself from rubber-banding / chaining overscroll.
        let js = "(function(){var s=document.createElement('style');s.textContent='html,body{overscroll-behavior:none !important;}';(document.head||document.documentElement).appendChild(s);})();"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.pageZoom = CGFloat(savedZoom())
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        return w
    }

    override init() {
        wv = BModel.makeWV()
        super.init()
        install(wv)
    }

    func install(_ w: WKWebView) {
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = false
        BModel.noBounce(w)
    }

    /// Called when the notch closes: throws away the page, history and address bar so the next open is a fresh start.
    func reset() {
        guard wv.url != nil || !q.isEmpty else { return }
        let old = wv
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.loadHTMLString("", baseURL: nil)   // also stops any video / audio still playing
        let w = BModel.makeWV()
        install(w)
        wv = w
        q = ""; canBack = false; canFwd = false; loading = false
        gen += 1
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
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loading = false; refresh(); BModel.noBounce(w); w.pageZoom = CGFloat(zoom) }
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
                btn("minus.magnifyingglass") { m.setZoom(m.zoom - 0.1) }
                Text("\(Int((m.zoom * 100).rounded()))%").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    .frame(width: 34).onTapGesture { m.setZoom(0.6) }
                btn("plus.magnifyingglass") { m.setZoom(m.zoom + 0.1) }
            }
            Web(wv: m.wv).id(m.gen).clipShape(RoundedRectangle(cornerRadius: 8))
        }.onAppear {
            if m.wv.url == nil { m.wv.load(URLRequest(url: URL(string: "https://www.google.com")!)) }
            BModel.noBounce(m.wv)
        }
    }
}

// MARK: Camera mirror + photos
final class PhotoSaver: NSObject, AVCapturePhotoCaptureDelegate {
    let done: (URL?, Data?) -> Void
    init(_ done: @escaping (URL?, Data?) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { DispatchQueue.main.async { self.done(nil, nil) }; return }
        let dir = CamModel.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("NOTCH \(f.string(from: Date())).jpg")
        do { try data.write(to: url); DispatchQueue.main.async { self.done(url, data) } }
        catch { DispatchQueue.main.async { self.done(nil, nil) } }
    }
}

final class CamModel: ObservableObject {
    static let shared = CamModel()
    @Published var flash = false
    @Published var last: NSImage?
    @Published var lastURL: URL?
    @Published var note = ""
    weak var view: CamView?
    var saver: PhotoSaver?

    static var dir: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("NOTCH", isDirectory: true)
    }

    /// Re-reads Pictures/NOTCH so the thumbnail always matches what is really on disk:
    /// delete (or trash) a photo and it disappears; the next-newest photo takes its place; no photos = no thumbnail.
    func refreshLast() {
        let current = lastURL
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = ((try? FileManager.default.contentsOfDirectory(at: CamModel.dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
            let newest = files.max { date($0) < date($1) }
            if let n = newest, let c = current, n.path == c.path { return }      // nothing changed
            var img: NSImage? = nil
            if let n = newest, let d = try? Data(contentsOf: n) { img = NSImage(data: d) }
            DispatchQueue.main.async {
                if img == nil { self.last = nil; self.lastURL = nil }
                else { self.last = img; self.lastURL = newest }
            }
        }
    }

    func snap() {
        guard let v = view, v.session.isRunning else { say("Camera not ready"); return }
        if let c = v.output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true          // saved photo matches the mirrored preview
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { withAnimation(.easeOut(duration: 0.35)) { CamModel.shared.flash = false } }
        let sv = PhotoSaver { [weak self] url, data in
            guard let self = self else { return }
            if let url = url, let data = data { self.lastURL = url; self.last = NSImage(data: data); self.say("Saved to Pictures/NOTCH") }
            else { self.say("Couldn't save photo") }
            self.saver = nil
        }
        saver = sv
        v.output.capturePhoto(with: settings, delegate: sv)
    }

    func say(_ t: String) {
        note = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in if self?.note == t { self?.note = "" } }
    }
}

final class CamView: NSView {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        session.beginConfiguration()
        session.sessionPreset = .high
        if let d = AVCaptureDevice.default(for: .video), let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) { session.addInput(i) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
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
        CamModel.shared.view = v
        AVCaptureDevice.requestAccess(for: .video) { ok in if ok { DispatchQueue.global().async { v.session.startRunning() } } }
        return v
    }
    func updateNSView(_ v: CamView, context: Context) {}
    static func dismantleNSView(_ v: CamView, coordinator: ()) { v.session.stopRunning() }
}

/// Camera tab: live mirror with a shutter button (or press Space). Photos go to ~/Pictures/NOTCH.
struct CameraTab: View {
    @ObservedObject var cm = CamModel.shared

    var body: some View {
        ZStack {
            CameraView()
            Color.white.opacity(cm.flash ? 0.9 : 0).allowsHitTesting(false)
            VStack {
                if !cm.note.isEmpty {
                    Text(cm.note).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.black.opacity(0.6)).clipShape(Capsule()).padding(.top, 10)
                }
                Spacer()
                HStack {
                    Group {
                        if let img = cm.last {
                            Button {
                                if let u = cm.lastURL, FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                else { cm.refreshLast() }
                            } label: {
                                Image(nsImage: img).resizable().scaledToFill().frame(width: 54, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                            }.buttonStyle(.plain).help("Show in Finder")
                        } else { Color.clear.frame(width: 54, height: 40) }
                    }
                    Spacer()
                    Button { cm.snap() } label: {
                        ZStack {
                            Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 54, height: 54)
                            Circle().fill(Color.white).frame(width: 42, height: 42)
                        }.contentShape(Circle())
                    }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help("Take photo (Space)")
                    Spacer()
                    Color.clear.frame(width: 54, height: 40)
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { cm.refreshLast() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in cm.refreshLast() }
    }
}

// MARK: Calendar + reminders
final class Cal: ObservableObject {
    let store = EKEventStore()
    @Published var events: [EKEvent] = []                         // events on the selected day
    @Published var reminders: [String] = []
    @Published var busy: Set<Int> = []                            // days of the shown month that have something on
    @Published var shown = Cal.monthStart(Date())                 // month being looked at
    @Published var selected = Calendar.current.startOfDay(for: Date())   // day being looked at

    static func monthStart(_ d: Date) -> Date { Calendar.current.dateInterval(of: .month, for: d)?.start ?? d }

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

    func goToday() { select(Date()) }

    func select(_ d: Date) {
        selected = Calendar.current.startOfDay(for: d)
        shown = Cal.monthStart(d)
        fetch()
    }

    func shift(_ months: Int) {
        shown = Calendar.current.date(byAdding: .month, value: months, to: shown) ?? shown
        fetch()
    }

    func fetch() {
        let cal = Calendar.current
        let a = selected
        let b = cal.date(byAdding: .day, value: 1, to: a) ?? a.addingTimeInterval(86400)
        events = store.events(matching: store.predicateForEvents(withStart: a, end: b, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        if let mi = cal.dateInterval(of: .month, for: shown) {
            var days = Set<Int>()
            for e in store.events(matching: store.predicateForEvents(withStart: mi.start, end: mi.end, calendars: nil)) {
                var d = max(cal.startOfDay(for: e.startDate), mi.start)
                let end = min(e.endDate, mi.end)
                var n = 0
                repeat {
                    days.insert(cal.component(.day, from: d))
                    d = cal.date(byAdding: .day, value: 1, to: d) ?? end
                    n += 1
                } while d < end && n < 40
            }
            busy = days
        }
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { r in
            DispatchQueue.main.async { self.reminders = (r ?? []).prefix(8).map { $0.title ?? "" } }
        }
    }
}

struct CalendarView: View {
    @StateObject var c = Cal()
    @AppStorage("monthView") var month = true

    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(c.selected) { return "Today" }
        if cal.isDateInTomorrow(c.selected) { return "Tomorrow" }
        if cal.isDateInYesterday(c.selected) { return "Yesterday" }
        return c.selected.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    func timeLabel(_ e: EKEvent) -> String {
        e.isAllDay ? "All day" : e.startDate.formatted(date: .omitted, time: .shortened)
    }

    var eventsCol: some View {
        ScrollView { VStack(alignment: .leading, spacing: 4) {
            Text(dayTitle).font(.caption.bold()).foregroundColor(.gray)
            if c.events.isEmpty { Text("No events").foregroundColor(.gray) }
            ForEach(c.events, id: \.eventIdentifier) { e in
                HStack(spacing: 6) {
                    Circle().fill(e.calendar?.cgColor.map { Color(cgColor: $0) } ?? Color.gray).frame(width: 6, height: 6)
                    Text(timeLabel(e)).font(.caption).foregroundColor(.gray).frame(width: 52, alignment: .leading)
                    Text(e.title ?? "").lineLimit(1)
                }
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
            if month {
                MonthGrid(shown: c.shown, selected: c.selected, busy: c.busy,
                          onSelect: { c.select($0) }, onShift: { c.shift($0) }, onToday: { c.goToday() })
                    .frame(width: 190)
            }
            eventsCol
            if !month { remindersCol }
            btn(month ? "list.bullet" : "calendar") { month.toggle() }
        }.onAppear {
            c.selected = Calendar.current.startOfDay(for: Date())     // start on today each time the notch opens
            c.shown = Cal.monthStart(Date())
            c.load()
        }
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

// MARK: Safari / browser music (reads media tabs via AppleScript + JavaScript)
let safariJS = #"(function(){var m=[].slice.call(document.querySelectorAll('video,audio')).filter(function(e){return !e.paused&&!e.ended&&e.currentTime>0});if(!m.length)return '';var d=navigator.mediaSession&&navigator.mediaSession.metadata;var a=d&&d.artwork&&d.artwork.length?d.artwork[d.artwork.length-1].src:'';return [(d&&d.title)||document.title,(d&&d.artist)||location.hostname,a,m[0].currentTime,m[0].duration].join('|||');})()"#
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
                if p.count >= 7 {
                    self.pos = Store.num(p[5]); self.posAt = Date()
                    let d = Store.num(p[6]); self.dur = d.isFinite ? d : 0   // live streams report Infinity
                }
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
        if cmd.hasPrefix("seek:") {
            js = "var l=[].slice.call(document.querySelectorAll('video,audio'));var e=l.filter(function(x){return !x.paused})[0]||l[0];if(e){e.currentTime=\(cmd.dropFirst(5));};"
            osa("tell application \"Safari\" to do JavaScript \"\(js)\" in tab \(safT) of window \(safW)")
            return
        }
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
    var shown: Date
    var selected: Date
    var busy: Set<Int>
    var onSelect: (Date) -> Void
    var onShift: (Int) -> Void
    var onToday: () -> Void

    func navBtn(_ n: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: n).font(.system(size: 9, weight: .bold)).frame(width: 22, height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var body: some View {
        let cal = Calendar.current, today = Date()
        let first = cal.dateInterval(of: .month, for: shown)?.start ?? shown
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let syms = cal.veryShortWeekdaySymbols
        let heads = (0..<7).map { syms[($0 + cal.firstWeekday - 1) % 7] }
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                navBtn("chevron.left") { onShift(-1) }
                Button { onToday() } label: {
                    Text(first, format: .dateTime.month(.abbreviated).year()).font(.caption.bold())
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Back to today")
                navBtn("chevron.right") { onShift(1) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(0..<7, id: \.self) { i in Text(heads[i]).font(.system(size: 9)).foregroundColor(.gray) }
                ForEach(0..<(lead + days), id: \.self) { i in
                    if i < lead { Color.clear.frame(height: 15) }
                    else {
                        let d = i - lead + 1
                        let date = cal.date(byAdding: .day, value: d - 1, to: first) ?? first
                        let isToday = cal.isDate(date, inSameDayAs: today)
                        let isSel = cal.isDate(date, inSameDayAs: selected)
                        Button { onSelect(date) } label: {
                            Text("\(d)").font(.system(size: 10, weight: isSel ? .bold : .regular)).frame(maxWidth: .infinity, minHeight: 15)
                                .background(Circle().fill(isToday ? Color.blue : (isSel ? Color.white.opacity(0.22) : Color.clear)))
                                .overlay(Circle().strokeBorder(isSel && isToday ? Color.white : Color.clear, lineWidth: 1))
                                .overlay(alignment: .bottom) { if busy.contains(d) { Circle().fill(Color.orange).frame(width: 3, height: 3) } }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
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
struct SettingsView: View {
    @AppStorage("accent") var accent = "green"
    @AppStorage("dateColor") var dateColor = "white"
    @AppStorage("fontDesign") var fd = "default"
    @AppStorage("corner") var corner = 24.0
    @AppStorage("pillExtra") var pillExtra = 92.0
    @AppStorage("updAutoInstall") var autoInstall = false
    @ObservedObject var hk = Hotkeys.shared
    @ObservedObject var rec = HotkeyRecorder.shared
    @ObservedObject var upd = Updater.shared

    func swatches(_ b: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(colorNames, id: \.self) { n in
                Circle().fill(presetColor(n)).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: b.wrappedValue == n ? 2.5 : 0))
                    .onTapGesture { b.wrappedValue = n }
            }
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(.gray)
            content()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func pill(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.white.opacity(0.12)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    func hotkeyRow(_ a: HKAction) -> some View {
        let isRec = rec.recording == a
        let combo = hk.combo(a)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(size: 12, weight: .medium))
                Text(a.detail).font(.system(size: 10)).foregroundColor(.gray)
            }
            Spacer(minLength: 0)
            Button { if isRec { rec.stop() } else { rec.start(a) } } label: {
                Text(isRec ? "Press keys..." : HK.text(combo))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 86).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isRec ? presetColor(accent).opacity(0.35) : Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            btn("arrow.counterclockwise") { rec.stop(); hk.reset(a) }.help("Back to the default")
            btn("xmark") { rec.stop(); hk.set(a, nil) }.help("Turn this hotkey off")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section("Appearance") {
                    HStack { Text("Accent").frame(width: 70, alignment: .leading); swatches($accent) }
                    HStack { Text("Clock").frame(width: 70, alignment: .leading); swatches($dateColor) }
                    HStack {
                        Text("Font").frame(width: 70, alignment: .leading)
                        Picker("", selection: $fd) { ForEach(["default", "rounded", "serif", "monospaced"], id: \.self) { Text($0.capitalized).tag($0) } }
                            .pickerStyle(.segmented).frame(width: 320)
                    }
                    HStack { Text("Corners").frame(width: 70, alignment: .leading); Slider(value: $corner, in: 6...40).frame(width: 320) }
                    HStack { Text("Pill width").frame(width: 70, alignment: .leading); Slider(value: $pillExtra, in: 40...170).frame(width: 320); Text("\(Int(pillExtra))").font(.caption).foregroundColor(.gray) }
                }
                section("Tabs") {
                    HStack {
                        Text("Hide and reorder the tabs along the top").font(.system(size: 12))
                        Spacer()
                        pill("Customise tabs...") { TabPrefs.shared.editing = true }
                    }
                }
                section("Updates") {
                    HStack {
                        Text("When a new version is found").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $autoInstall) {
                            Text("Ask me first").tag(false)
                            Text("Update automatically").tag(true)
                        }.pickerStyle(.segmented).frame(width: 290)
                    }
                    HStack {
                        Text(autoInstall ? "NOTCH downloads, rebuilds and restarts itself as soon as a new release is posted."
                                         : "You'll see a red dot on the Updates tab and an Install button. NOTCH checks on launch and every 3 hours.")
                            .font(.system(size: 10)).foregroundColor(.gray)
                        Spacer(minLength: 0)
                        pill("Check now") { upd.check() }
                    }
                }
                section("Hotkeys") {
                    ForEach(HKAction.allCases, id: \.self) { hotkeyRow($0) }
                    Text(rec.message.isEmpty
                         ? "Click a key box, then press the keys you want. Hotkeys must use Control + Option together so they never clash with ⌘ shortcuts (like ⌘⇧4 or ⌘Space) or with typing. Esc cancels."
                         : rec.message)
                        .font(.system(size: 10)).foregroundColor(rec.message.isEmpty ? .gray : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
        }
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
