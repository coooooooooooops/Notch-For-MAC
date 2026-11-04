import Foundation
import CoreAudio
import AudioToolbox

// MARK: Bass booster, system-wide (macOS 14.2 and newer).
// NOTCH taps all the audio the Mac is playing (apart from its own chimes), runs it through a low-shelf filter and plays it
// out of the same speakers or headphones. The original sound is muted only while NOTCH is doing this, and the tap is
// removed by macOS the moment NOTCH quits, so audio can never be left muted.
// macOS asks for "System Audio Recording" permission the first time. If this file ever fails to build,
// build.sh falls back to BassEngineStub.swift and the rest of the app still installs.

/// The filter: a low-shelf biquad (RBJ cookbook) plus a gentle limiter so boosted peaks never clip.
final class BassDSP {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var pre = 1.0
    private let z1 = UnsafeMutablePointer<Double>.allocate(capacity: 16)
    private let z2 = UnsafeMutablePointer<Double>.allocate(capacity: 16)
    var sampleRate = 48000.0
    var peak: Float = 0                 // loudest input sample since the last check (the silence watchdog reads it)

    init() {
        z1.initialize(repeating: 0, count: 16)
        z2.initialize(repeating: 0, count: 16)
    }
    deinit { z1.deallocate(); z2.deallocate() }

    func configure(gainDb: Double, sampleRate sr: Double) {
        sampleRate = sr
        let f0 = 120.0
        let A = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * f0 / sr
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / 2.0 * 2.0.squareRoot()          // shelf slope 1
        let sq = 2.0 * A.squareRoot() * alpha
        let nb0 = A * ((A + 1) - (A - 1) * cw + sq)
        let nb1 = 2 * A * ((A - 1) - (A + 1) * cw)
        let nb2 = A * ((A + 1) - (A - 1) * cw - sq)
        let na0 = (A + 1) + (A - 1) * cw + sq
        let na1 = -2 * ((A - 1) + (A + 1) * cw)
        let na2 = (A + 1) + (A - 1) * cw - sq
        // headroom: pull the whole signal down a little as the boost goes up
        pre = pow(10.0, -min(gainDb, 15) * 0.35 / 20.0)
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0
    }

    func reset() { z1.initialize(repeating: 0, count: 16); z2.initialize(repeating: 0, count: 16); peak = 0 }

    private func totalChannels(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var n = 0
        for b in list { n += Int(b.mNumberChannels) }
        return n
    }

    /// Finds channel `c` across the buffers: its first sample, the step between samples and how many frames it has.
    private func chan(_ list: UnsafeMutableAudioBufferListPointer, _ c: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var idx = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            guard n > 0, let d = b.mData else { continue }
            if c < idx + n {
                let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * n)
                return (d.assumingMemoryBound(to: Float.self) + (c - idx), n, frames)
            }
            idx += n
        }
        return nil
    }

    func process(_ inList: UnsafeMutableAudioBufferListPointer, _ outList: UnsafeMutableAudioBufferListPointer) {
        let inCh = totalChannels(inList), outCh = totalChannels(outList)
        var pk: Float = 0
        for c in 0..<min(outCh, 16) {
            guard let o = chan(outList, c) else { continue }
            guard inCh > 0, let i = chan(inList, min(c, inCh - 1)) else {
                for f in 0..<o.2 { o.0[f * o.1] = 0 }
                continue
            }
            let frames = min(o.2, i.2)
            var s1 = z1[c], s2 = z2[c]
            for f in 0..<frames {
                let xin = i.0[f * i.1]
                let ax = abs(xin)
                if ax > pk { pk = ax }
                let x = Double(xin) * pre
                var y = b0 * x + s1
                s1 = b1 * x - a1 * y + s2
                s2 = b2 * x - a2 * y
                // soft knee above 0.9 so a boosted peak rounds off instead of clipping
                let ay = abs(y)
                if ay > 0.9 { y = (y < 0 ? -1.0 : 1.0) * (0.9 + 0.1 * tanh((ay - 0.9) / 0.1)) }
                o.0[f * o.1] = Float(y)
            }
            z1[c] = s1; z2[c] = s2
            if o.2 > frames { for f in frames..<o.2 { o.0[f * o.1] = 0 } }
        }
        if pk > peak { peak = pk }
    }
}

