import SwiftUI
import AppKit
import Carbon.HIToolbox

// Global hotkeys. Every NOTCH hotkey must use Control + Option together. That rule is what keeps them from clashing:
// Command-based shortcuts (Cmd+Shift+4, Cmd+Space, Cmd+Tab...) are never touched, Option on its own would swallow
// special characters while typing, and Control on its own is used by text editing (Ctrl+A, Ctrl+E...).

enum HKAction: String, CaseIterable {
    case notch, ai, clipboard

    var title: String {
        switch self {
        case .notch: return "Open / close the notch"
        case .ai: return "Ask AI"
        case .clipboard: return "Clipboard history"
        }
    }
    var detail: String {
        switch self {
        case .notch: return "Opens the notch from anywhere"
        case .ai: return "Jumps to the AI tab with the cursor in the chat"
        case .clipboard: return "Jumps to the clipboard tab"
        }
    }
    var hotkeyID: UInt32 {
        switch self {
        case .notch: return 1
        case .ai: return 2
        case .clipboard: return 3
        }
    }
    /// Default key (always with Control + Option): N, A, V
    var defaultCode: UInt32 {
        switch self {
        case .notch: return 45
        case .ai: return 0
        case .clipboard: return 9
        }
    }
}

struct HKCombo: Equatable {
    var code: UInt32
    var mods: UInt32          // Carbon modifier flags
}

enum HK {
    static let ctrl = UInt32(controlKey), opt = UInt32(optionKey), cmd = UInt32(cmdKey), shift = UInt32(shiftKey)
    static let required = UInt32(controlKey | optionKey)

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= ctrl }
        if f.contains(.option) { m |= opt }
        if f.contains(.shift) { m |= shift }
        if f.contains(.command) { m |= cmd }
        return m
    }

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 36: "Return", 48: "Tab", 51: "Delete",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func text(_ c: HKCombo?) -> String {
        guard let c = c else { return "Off" }
        var s = ""
        if c.mods & ctrl != 0 { s += "⌃" }
        if c.mods & opt != 0 { s += "⌥" }
        if c.mods & shift != 0 { s += "⇧" }
        if c.mods & cmd != 0 { s += "⌘" }
        return s + (keyNames[c.code] ?? "Key \(c.code)")
    }
}

final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()
    @Published var combos: [String: HKCombo] = [:]          // HKAction.rawValue -> combo; missing = turned off
    var onFire: ((HKAction) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() {
        let d = UserDefaults.standard
        for a in HKAction.allCases {
            if let v = d.string(forKey: "hk." + a.rawValue) {
                if v == "off" { continue }
                let p = v.split(separator: ":").compactMap { UInt32($0) }
                if p.count == 2, p[1] & HK.required == HK.required { combos[a.rawValue] = HKCombo(code: p[0], mods: p[1]) }
                else { combos[a.rawValue] = Hotkeys.defaultCombo(a) }
            } else if a == .notch, d.string(forKey: "hotkey") == "off" {
                continue                                    // you had turned the old single hotkey off
            } else {
                combos[a.rawValue] = Hotkeys.defaultCombo(a)
            }
        }
    }

    static func defaultCombo(_ a: HKAction) -> HKCombo { HKCombo(code: a.defaultCode, mods: HK.required) }

    func combo(_ a: HKAction) -> HKCombo? { combos[a.rawValue] }

    func save() {
        let d = UserDefaults.standard
        for a in HKAction.allCases {
            if let c = combos[a.rawValue] { d.set("\(c.code):\(c.mods)", forKey: "hk." + a.rawValue) }
            else { d.set("off", forKey: "hk." + a.rawValue) }
        }
    }

    func set(_ a: HKAction, _ c: HKCombo?) {
        if let c = c { combos[a.rawValue] = c } else { combos[a.rawValue] = nil }
        save(); apply()
    }

    func reset(_ a: HKAction) { set(a, Hotkeys.defaultCombo(a)) }

    /// nil = fine, otherwise the reason it can't be used.
    func validate(_ c: HKCombo, for a: HKAction) -> String? {
        if c.mods & HK.required != HK.required { return "Hold Control and Option together, then press a key" }
        if c.code == 53 { return "Esc cancels" }
        if c.mods == HK.required | HK.cmd, [24, 27, 28].contains(c.code) { return "macOS already uses that for Zoom" }
        for o in HKAction.allCases where o != a {
            if combos[o.rawValue] == c { return "Already used for \"\(o.title)\"" }
        }
        return nil
    }

    // MARK: registration with macOS (no special permission needed)
    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs = [:]
    }

    func apply() {
        unregisterAll()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                var hk = EventHotKeyID()
                let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                if st == noErr {
                    let id = hk.id
                    DispatchQueue.main.async { Hotkeys.shared.fire(id) }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for a in HKAction.allCases {
            guard let c = combos[a.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4E544348), id: a.hotkeyID)
            if RegisterEventHotKey(c.code, c.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref { refs[a.hotkeyID] = r }
        }
    }

    func fire(_ id: UInt32) {
        guard let a = HKAction.allCases.first(where: { $0.hotkeyID == id }) else { return }
        onFire?(a)
    }
}

/// Listens for the next key combination while a hotkey button in Settings is waiting.
final class HotkeyRecorder: ObservableObject {
    static let shared = HotkeyRecorder()
    @Published var recording: HKAction? = nil
    @Published var message = ""
    private var monitor: Any?

    func start(_ a: HKAction) {
        stop()
        recording = a; message = ""
        Hotkeys.shared.unregisterAll()      // otherwise macOS delivers the combination to the hotkey instead of to us
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self = self, let act = self.recording else { return e }
            if e.keyCode == 53 { self.stop(); return nil }
            let c = HKCombo(code: UInt32(e.keyCode), mods: HK.carbonMods(e.modifierFlags))
            if let err = Hotkeys.shared.validate(c, for: act) { self.message = err; return nil }
            Hotkeys.shared.set(act, c)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = nil
        Hotkeys.shared.apply()
    }
}
