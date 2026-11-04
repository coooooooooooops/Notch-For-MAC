import SwiftUI
import AppKit
import EventKit
import IOKit.pwr_mgt
import ApplicationServices

// MARK: Stage 4: four new tabs.
//   Quick Actions: run Shortcuts, stay awake, mute the mic, join the next meeting, snap windows.
//   To-do: task list plus focus-session stats from the Timers tab.
//   Terminal and Teleprompter are hidden until you switch them on in Customise tabs.
// (Everything here uses ObservableObject rather than @State, because Command Line Tools builds can't use @State.)

let quickTab = 16, todoTab = 17, termTab = 18, prompterTab = 19

// MARK: running programs without freezing the notch
enum Sh {
    static func output(_ exe: String, _ args: [String], timeout: Double = 20, cwd: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        do { try p.run() } catch { return "Could not start: \(error.localizedDescription)\n" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        var s = String(data: data, encoding: .utf8) ?? ""
        if s.count > 20000 { s = String(s.suffix(20000)) }
        return s
    }
}

// MARK: Shortcuts
final class QuickModel: ObservableObject {
    static let shared = QuickModel()
    @Published var shortcuts: [String] = []
    @Published var loading = false

    func load() {
        if loading { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let out = Sh.output("/usr/bin/shortcuts", ["list"], timeout: 10)
            let names = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.async { self.shortcuts = names; self.loading = false }
        }
    }

    func run(_ name: String) {
        Store.shared.say("Running \(name)...", hold: 30)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Sh.output("/usr/bin/shortcuts", ["run", name], timeout: 120)
            DispatchQueue.main.async { Store.shared.say("Ran \(name)") }
        }
    }
}

// MARK: Stay awake
final class Awake: ObservableObject {
    static let shared = Awake()
    @Published var on = false
    private var id = IOPMAssertionID(0)

    func set(_ v: Bool) {
        if v == on { return }
        if v {
            let r = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "NOTCH stay awake" as CFString, &id)
            on = (r == kIOReturnSuccess)
        } else {
            IOPMAssertionRelease(id)
            id = IOPMAssertionID(0)
            on = false
        }
        Store.shared.say(on ? "Mac will stay awake" : "Back to normal sleep")
    }
}

// MARK: Mute the microphone (sets the input volume to 0 and remembers the old level)
final class MicMute: ObservableObject {
    static let shared = MicMute()
    @Published var muted = false
    private var saved = 70

    private func level() -> Int { Int(osa("input volume of (get volume settings)")?.int32Value ?? 50) }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let v = self.level()
            DispatchQueue.main.async { self.muted = (v == 0); if v > 0 { self.saved = v } }
        }
    }

    func toggle() {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = self.level()
            if v == 0 { osa("set volume input volume \(max(self.saved, 30))") } else { self.saved = v; osa("set volume input volume 0") }
            let nv = self.level()
            DispatchQueue.main.async { self.muted = (nv == 0); Store.shared.say(nv == 0 ? "Mic muted" : "Mic on") }
        }
    }
}

// MARK: Join the next meeting (looks for a Zoom / Meet / Teams / Webex link in your calendar)
enum Meeting {
    static func isMeeting(_ u: URL) -> Bool {
        let h = (u.host ?? "").lowercased()
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com"]
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func joinNext() {
        Store.shared.say("Looking for a meeting...", hold: 10)
        DispatchQueue.global(qos: .userInitiated).async {
            let store = EKEventStore()
            let now = Date()
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(8 * 3600), calendars: nil)
            let events = store.events(matching: pred).filter { !$0.isAllDay && $0.endDate > now }.sorted { $0.startDate < $1.startDate }
            let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            var found: (URL, String)?
            outer: for e in events {
                var texts = [e.location ?? "", e.notes ?? ""]
                if let u = e.url?.absoluteString { texts.insert(u, at: 0) }
                for t in texts {
                    let ns = t as NSString
                    for m in det?.matches(in: t, range: NSRange(location: 0, length: ns.length)) ?? [] {
                        if let u = m.url, isMeeting(u) { found = (u, e.title ?? "meeting"); break outer }
                    }
                }
            }
            DispatchQueue.main.async {
                if let f = found {
                    NSWorkspace.shared.open(f.0)
                    Store.shared.say("Joining \(f.1)")
                } else {
                    Store.shared.say("No meeting link in the next 8 hours (is Calendar allowed?)", hold: 4)
                }
            }
        }
    }
}

