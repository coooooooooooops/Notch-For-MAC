import SwiftUI
import AppKit

// MARK: Liquid Glass (macOS 26+) with a frosted-material fallback for older macOS.
// The glass code only compiles when the Swift 6.2 toolchain (Xcode 26 SDK) is present, so older
// Command Line Tools still build the app and simply use the material look.

#if compiler(>=6.2)
@available(macOS 26.0, *)
func makeGlass(_ tint: Color?, _ interactive: Bool) -> Glass {
    var g = Glass.regular
    if let t = tint { g = g.tint(t) }
    if interactive { g = g.interactive() }
    return g
}
#endif

extension View {
    /// Liquid Glass on macOS 26+, a frosted material on earlier versions.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint, interactive), in: shape)
        } else {
            self.materialSurface(shape, tint: tint)
        }
        #else
        self.materialSurface(shape, tint: tint)
        #endif
    }

    func materialSurface<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self.background(
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill((tint ?? Color.white).opacity(tint == nil ? 0.05 : 0.30))
            }
        )
        .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 0.75))
    }

    /// A rounded card that is glass when "Liquid Glass" is on in Settings, flat translucent white when it is off.
    func panelCard(_ radius: CGFloat = 10, tint: Color? = nil, classic: Color = Color.white.opacity(0.06)) -> some View {
        modifier(GlassIf(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, interactive: false, classic: classic))
    }
}

struct GlassIf<S: Shape>: ViewModifier {
    @AppStorage("glass") var glass = true
    var shape: S
    var tint: Color?
    var interactive: Bool
    var classic: Color
    func body(content: Content) -> some View {
        if glass {
            content.glassSurface(shape, tint: tint, interactive: interactive)
        } else {
            content.background(shape.fill(classic))
        }
    }
}

// MARK: Haptics
func tapHaptic() {
    guard UserDefaults.standard.bool(forKey: "haptics") else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
}

// MARK: Tab highlight that glides between tabs
struct TabFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

final class TabFrames: ObservableObject {
    @Published var f: [Int: CGRect] = [:]
}

// MARK: Themes (one tap sets colours, outline, corners and glass together)
struct NotchTheme {
    let name: String
    let accent: String
    let clock: String
    let outline: String
    let width: Double
    let corner: Double
    let glass: Bool
    let glassBody: Bool

    static let all: [NotchTheme] = [
        NotchTheme(name: "Midnight", accent: "cyan", clock: "white", outline: "cyan", width: 1.5, corner: 26, glass: true, glassBody: false),
        NotchTheme(name: "Aurora", accent: "purple", clock: "cyan", outline: "purple", width: 2.0, corner: 30, glass: true, glassBody: true),
        NotchTheme(name: "Sunset", accent: "orange", clock: "yellow", outline: "pink", width: 1.5, corner: 28, glass: true, glassBody: false),
        NotchTheme(name: "Mono", accent: "white", clock: "white", outline: "white", width: 1.0, corner: 22, glass: true, glassBody: false),
        NotchTheme(name: "Classic", accent: "green", clock: "white", outline: "none", width: 1.5, corner: 24, glass: false, glassBody: false)
    ]

    func apply() {
        let d = UserDefaults.standard
        d.set(accent, forKey: "accent")
        d.set(clock, forKey: "dateColor")
        d.set(outline, forKey: "outline")
        d.set(width, forKey: "outlineWidth")
        d.set(corner, forKey: "corner")
        d.set(glass, forKey: "glass")
        d.set(glassBody, forKey: "glassBody")
        tapHaptic()
    }
}
