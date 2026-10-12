import Combine
import SwiftUI
import AppKit
import CoreWLAN
import IOBluetooth
import CoreGraphics
import Darwin

// MARK: Battery icon (fill level matches the percentage)
//   white = normal, green = charging, yellow = Low Power Mode, red = under 20%
func batteryTint(_ level: Int, _ charging: Bool, _ lowPower: Bool) -> Color {
    if charging { return .green }
    if level >= 0 && level < 20 { return .red }
    if lowPower { return .yellow }
    return .white
}

struct BatteryIcon: View {
    var level: Int
    var charging: Bool
    var lowPower: Bool
    var scale: CGFloat = 1

    var body: some View {
        let w = 24 * scale, h = 12 * scale
        let pct = CGFloat(max(0, min(100, level))) / 100
        let tint = batteryTint(level, charging, lowPower)
        HStack(spacing: 1 * scale) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5 * scale).stroke(Color.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2 * scale).fill(tint)
                    .frame(width: max(2 * scale, (w - 4 * scale) * pct), height: h - 4 * scale)
                    .padding(.leading, 2 * scale)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 7.5 * scale, weight: .bold)).foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.7), radius: 1).frame(width: w)
                }
            }.frame(width: w, height: h)
            Capsule().fill(Color.white.opacity(0.45)).frame(width: 2 * scale, height: 4.5 * scale)
        }
    }
}

// MARK: Display brightness (the same private call System Settings uses; built-in display only)
enum Bright {
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func get() -> Double? {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        let f = unsafeBitCast(sym, to: GetFn.self)
        var v: Float = 0
        return f(CGMainDisplayID(), &v) == 0 ? Double(v) : nil
    }
    static func set(_ v: Double) {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return }
        let f = unsafeBitCast(sym, to: SetFn.self)
        _ = f(CGMainDisplayID(), Float(min(1, max(0, v))))
    }
}

struct BTDev: Identifiable {
    let id: String
    let name: String
    var connected: Bool