// MARK: Window snapping (needs Accessibility permission, macOS asks the first time)
enum WindowSnap {
    enum Spot { case left, right, top, bottom, full, center }

    static func snap(_ spot: Spot) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            Store.shared.say("Allow NOTCH in Privacy & Security > Accessibility, then try again", hold: 4)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            Store.shared.say("Click the window you want to move first", hold: 3)
            return
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var wref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &wref) == .success, let w = wref else {
            Store.shared.say("No window to move", hold: 3)
            return
        }
        let win = w as! AXUIElement
        var pv: CFTypeRef?, sv: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pv)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sv)
        var pt = CGPoint.zero, sz = CGSize.zero
        if let pv = pv { AXValueGetValue(pv as! AXValue, .cgPoint, &pt) }
        if let sv = sv { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }

        // Accessibility uses top-left coordinates, AppKit bottom-left; convert via the primary screen's height.
        let primaryH = NSScreen.screens[0].frame.height
        let center = CGPoint(x: pt.x + sz.width / 2, y: primaryH - (pt.y + sz.height / 2))
        let scr = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = scr.visibleFrame
        var t = v
        switch spot {
        case .left: t = CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right: t = CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .top: t = CGRect(x: v.minX, y: v.midY, width: v.width, height: v.height / 2)
        case .bottom: t = CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height / 2)
        case .full: t = v
        case .center:
            let cw = v.width * 0.6, ch = v.height * 0.7
            t = CGRect(x: v.midX - cw / 2, y: v.midY - ch / 2, width: cw, height: ch)
        }
        var np = CGPoint(x: t.minX, y: primaryH - t.maxY)
        var ns = CGSize(width: t.width, height: t.height)
        if let a = AXValueCreate(.cgPoint, &np) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, a) }
        if let b = AXValueCreate(.cgSize, &ns) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, b) }
        if let a = AXValueCreate(.cgPoint, &np) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, a) }
    }
}

// MARK: Quick Actions tab
struct QuickActionsView: View {
    @ObservedObject var q = QuickModel.shared
    @ObservedObject var awake = Awake.shared
    @ObservedObject var mic = MicMute.shared
    @AppStorage("accent") var accent = "green"

