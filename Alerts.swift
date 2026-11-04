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

extension SysAudio {
    /// Sets the output volume (0...1) and the mute switch.
    static func setVolume(_ v: Double, muted: Bool) {
        guard let dev = device() else { return }
        var level = Float32(min(1, max(0, v)))
        for el in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { continue }
            _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
            if el == kAudioObjectPropertyElementMain { break }
        }
        var m: UInt32 = muted ? 1 : 0
        var maddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                               mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &maddr) {
            _ = AudioObjectSetPropertyData(dev, &maddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

/// Optional: catches the keyboard volume keys, handles them itself and so replaces the macOS volume bar with the
/// notch one. Needs the Accessibility permission. Brightness keys are not touched. Off by default.
final class VolumeKeys {
    static let shared = VolumeKeys()
    var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var asked = false

    func sync(_ on: Bool) {
        if on && tap == nil { start() } else if !on && tap != nil { stop() }
    }

    private func start() {
        guard AXIsProcessTrusted() else {
            if !asked {
                asked = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                Store.shared.say("Allow NOTCH under Accessibility to take over the volume keys", hold: 4)
            }
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = VolumeKeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = (ns.data1 & 0xFFFF0000) >> 16
            let down = ((ns.data1 & 0x0000FF00) >> 8) == 0xA
            guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return Unmanaged.passUnretained(event) }
            if down { DispatchQueue.main.async { VolumeKeys.shared.handle(keyCode) } }
            return nil      // swallow it so macOS does not show its own bar
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << 14), callback: callback, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        if let s = source { CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes) }
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    func handle(_ key: Int) {
        guard let cur = SysAudio.volume() else { return }
        var level = cur.level
        var muted = cur.muted
        switch key {
        case 0: level = min(1, level + 1.0 / 16); muted = false
        case 1: level = max(0, level - 1.0 / 16); muted = false
        default: muted.toggle()
        }
        SysAudio.setVolume(level, muted: muted)
        AlertCenter.shared.post(.volume(level, muted), for: 1.6)
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
    private var btPending: [String: Bool] = [:]
    private var lastPlug = Date.distantPast
    private let q = DispatchQueue(label: "notch.alerts")
    private var timer: Timer?
    private var n = 0

    func start() {
        let d = UserDefaults.standard
        d.register(defaults: ["hudVolume": true, "hudBrightness": false, "hudPower": true, "hudBluetooth": true])
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
        VolumeKeys.shared.sync(d.bool(forKey: "replaceVolume"))
        let wantVol = d.bool(forKey: "hudVolume"), wantBright = d.bool(forKey: "hudBrightness")
        let wantBT = d.bool(forKey: "hudBluetooth") && n % 15 == 0      // about every 5 seconds
        guard wantVol || wantBright || wantBT else { return }
        q.async { [weak self] in
            var vol: (level: Double, muted: Bool)?
            var br: Double?
            var bt: [BTDev]?
            if wantVol { vol = SysAudio.volume() }
            if wantBright { br = Bright.get() }
            if wantBT { bt = ControlModel.pairedDevices() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let v = vol {
                    let muteChanged = self.lastMute != nil && self.lastMute != v.muted
                    self.lastMute = v.muted
                    if self.moved(v.level, &self.lastVol, 0.01) || muteChanged { self.post(.volume(v.level, v.muted), for: 1.6) }
                }
                if let b = br, self.moved(b, &self.lastBright, 0.03) { self.post(.brightness(b), for: 1.6) }
                if let devs = bt { self.checkBluetooth(devs) }
            }
        }
    }

    private func checkPower(_ s: Store) {
        guard s.battery >= 0 else { return }
        if let was = lastCharging, was != s.charging, Date().timeIntervalSince(lastPlug) > 10 { lastPlug = Date(); post(.plug(s.charging, s.battery), for: 3) }
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

    /// A device only counts as connected / disconnected once two checks in a row agree, so flickering links stay quiet.
    private func checkBluetooth(_ devs: [BTDev]) {
        guard btState != nil else {
            var first: [String: Bool] = [:]
            for d in devs { first[d.id] = d.connected }
            btState = first
            return
        }
        for d in devs {
            guard let prev = btState?[d.id] else { btState?[d.id] = d.connected; continue }
            if prev == d.connected { btPending[d.id] = nil; continue }
            if btPending[d.id] == d.connected {
                btPending[d.id] = nil
                btState?[d.id] = d.connected
                post(.bluetooth(d.name, d.icon, d.connected), for: 3)
                return
            }
            btPending[d.id] = d.connected
        }
    }
}
