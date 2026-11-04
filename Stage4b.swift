import SwiftUI
import AppKit
import AVFoundation
import Speech
import IOKit

// MARK: Stage 4b: dictation tab, GPU load, and a picture or GIF that sits beside the notch.

let dictateTab = 20

// MARK: GPU load (0...1) from the graphics accelerator's own statistics
func gpuLoad() -> Double {
    guard let matching = IOServiceMatching("IOAccelerator") else { return 0 }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var best = 0.0
    var svc = IOIteratorNext(it)
    while svc != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let d = props?.takeRetainedValue() as? [String: Any],
           let perf = d["PerformanceStatistics"] as? [String: Any],
           let v = perf["Device Utilization %"] as? NSNumber {
            best = max(best, v.doubleValue)
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(it)
    }
    return min(1, best / 100)
}

// MARK: Dictation (Apple's speech recognition, on the Mac itself whenever the language supports it)
// 4.3: switching the mic off now really releases it. Every session gets its own audio engine, the recognition task is
// cancelled, and the engine is stopped, reset and thrown away, so the orange microphone dot goes out straight away.
final class DictationModel: ObservableObject {
    static let shared = DictationModel()
    @Published var text = ""
    @Published var listening = false
    @Published var status = "Tap the mic and talk"

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var session = 0                 // bumped on every start / stop so a late callback from an old session is ignored
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()

    func toggle() { listening ? stop() : start() }

    func start() {
        if listening { return }
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self.status = "Allow Speech Recognition for NOTCH in System Settings > Privacy & Security"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.status = "Allow the Microphone for NOTCH in System Settings > Privacy & Security"
                            return
                        }
                        if !self.listening { self.begin() }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let rec = recognizer, rec.isAvailable else { status = "Speech recognition isn't available right now"; return }
        releaseAudio()                      // make sure nothing from an earlier session is still holding the mic
        session += 1
        let mine = session
        text = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let eng = AVAudioEngine()
        engine = eng
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { releaseAudio(); status = "No microphone found"; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        eng.prepare()
        do { try eng.start() } catch { releaseAudio(); status = "Couldn't start the microphone"; return }
        listening = true
        status = "Listening..."
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.session == mine else { return }     // an old session: ignore
                if let r = result { self.text = r.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) {
                    let had = self.listening
                    self.releaseAudio()
                    self.listening = false
                    if had { self.finishStatus() }
                }
            }
        }
    }

    /// Stops the microphone completely: tap off, engine stopped and reset, recognition cancelled.
    private func releaseAudio() {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            if e.isRunning { e.stop() }
            e.reset()
        }
        engine = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func finishStatus() {
        if text.isEmpty { status = "Didn't catch anything" }
        else { copy(); status = "Copied to the clipboard" }
    }

    func stop() {
        guard listening || engine != nil else { return }
        session += 1                        // anything the old recognition task still says is now ignored
        releaseAudio()
        let was = listening
        listening = false
        if was { finishStatus() }
    }

    /// Hard stop with no clipboard side effects (used when the notch closes).
    func forceOff() {
        session += 1
        releaseAudio()
        listening = false
    }

    func copy() {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

struct DictateView: View {
    @ObservedObject var d = DictationModel.shared
    @AppStorage("accent") var accent = "green"

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                Button { d.toggle() } label: {
                    Image(systemName: d.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30))
                        .frame(width: 84, height: 84)
                        .modifier(GlassIf(shape: Circle(), tint: d.listening ? Color.red.opacity(0.7) : presetColor(accent).opacity(0.55),
                                          interactive: true, classic: d.listening ? Color.red.opacity(0.5) : presetColor(accent).opacity(0.4)))
                }.buttonStyle(.plain)
                Text(d.status).font(.caption).foregroundColor(.gray).multilineTextAlignment(.center).frame(width: 150)
            }
            VStack(spacing: 8) {
                TextEditor(text: $d.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                HStack {
                    Spacer()
                    Button("Clear") { d.text = "" }.buttonStyle(.plain).foregroundColor(.gray)
                    Button("Copy") { d.copy(); Store.shared.say("Copied") }.buttonStyle(.plain).foregroundColor(presetColor(accent))
                }.font(.system(size: 12))
            }
        }
        .onDisappear { d.stop() }
    }
}

// MARK: A picture or GIF beside the notch while nothing else is happening
struct IdleImage: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.image = NSImage(contentsOfFile: path)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image == nil { v.image = NSImage(contentsOfFile: path) }
    }
}

enum IdlePicture {
    static var path: String { UserDefaults.standard.string(forKey: "idleImagePath") ?? "" }
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "idleImage") && !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    static func choose() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [.image]
        o.allowsMultipleSelection = false
        o.message = "Pick a picture or GIF to show beside the notch"
        guard o.runModal() == .OK, let u = o.url else { return }
        let dest = Updater.support.appendingPathComponent("idle." + (u.pathExtension.isEmpty ? "png" : u.pathExtension))
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: u, to: dest) } catch { Store.shared.say("Couldn't use that file"); return }
        UserDefaults.standard.set(dest.path, forKey: "idleImagePath")
        UserDefaults.standard.set(true, forKey: "idleImage")
        Store.shared.say("Picture set")
    }

    static func remove() {
        try? FileManager.default.removeItem(atPath: path)
        UserDefaults.standard.removeObject(forKey: "idleImagePath")
        UserDefaults.standard.set(false, forKey: "idleImage")
    }
}