    func tile(_ icon: String, _ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .modifier(GlassIf(shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                              tint: on ? presetColor(accent).opacity(0.6) : nil, interactive: true,
                              classic: on ? presetColor(accent).opacity(0.35) : Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    func snapButton(_ icon: String, _ spot: WindowSnap.Spot) -> some View {
        Button { WindowSnap.snap(spot) } label: {
            Image(systemName: icon).font(.system(size: 15))
                .frame(maxWidth: .infinity, minHeight: 32)
                .modifier(GlassIf(shape: RoundedRectangle(cornerRadius: 9, style: .continuous), tint: nil, interactive: true, classic: Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts").font(.caption).foregroundColor(.gray)
                if q.shortcuts.isEmpty {
                    Text(q.loading ? "Loading..." : "No Shortcuts found. Make some in the Shortcuts app and they show up here.")
                        .font(.caption).foregroundColor(.gray)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(q.shortcuts, id: \.self) { n in
                            Button { q.run(n) } label: {
                                Text(n).font(.system(size: 11)).lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    tile("cup.and.saucer.fill", "Stay awake", on: awake.on) { awake.set(!awake.on) }
                    tile(mic.muted ? "mic.slash.fill" : "mic.fill", mic.muted ? "Mic muted" : "Mute mic", on: mic.muted) { mic.toggle() }
                    tile("video.fill", "Join meeting") { Meeting.joinNext() }
                }
                Text("Snap the front window").font(.caption).foregroundColor(.gray).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    snapButton("rectangle.lefthalf.filled", .left)
                    snapButton("rectangle.righthalf.filled", .right)
                    snapButton("rectangle.tophalf.filled", .top)
                    snapButton("rectangle.bottomhalf.filled", .bottom)
                    snapButton("rectangle.fill", .full)
                    snapButton("rectangle.center.inset.filled", .center)
                }
            }.frame(width: 320)
        }
        .onAppear { q.load(); mic.refresh() }
    }
}

// MARK: To-do + focus stats
struct TodoItem: Codable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

final class TodoModel: ObservableObject {
    static let shared = TodoModel()
    @Published var items: [TodoItem] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "todos"), let a = try? JSONDecoder().decode([TodoItem].self, from: d) {
            items = a
        } else {
            items = []
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "todos") }
    }
}

final class TodoDraft: ObservableObject {
    @Published var text = ""
}

struct PomoDay {
    let label: String
    let count: Int
    let mins: Int
}

enum PomoStats {
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Called by the timer each time a focus session finishes.
    static func record(_ mins: Int) {
        let d = UserDefaults.standard
        var m = (d.dictionary(forKey: "pomoMins") as? [String: Int]) ?? [:]
        var n = (d.dictionary(forKey: "pomoCount") as? [String: Int]) ?? [:]
        let k = df.string(from: Date())
        m[k, default: 0] += mins
        n[k, default: 0] += 1
        d.set(m, forKey: "pomoMins")
        d.set(n, forKey: "pomoCount")
    }

    static func last7() -> [PomoDay] {
        let d = UserDefaults.standard
        let m = (d.dictionary(forKey: "pomoMins") as? [String: Int]) ?? [:]
        let n = (d.dictionary(forKey: "pomoCount") as? [String: Int]) ?? [:]
        let cal = Calendar.current
        let lf = DateFormatter()
        lf.dateFormat = "EEEEE"
        return (0..<7).reversed().map { i -> PomoDay in
            let day = cal.date(byAdding: .day, value: -i, to: Date()) ?? Date()
            let k = df.string(from: day)
            return PomoDay(label: lf.string(from: day), count: n[k] ?? 0, mins: m[k] ?? 0)
        }
    }

    /// Days in a row with at least one finished focus session (today not being done yet does not break it).
    static func streak() -> Int {
        let n = (UserDefaults.standard.dictionary(forKey: "pomoCount") as? [String: Int]) ?? [:]
        let cal = Calendar.current
        var day = Date()
        if (n[df.string(from: day)] ?? 0) == 0 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var s = 0
        while (n[df.string(from: day)] ?? 0) > 0 && s < 3650 {
            s += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return s
    }
}

struct TodoView: View {
    @ObservedObject var m = TodoModel.shared
    @StateObject var draft = TodoDraft()
    @EnvironmentObject var s: Store
    @AppStorage("accent") var accent = "green"

    func add() {
        let t = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        m.items.insert(TodoItem(text: t), at: 0)
        draft.text = ""
    }

    var body: some View {
        let days = PomoStats.last7()
        let today = days.last ?? PomoDay(label: "", count: 0, mins: 0)
        let peak = max(days.map { $0.mins }.max() ?? 1, 1)
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Add a task", text: $draft.text).textFieldStyle(.plain).onSubmit { add() }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    Button { add() } label: { Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundColor(presetColor(accent)) }
                        .buttonStyle(.plain)
                    if m.items.contains(where: { $0.done }) {
                        Button("Clear done") { m.items.removeAll { $0.done } }.buttonStyle(.plain).font(.caption).foregroundColor(.gray)
                    }
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(m.items) { item in
                            HStack(spacing: 8) {
                                Button {
                                    if let i = m.items.firstIndex(where: { $0.id == item.id }) { m.items[i].done.toggle() }
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(item.done ? presetColor(accent) : Color.gray)
                                }.buttonStyle(.plain)
                                Text(item.text).strikethrough(item.done)
                                    .foregroundColor(item.done ? Color.gray : Color.white).lineLimit(2)
                                Spacer()
                                Button { m.items.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).foregroundColor(.gray)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                        }
                        if m.items.isEmpty { Text("Nothing to do. Enjoy it.").font(.caption).foregroundColor(.gray).padding(.top, 20) }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("Focus").font(.caption).foregroundColor(.gray)
                HStack(spacing: 14) {
                    VStack(alignment: .leading) { Text("\(today.count)").font(.system(size: 22, weight: .semibold)); Text("sessions today").font(.system(size: 9)).foregroundColor(.gray) }
                    VStack(alignment: .leading) { Text("\(today.mins)").font(.system(size: 22, weight: .semibold)); Text("minutes").font(.system(size: 9)).foregroundColor(.gray) }
                    VStack(alignment: .leading) { Text("\(PomoStats.streak())").font(.system(size: 22, weight: .semibold)); Text("day streak").font(.system(size: 9)).foregroundColor(.gray) }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                        VStack(spacing: 3) {
                            Capsule().fill(d.mins > 0 ? presetColor(accent) : Color.white.opacity(0.12))
                                .frame(width: 18, height: max(4, 60 * CGFloat(d.mins) / CGFloat(peak)))
                            Text(d.label).font(.system(size: 9)).foregroundColor(.gray)
                        }
                    }
                }.frame(height: 80, alignment: .bottom)
                Text("Counts every finished focus timer from the Timers tab.").font(.system(size: 9)).foregroundColor(.gray)
            }.frame(width: 240)
        }
    }
}

// MARK: Terminal
final class TermModel: ObservableObject {
    static let shared = TermModel()
    @Published var out = ""
    @Published var cmd = ""
    @Published var busy = false
    @Published var cwd = NSHomeDirectory()

