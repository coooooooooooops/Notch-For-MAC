import SwiftUI
import AppKit

// MARK: Bass booster: the switch, the strength, and the Apple Music fallback.
// On macOS 14.2+ the boost applies to everything the Mac plays (see BassEngine.swift). On older macOS, or if the system-wide
// route cannot start, it switches on Apple Music's own "Bass Booster" equaliser preset instead (Apple Music only).

final class BassBoost: ObservableObject {
    static let shared = BassBoost()

    @Published var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "bassOn"); apply() } }
    @Published var level: Double { didSet { UserDefaults.standard.set(level, forKey: "bassLevel"); if on { BassEngine.shared.setGain(gainDb) } } }
    @Published var status = ""
    private var musicEQOn = false

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["bassOn": false, "bassLevel": 0.5])
        on = d.bool(forKey: "bassOn")
        level = d.double(forKey: "bassLevel")
        status = on ? "" : "Off"
    }

    /// 0...1 maps to a +2 to +14 dB shelf below about 120 Hz.
    var gainDb: Double { 2 + min(1, max(0, level)) * 12 }

    var strengthName: String { level < 0.34 ? "Light" : (level < 0.67 ? "Medium" : "Heavy") }

    /// Called once at launch so the setting survives a restart.
    func restore() { if on { apply() } }

    /// Called when the app quits.
    func shutdown() {
        BassEngine.shared.stop()
        setMusicEQ(false)
    }

    func toggle() { on.toggle() }

    private func apply() {
        if !on {
            BassEngine.shared.stop()
            setMusicEQ(false)
            status = "Off"
            return
        }
        if BassEngine.supported, BassEngine.shared.start(gainDb: gainDb) == nil {
            setMusicEQ(false)
            status = "On for everything you play"
            return
        }
        // Not available (older macOS, or the permission was refused): use Apple Music's own preset.
        if Store.shared.isRunning("com.apple.Music") {
            setMusicEQ(true)
            status = "On for Apple Music only"
        } else {
            status = BassEngine.supported ? "Couldn't start. Allow System Audio Recording for NOTCH in Privacy & Security." : "Needs macOS 14.2 or newer (works with Apple Music only)"
        }
    }

    /// The system-wide route gave up (no sound reached it, or the output could not be rebuilt).
    func engineFailed(_ message: String) {
        BassEngine.shared.stop()
        UserDefaults.standard.set(false, forKey: "bassOn")
        on = false                       // didSet runs apply() which stops everything cleanly
        status = message
        Store.shared.say("Bass booster switched off", hold: 3)
    }

    private func setMusicEQ(_ enable: Bool) {
        if enable == musicEQOn { return }
        musicEQOn = enable
        guard Store.shared.isRunning("com.apple.Music") else { return }
        DispatchQueue.global(qos: .utility).async {
            if enable {
                osa("tell application \"Music\"\nset EQ enabled to true\ntry\nset current EQ preset to EQ preset \"Bass Booster\"\nend try\nend tell")
            } else {
                osa("tell application \"Music\" to set EQ enabled to false")
            }
        }
    }
}