    var icon: String {
        let n = name.lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("buds") || n.contains("headphone") || n.contains("headset") || n.contains("beats") || n.hasPrefix("wh-") || n.hasPrefix("wf-") { return "headphones" }
        if n.contains("mouse") { return "computermouse.fill" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if n.contains("speaker") || n.contains("homepod") || n.contains("soundbar") || n.contains("jbl") || n.contains("bose") { return "hifispeaker.fill" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("dualshock") || n.contains("xbox") || n.contains("joy-con") { return "gamecontroller.fill" }
        if n.contains("watch") { return "applewatch" }
        return "dot.radiowaves.right"
    }
}

// MARK: Night Shift and keyboard backlight (private CoreBrightness calls; if macOS changes them the controls just grey out)
enum CoreBright {
    static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil

    // Night Shift
    static let blue: NSObject? = {
        guard CoreBright.loaded, let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()
    typealias BlueSet = @convention(c) (AnyObject, Selector, Bool) -> Bool
    typealias BlueGet = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

    static func nightShift() -> Bool? {
        guard let c = blue else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard c.responds(to: sel) else { return nil }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
        memset(buf, 0, 256)
        defer { buf.deallocate() }
        let f = unsafeBitCast(c.method(for: sel), to: BlueGet.self)
        guard f(c, sel, buf) else { return nil }
        return buf.load(fromByteOffset: 0, as: UInt8.self) != 0 || buf.load(fromByteOffset: 1, as: UInt8.self) != 0
    }

    static func setNightShift(_ on: Bool) -> Bool {
        guard let c = blue else { return false }
        let sel = NSSelectorFromString("setEnabled:")
        guard c.responds(to: sel) else { return false }
        let f = unsafeBitCast(c.method(for: sel), to: BlueSet.self)
        return f(c, sel, on)
    }

    // Keyboard backlight
    static let kbd: NSObject? = {
        guard CoreBright.loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()
    typealias KGet = @convention(c) (AnyObject, Selector, UInt64) -> Float
    typealias KSet = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    static func keyboard() -> Double? {
        guard let c = kbd else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard c.responds(to: sel) else { return nil }
        let v = unsafeBitCast(c.method(for: sel), to: KGet.self)(c, sel, 1)
        return v.isFinite && v >= 0 ? Double(min(1, v)) : nil
    }

    static func setKeyboard(_ v: Double) {
        guard let c = kbd else { return }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard c.responds(to: sel) else { return }
        _ = unsafeBitCast(c.method(for: sel), to: KSet.self)(c, sel, Float(min(1, max(0, v))), 1)
    }
}

// MARK: model
final class ControlModel: ObservableObject {
    @Published var wifiOn = false
    @Published var ssid = ""
    @Published var devices: [BTDev] = []
    @Published var btBusy: Set<String> = []
    @Published var showBT = false
    @Published var lpNote = ""
    @Published var night: Bool? = nil           // nil = not available on this Mac / macOS
    @Published var kbdLevel = 0.5
    @Published var hasKbd = false
    @Published var dark = false
    @Published var brightness = 0.5
    @Published var hasBrightness = false
    @Published var volume = 0.5
    @Published var muted = false
    var editing = false                       // a slider is being dragged: don't fight it
    let q = DispatchQueue(label: "notch.control")

    /// Every Bluetooth device this Mac has paired with, connected ones first.
    static func pairedDevices() -> [BTDev] {
        let list = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return list.compactMap { d -> BTDev? in
            guard let n = d.name, !n.isEmpty, let a = d.addressString else { return nil }
            return BTDev(id: a, name: n, connected: d.isConnected())
        }.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
    }

    var connectedName: String? { devices.first { $0.connected }?.name }

    /// Connects the device if it is off, disconnects it if it is on.
    func toggleDevice(_ dev: BTDev) {
        guard !btBusy.contains(dev.id) else { return }
        btBusy.insert(dev.id)
        q.async {
            let d = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { $0.addressString == dev.id }
            if let d = d {
                if d.isConnected() { _ = d.closeConnection() } else { _ = d.openConnection() }
            }
            let fresh = ControlModel.pairedDevices()
            DispatchQueue.main.async { self.devices = fresh; self.btBusy.remove(dev.id) }
        }
    }

    func refresh() {
        if editing { return }
        q.async {
            let iface = CWWiFiClient.shared().interface()
            let w = iface?.powerOn() ?? false
            let n = (w ? iface?.ssid() : nil) ?? ""
            let b = Bright.get()
            let ns = CoreBright.nightShift()
            let kb = CoreBright.keyboard()
            let v = osa("output volume of (get volume settings)")?.int32Value
            let m = osa("output muted of (get volume settings)")?.booleanValue
            let devs = ControlModel.pairedDevices()
            let dk = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            DispatchQueue.main.async {
                if self.editing { return }
                self.wifiOn = w; self.ssid = n; self.dark = dk; self.devices = devs
                if let b = b { self.brightness = b; self.hasBrightness = true } else { self.hasBrightness = false }
                self.night = ns
                if let k = kb { self.kbdLevel = k; self.hasKbd = true } else { self.hasKbd = false }
                if let v = v { self.volume = Double(v) / 100 }
                if let m = m { self.muted = m }
            }
        }
    }

    func toggleWifi() {
        let want = !wifiOn
        wifiOn = want
        if !want { ssid = "" }
        q.async {
            try? CWWiFiClient.shared().interface()?.setPower(want)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
        }
    }

    func toggleDark() {
        dark.toggle()
        q.async { osa("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") }
    }

    func setVolume(_ v: Double) {
        volume = v
        let n = Int((v * 100).rounded())
        if n > 0 { muted = false }
        q.async { osa("set volume output volume \(n)" + (n > 0 ? "\nset volume without output muted" : "")) }
    }

    func toggleMute() {
        muted.toggle()
        let m = muted
        q.async { osa("set volume " + (m ? "with" : "without") + " output muted") }
    }

    func setBrightness(_ v: Double) {
        brightness = v
        Bright.set(v)
    }

    // MARK: Low Power Mode without a password prompt
    // macOS only lets an administrator change it. NOTCH asks for your password ONCE to install a rule that lets
    // your user run exactly "pmset -a lowpowermode 0" and "... 1" without a password. After that it is instant.
    // Everything it does is written to ~/Library/Application Support/NOTCH/lowpower.log.

    static func lpLog(_ t: String) {
        let f = Updater.support.appendingPathComponent("lowpower.log")
        let line = "[\(Date())] \(t)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }

    /// Runs pmset through sudo with no password and no terminal. needsRule = sudo refused because no rule exists yet.
    static func sudoPmset(_ v: String) -> (ran: Bool, needsRule: Bool, err: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", v]
        let pipe = Pipe(); p.standardOutput = FileHandle.nullDevice; p.standardError = pipe
        do { try p.run() } catch { return (false, false, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let err = (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let low = err.lowercased()
        let refused = low.contains("password") || low.contains("terminal") || low.contains("not allowed") || low.contains("may not run") || low.contains("not in the sudoers")
        lpLog("sudo pmset lowpowermode \(v): exit \(p.terminationStatus) \(err)")
        return (p.terminationStatus == 0 || !refused, p.terminationStatus != 0 && refused, err)
    }

    /// One-time setup. Returns nil on success or the reason it failed.
    static func installLowPowerRule() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return "unsupported account name" }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
        let sh = "mkdir -p /etc/sudoers.d && echo '\(rule)' > /tmp/notch-lp && /usr/sbin/chown root:wheel /tmp/notch-lp && /bin/chmod 440 /tmp/notch-lp && /usr/sbin/visudo -cf /tmp/notch-lp && /bin/mv -f /tmp/notch-lp /etc/sudoers.d/notch-lowpower"
        DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
        var e: NSDictionary?
        _ = NSAppleScript(source: "do shell script \"\(sh)\" with administrator privileges")?.executeAndReturnError(&e)
        if let e = e {
            let msg = (e[NSAppleScript.errorMessage] as? String) ?? "setup failed"
            lpLog("install failed: \(msg)")
            return msg
        }
        lpLog("install ok for user \(user)")
        return nil
    }

    func lpSay(_ t: String) {
        DispatchQueue.main.async {
            self.lpNote = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.lpNote == t { self.lpNote = "" } }
        }
    }

    func setLowPower(_ on: Bool) {
        let v = on ? "1" : "0"
        q.async {
            var r = ControlModel.sudoPmset(v)
            if r.needsRule {                                   // first time only: one password prompt
                if let why = ControlModel.installLowPowerRule() {
                    if !why.lowercased().contains("cancel") { self.lpSay("Setup failed") }
                    return
                }
                r = ControlModel.sudoPmset(v)
                if r.needsRule { self.lpSay("Setup didn't apply"); return }
            }
            // confirm it really changed (give macOS a moment to report it)
            for _ in 0..<8 {
                if ProcessInfo.processInfo.isLowPowerModeEnabled == on { return }
                Thread.sleep(forTimeInterval: 0.25)
            }
            ControlModel.lpLog("state did not change to \(v): \(r.err)")
            self.lpSay("Couldn't change it")
        }
    }

    func setKeyboard(_ v: Double) {
        kbdLevel = v
        CoreBright.setKeyboard(v)
    }

    func toggleNight() {
        guard let on = night else {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(u) }
            return
        }
        night = !on
        q.async {
            _ = CoreBright.setNightShift(!on)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
        }
    }

    /// Drag-select a screenshot. It's saved on the Desktop like the normal macOS one and also dropped onto your Shelf.
    func screenshot() {
        q.async {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let path = NSHomeDirectory() + "/Desktop/NOTCH Screenshot \(f.string(from: Date())).png"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-i", path]
            do { try p.run() } catch { return }
            p.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                DispatchQueue.main.async {
                    let u = URL(fileURLWithPath: path)
                    if !Store.shared.files.contains(u) { Store.shared.files.append(u) }
                }
            }
        }
    }

    func sleepDisplay() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

// MARK: pieces
struct CCTile: View {
    var icon: String
    var title: String
    var sub: String
    var on: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(on ? tint : Color.white.opacity(0.14))
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                }.frame(width: 30, height: 30)
                Spacer(minLength: 0)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(sub).font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct CCSlider: View {
    var icon: String
    @Binding var value: Double
    var enabled: Bool = true
    var onIcon: (() -> Void)? = nil
    var onEditing: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { onIcon?() } label: {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Slider(value: $value, in: 0...1, onEditingChanged: onEditing).disabled(!enabled)
            Text(enabled ? "\(Int((value * 100).rounded()))%" : "--")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: tab
struct ControlCentreView: View {
    @EnvironmentObject var s: Store
    @StateObject var cm = ControlModel()

    var volumeIcon: String {
        if cm.muted || cm.volume <= 0.001 { return "speaker.slash.fill" }
        if cm.volume < 0.34 { return "speaker.wave.1.fill" }
        if cm.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var batteryStatus: String {
        if s.battery < 0 { return "No battery" }
        if s.charging { return "Charging" }
        if s.battery < 20 { return "Low battery" }
        if s.lowPower { return "Low Power Mode" }
        return "On battery"
    }

    var tiles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                CCTile(icon: cm.wifiOn ? "wifi" : "wifi.slash", title: "Wi-Fi",
                       sub: cm.wifiOn ? (cm.ssid.isEmpty ? "On" : cm.ssid) : "Off",
                       on: cm.wifiOn, tint: .blue) { cm.toggleWifi() }
                CCTile(icon: "headphones", title: "Bluetooth", sub: cm.connectedName ?? "Choose a device",
                       on: cm.connectedName != nil, tint: .blue) { cm.showBT = true }
                CCTile(icon: "circle.lefthalf.filled", title: "Dark Mode", sub: cm.dark ? "On" : "Off",
                       on: cm.dark, tint: .indigo) { cm.toggleDark() }
            }
            HStack(spacing: 8) {
                CCTile(icon: "sun.haze.fill", title: "Night Shift", sub: cm.night == nil ? "Unavailable" : (cm.night! ? "On" : "Off"),
                       on: cm.night ?? false, tint: .orange) { cm.toggleNight() }
                CCTile(icon: "leaf.fill", title: "Low Power", sub: cm.lpNote.isEmpty ? (s.lowPower ? "On" : "Off") : cm.lpNote,
                       on: s.lowPower, tint: .yellow) { cm.setLowPower(!s.lowPower) }
                CCTile(icon: "gearshape.fill", title: "Settings", sub: "System Settings",
                       on: false, tint: .gray) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
            HStack(spacing: 8) {
                CCTile(icon: "camera.viewfinder", title: "Screenshot", sub: "Select an area",
                       on: false, tint: .gray) { cm.screenshot() }
                CCTile(icon: "display", title: "Sleep Display", sub: "Tap to sleep",
                       on: false, tint: .gray) { cm.sleepDisplay() }
            }
        }
    }

    func deviceRow(_ d: BTDev) -> some View {
        let busy = cm.btBusy.contains(d.id)
        let status = busy ? (d.connected ? "Disconnecting..." : "Connecting...") : (d.connected ? "Connected" : "Not connected")
        return Button { cm.toggleDevice(d) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(d.connected ? Color.blue : Color.white.opacity(0.14))
                    Image(systemName: d.icon).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                }.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(status).font(.system(size: 10)).foregroundColor(d.connected && !busy ? Color.blue : Color.gray)
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                else if d.connected { Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var btPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Button { cm.showBT = false } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Bluetooth").font(.system(size: 13, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Text("Tap to connect or disconnect").font(.system(size: 10)).foregroundColor(.gray)
            }
            ScrollView {
                VStack(spacing: 5) {
                    if cm.devices.isEmpty {
                        Text("No paired devices. Pair one in System Settings > Bluetooth and it will show up here.")
                            .font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center)
                            .padding(.top, 14).padding(.horizontal, 10)
                    }
                    ForEach(cm.devices) { d in deviceRow(d) }
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group { if cm.showBT { btPanel } else { tiles } }.frame(width: 322)

            VStack(spacing: 8) {
                CCSlider(icon: "sun.max.fill",
                         value: Binding(get: { cm.brightness }, set: { cm.setBrightness($0) }),
                         enabled: cm.hasBrightness, onEditing: { cm.editing = $0 })
                CCSlider(icon: "keyboard",
                         value: Binding(get: { cm.kbdLevel }, set: { cm.setKeyboard($0) }),
                         enabled: cm.hasKbd, onEditing: { cm.editing = $0 })
                CCSlider(icon: volumeIcon,
                         value: Binding(get: { cm.muted ? 0 : cm.volume }, set: { cm.setVolume($0) }),
                         onIcon: { cm.toggleMute() }, onEditing: { cm.editing = $0 })
                HStack(spacing: 10) {
                    BatteryIcon(level: s.battery, charging: s.charging, lowPower: s.lowPower, scale: 1.25)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.battery < 0 ? "--" : "\(s.battery)%").font(.system(size: 13, weight: .semibold))
                        Text(batteryStatus).font(.system(size: 10)).foregroundColor(.gray)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }.frame(maxWidth: .infinity)
        }
        .onAppear { cm.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in cm.refresh() }
    }
}