@available(macOS 14.2, *)
final class BassTapCore {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let dsp: BassDSP
    private let queue = DispatchQueue(label: "notch.bass.io", qos: .userInteractive)

    init(dsp: BassDSP) { self.dsp = dsp }

    static func uid(of dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf)
        guard st == noErr, let c = cf else { return nil }
        return c.takeRetainedValue() as String
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var p = pid
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return (st == noErr && obj != AudioObjectID(kAudioObjectUnknown)) ? obj : nil
    }

    /// nil = running. Otherwise a short message saying what went wrong (everything is cleaned up again).
    func start(gainDb: Double) -> String? {
        guard let outDev = SysAudio.device(), let outUID = BassTapCore.uid(of: outDev) else { return "No audio output found" }
        var excluded: [AudioObjectID] = []
        if let me = BassTapCore.processObject(pid: getpid()) { excluded.append(me) }     // never tap ourselves
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "NOTCH Bass"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var tid = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tid)
        guard st == noErr else { return "Couldn't tap the system audio (error \(st))" }
        tapID = tid

        var sr = 48000.0
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asz, &asbd) == noErr, asbd.mSampleRate > 0 { sr = asbd.mSampleRate }
        dsp.reset()
        dsp.configure(gainDb: gainDb, sampleRate: sr)

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NOTCH Bass",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]]
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aid)
        guard st == noErr else { stop(); return "Couldn't set up the audio route (error \(st))" }
        aggID = aid

        let d = dsp
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inData, _, outData, _ in
            d.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                      UnsafeMutableAudioBufferListPointer(outData))
        }
        guard st == noErr, let pid = procID else { stop(); return "Couldn't start the audio route (error \(st))" }
        st = AudioDeviceStart(aggID, pid)
        guard st == noErr else { stop(); return "Couldn't start the audio route (error \(st))" }
        return nil
    }

    func stop() {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// What the rest of the app talks to.
final class BassEngine {
    static let shared = BassEngine()
    static var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    let dsp = BassDSP()
    private var core: AnyObject?
    private var gain = 6.0
    private var watch: Timer?
    private var silentChecks = 0
    private var listening = false
    var running: Bool { core != nil }

    /// nil = started. Otherwise the reason it could not start.
    func start(gainDb: Double) -> String? {
        gain = gainDb
        guard #available(macOS 14.2, *) else { return "System-wide bass needs macOS 14.2 or newer" }
        stop()
        let c = BassTapCore(dsp: dsp)
        if let err = c.start(gainDb: gainDb) { return err }
        core = c
        silentChecks = 0
        listenForDeviceChanges()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        watch = t
        return nil
    }

    func setGain(_ db: Double) {
        gain = db
        if running { dsp.configure(gainDb: db, sampleRate: dsp.sampleRate) }
    }

    func stop() {
        watch?.invalidate(); watch = nil
        if #available(macOS 14.2, *), let c = core as? BassTapCore { c.stop() }
        core = nil
    }

    /// If music is playing but the tap hears pure silence for a while, the permission was probably refused:
    /// switch the boost off again so the Mac is never left silent.
    private func check() {
        guard running else { return }
        let pk = dsp.peak
        dsp.peak = 0
        if pk == 0 && Store.shared.playing { silentChecks += 1 } else { silentChecks = 0 }
        if silentChecks >= 5 {
            silentChecks = 0
            BassBoost.shared.engineFailed("No sound reached the booster. Allow NOTCH under System Settings > Privacy & Security > System Audio Recording, then switch it on again.")
        }
    }

    /// Plugging in headphones or switching speakers changes the output; rebuild the route for the new one.
    private func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self = self, self.running else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.running else { return }
                if let err = self.start(gainDb: self.gain) { BassBoost.shared.engineFailed(err) }
            }
        }
    }
}
