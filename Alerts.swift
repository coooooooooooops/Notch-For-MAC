import SwiftUI
import AppKit
import CoreAudio
import IOBluetooth

// MARK: Stage 2: system HUDs and alerts that pop up in the live pill.
// Volume, display brightness, keyboard backlight, plug / unplug, low battery, full battery, Bluetooth connect / disconnect.
// macOS still shows its own volume and brightness pop-up as well; this adds a copy of it next to the notch.

enum SysAudio {
    static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (st == noErr && id != 0) ? id : nil
    }

    /// Output volume 0...1 and whether it is muted. nil if the current output has no software volume (some HDMI outputs).
    static func volume() -> (level: Double, muted: Bool)? {
        guard let dev = device() else { return nil }
        var vals: [Double] = []
        for el in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { vals.append(Double(v)) }
            if el == kAudioObjectPropertyElementMain, !vals.isEmpty { break }
        }
        guard !vals.isEmpty else { return nil }
        var muted: UInt32 = 0
        var msize = UInt32(MemoryLayout<UInt32>.size)
        var maddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                               mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &maddr) { _ = AudioObjectGetPropertyData(dev, &maddr, 0, nil, &msize, &muted) }
        return (vals.reduce(0, +) / Double(vals.count), muted != 0)
    }
}

enum HUDKind {
    case volume(Double, Bool)
    case brightness(Double)
    case keyboard(Double)
    case plug(Bool, Int)            // plugged in (true) or unplugged (false), battery %
    case lowBattery(Int)
    case full
    case bluetooth(String, String, Bool)   // name, SF Symbol, connected

    /// What the two ears of the pill show for this HUD.
    var ears: (LeftEar, RightEar) {
        switch self {
        case .volume(let v, let muted):
            let off = muted || v <= 0.001
            let icon = off ? "speaker.slash.fill" : (v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
            return (.sf(icon, "white"), .level(off ? 0 : v, "white"))
        case .brightness(let v):
            return (.sf("sun.max.fill", "yellow"), .level(v, "yellow"))
        case .keyboard(let v):
            return (.sf("light.max", "orange"), .level(v, "orange"))
        case .plug(let on, let pct):
            return (.sf(on ? "bolt.fill" : "bolt.slash.fill", on ? "green" : "white"), .text("\(pct)%"))
        case .lowBattery(let pct):
            return (.sf(pct <= 10 ? "battery.0percent" : "battery.25percent", pct <= 10 ? "red" : "orange"), .text("\(pct)%"))
        case .full:
            return (.sf("bolt.fill", "green"), .text("Full"))
        case .bluetooth(let name, let icon, let on):
            return (.sf(icon, on ? "cyan" : "white"), .text(String(name.prefix(9))))
        }
    }
}

final class AlertCenter {
    static let shared = AlertCenter()
    private(set) var hud: HUDKind?
    private(set) var hudUntil = Date.distantPast

    private var lastVol: Double?, lastMute: Bool?, lastBright: Double?, lastKbd: Double?
    private var lastCharging: Bool?
    private var warned = Set<Int>()
    private var btState: [String: Bool]?
    private let q = DispatchQueue(label: "notch.alerts")
    private var timer: Timer?
    private var n = 0

    func start() {
        let d = UserDefaults.standard
        d.register(defaults: ["hudVolume": true, "hudBrightness": true, "hudPower": true, "hudBluetooth": true])
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// The HUD that should be showing right now, if any.
    func current() -> HUDKind? { Date() < hudUntil ? hud : nil }

    func post(_ k: HUDKind, for secs: Double) {
        hud = k
        hudUntil = Date().addingTimeInterval(secs)
    }

    private func moved(_ new: Double, _ old: inout Double?, _ eps: Double) -> Bool {
        defer { old = new }
        guard let o = old else { return false }
        return abs(new - o) > eps
    }

    private func poll() {
        n += 1
        let d = UserDefaults.standard
        if d.bool(forKey: "hudPower") { checkPower(Store.shared) }
        let wantVol = d.bool(forKey: "hudVolume"), wantBright = d.bool(forKey: "hudBrightness")
        let wantBT = d.bool(forKey: "hudBluetooth") && n % 9 == 0      // about every 3 seconds
        guard wantVol || wantBright || wantBT else { return }
        q.async { [weak self] in
            var vol: (level: Double, muted: Bool)?
            var br: Double?, kb: Double?
            var bt: [BTDev]?
            if wantVol { vol = SysAudio.volume() }
            if wantBright { br = Bright.get(); kb = CoreBright.keyboard() }
            if wantBT { bt = ControlModel.pairedDevices() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let v = vol {
                    let muteChanged = self.lastMute != nil && self.lastMute != v.muted
                    self.lastMute = v.muted
                    if self.moved(v.level, &self.lastVol, 0.01) || muteChanged { self.post(.volume(v.level, v.muted), for: 1.6) }
                }
                if let b = br, self.moved(b, &self.lastBright, 0.03) { self.post(.brightness(b), for: 1.6) }
                if let k = kb, self.moved(k, &self.lastKbd, 0.03) { self.post(.keyboard(k), for: 1.6) }
                if let devs = bt { self.checkBluetooth(devs) }
            }
        }
    }

    private func checkPower(_ s: Store) {
        guard s.battery >= 0 else { return }
        if let was = lastCharging, was != s.charging { post(.plug(s.charging, s.battery), for: 3) }
        lastCharging = s.charging
        if s.charging || s.battery > 20 { warned = warned.filter { $0 == 100 } }
        if !s.charging {
            for t in [20, 10, 5] where s.battery <= t && !warned.contains(t) {
                warned.insert(t)
                post(.lowBattery(s.battery), for: 4)
                break
            }
        }
        if s.charging && s.battery >= 100 && !warned.contains(100) { warned.insert(100); post(.full, for: 3) }
        if s.battery < 95 { warned.remove(100) }
    }

    private func checkBluetooth(_ devs: [BTDev]) {
        var now: [String: Bool] = [:]
        for d in devs { now[d.id] = d.connected }
        defer { btState = now }
        guard let old = btState else { return }
        for d in devs where old[d.id] != nil && old[d.id] != d.connected {
            post(.bluetooth(d.name, d.icon, d.connected), for: 3)
            break
        }
    }
}
