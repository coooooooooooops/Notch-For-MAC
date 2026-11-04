import Foundation

// Used by build.sh only if BassEngine.swift does not build on this Mac's toolchain. Everything else still installs;
// the bass booster then falls back to Apple Music's own "Bass Booster" equaliser preset.
final class BassEngine {
    static let shared = BassEngine()
    static var supported: Bool { false }
    var running: Bool { false }
    func start(gainDb: Double) -> String? { "System-wide bass isn't available in this build" }
    func setGain(_ db: Double) {}
    func stop() {}
}