    var prompt: String { cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " $" }

    func run() {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !busy else { return }
        cmd = ""
        if c == "clear" { out = ""; return }
        busy = true
        out += "\(prompt) \(c)\n"
        let dir = cwd
        DispatchQueue.global(qos: .userInitiated).async {
            let marker = "__NOTCH_CWD__"
            let text = Sh.output("/bin/zsh", ["-c", "\(c)\necho \"\(marker)$(pwd)\""], timeout: 30, cwd: dir)
            var shown = text
            var newDir = dir
            if let r = text.range(of: marker, options: .backwards) {
                newDir = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                shown = String(text[..<r.lowerBound])
            }
            DispatchQueue.main.async {
                self.out += shown
                if !shown.isEmpty && !shown.hasSuffix("\n") { self.out += "\n" }
                if !newDir.isEmpty { self.cwd = newDir }
                if self.out.count > 30000 { self.out = String(self.out.suffix(30000)) }
                self.busy = false
            }
        }
    }
}

struct TerminalView: View {
    @ObservedObject var m = TermModel.shared

    var body: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(m.out.isEmpty ? "Type a command and press Return. Runs with zsh in your home folder." : m.out)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(m.out.isEmpty ? Color.gray : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .onChange(of: m.out) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.5)))
            HStack(spacing: 6) {
                Text(m.prompt).font(.system(size: 11, design: .monospaced)).foregroundColor(.green)
                TextField("command", text: $m.cmd).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { m.run() }
                if m.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }
}

// MARK: Teleprompter
final class PrompterModel: ObservableObject {
    static let shared = PrompterModel()
    @Published var running = false
    @Published var offset: CGFloat = 0
    private var timer: Timer?

    func start() {
        stop()
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let sp = UserDefaults.standard.double(forKey: "prompterSpeed")
            self?.offset += CGFloat((sp > 0 ? sp : 30) / 30.0)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    func reset() {
        stop()
        offset = 0
    }
}

struct PrompterView: View {
    @ObservedObject var p = PrompterModel.shared
    @AppStorage("prompterText") var text = "Paste your script here, press Start, and it scrolls at your speed.\n\nKeep your eyes near the camera and read at a steady pace."
    @AppStorage("prompterSpeed") var speed = 30.0
    @AppStorage("prompterSize") var size = 30.0
    @AppStorage("accent") var accent = "green"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button { p.running ? p.stop() : p.start() } label: {
                    Label(p.running ? "Pause" : "Start", systemImage: p.running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Capsule().fill(presetColor(accent).opacity(0.5)))
                }.buttonStyle(.plain)
                Button { p.reset() } label: {
                    Label("Back to start", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain)
                Text("Speed").font(.caption).foregroundColor(.gray)
                Slider(value: $speed, in: 10...120)
                Text("Text size").font(.caption).foregroundColor(.gray)
                Slider(value: $size, in: 18...64)
            }.frame(width: 170)

            Group {
                if !p.running && p.offset == 0 {
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                } else {
                    GeometryReader { g in
                        Text(text)
                            .font(.system(size: CGFloat(size), weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: g.size.width)
                            .offset(y: g.size.height * 0.35 - p.offset)
                    }
                    .clipped()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { p.stop() }
    }
}
