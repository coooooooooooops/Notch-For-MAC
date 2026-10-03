import SwiftUI
import AppKit
import WebKit

// AI tab: NOTCH looks through /Applications for AI apps you already have, you pick one, and it runs inside
// the notch without that app ever opening. Nothing to buy and no API key: it uses the app's own free web
// version (you sign in once and it stays signed in). Your pick is remembered; "Switch" lets you choose another.

let aiTab = 14   // index of the AI tab in RootView.icons

struct AIProvider {
    let id: String
    let name: String
    let url: String
    let keys: [String]      // lowercase app-name matches (e.g. "claude" finds Claude.app)
}

let aiProviders: [AIProvider] = [
    AIProvider(id: "chatgpt", name: "ChatGPT", url: "https://chatgpt.com", keys: ["chatgpt"]),
    AIProvider(id: "claude", name: "Claude", url: "https://claude.ai", keys: ["claude"]),
    AIProvider(id: "gemini", name: "Gemini", url: "https://gemini.google.com/app", keys: ["gemini"]),
    AIProvider(id: "perplexity", name: "Perplexity", url: "https://www.perplexity.ai", keys: ["perplexity"]),
    AIProvider(id: "copilot", name: "Copilot", url: "https://copilot.microsoft.com", keys: ["copilot", "microsoft copilot"]),
    AIProvider(id: "grok", name: "Grok", url: "https://grok.com", keys: ["grok"]),
    AIProvider(id: "deepseek", name: "DeepSeek", url: "https://chat.deepseek.com", keys: ["deepseek"]),
    AIProvider(id: "mistral", name: "Le Chat", url: "https://chat.mistral.ai", keys: ["le chat", "mistral"]),
    AIProvider(id: "poe", name: "Poe", url: "https://poe.com", keys: ["poe"]),
]

struct AIFound: Identifiable {
    let p: AIProvider
    let path: String
    var id: String { p.id }
}

func aiMatches(_ appName: String, _ key: String) -> Bool {
    appName == key || appName.hasPrefix(key + " ") || (key.count >= 5 && appName.contains(key))
}

final class AIModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = AIModel()
    @Published var found: [AIFound] = []
    @Published var scanned = false
    @Published var choice: String = "" { didSet { UserDefaults.standard.set(choice, forKey: "aiChoice") } }
    var views: [String: WKWebView] = [:]      // one live page per AI, so a chat survives tab switches
    var lastUsed: [String: Date] = [:]        // when each page was last on screen (idle pages get unloaded)

    override init() {
        super.init()
        choice = UserDefaults.standard.string(forKey: "aiChoice") ?? ""
    }

    /// Looks for AI apps in /Applications and ~/Applications.
    func scan() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var apps: [(name: String, path: String)] = []
            for d in ["/Applications", NSHomeDirectory() + "/Applications"] {
                for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                    apps.append((String(f.dropLast(4)).lowercased(), d + "/" + f))
                }
            }
            var out: [AIFound] = []
            for p in aiProviders {
                var hit: (name: String, path: String)? = nil
                for a in apps {
                    for k in p.keys where aiMatches(a.name, k) { hit = a }
                    if hit != nil { break }
                }
                if let h = hit { out.append(AIFound(p: p, path: h.path)) }
            }
            DispatchQueue.main.async {
                self.found = out
                self.scanned = true
                if !self.choice.isEmpty, !out.contains(where: { $0.id == self.choice }) { self.choice = "" }   // app was removed
            }
        }
    }

    /// Puts the cursor in the chat box (used by the Ask AI hotkey).
    func focusChat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let wv = self.views[self.choice] else { return }
            wv.window?.makeFirstResponder(wv)
            wv.evaluateJavaScript(WebDrop.focusJS, completionHandler: nil)
        }
    }

    func unload(_ id: String) {
        if let v = views[id] { v.stopLoading(); v.navigationDelegate = nil; v.uiDelegate = nil; v.loadHTMLString("", baseURL: nil) }
        views[id] = nil; lastUsed[id] = nil
    }

    func web(for id: String) -> WKWebView {
        lastUsed[id] = Date()
        if let w = views[id] { return w }
        let w = DropWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        w.pageZoom = 0.85
        w.navigationDelegate = self
        w.uiDelegate = self
        BModel.noBounce(w)
        if let p = aiProviders.first(where: { $0.id == id }), let u = URL(string: p.url) { w.load(URLRequest(url: u)) }
        views[id] = w
        return w
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { BModel.noBounce(w) }
    // sign-in pop-ups and "new tab" links just open in the same view
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if a.targetFrame == nil { w.load(a.request) }
        return nil
    }
}

struct AIView: View {
    @ObservedObject var m = AIModel.shared
    @AppStorage("accent") var accent = "green"

    var body: some View {
        Group {
            if let f = m.found.first(where: { $0.id == m.choice }) { chat(f) } else { picker }
        }.onAppear { m.scan() }
    }

    func chat(_ f: AIFound) -> some View {
        let wv = m.web(for: f.id)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 20, height: 20)
                Text(f.p.name).font(.headline)
                Spacer()
                btn("arrow.clockwise") { wv.reload() }
                Button { m.choice = "" } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .bold))
                        Text("Switch").font(.system(size: 11, weight: .medium))
                    }.padding(.horizontal, 10).padding(.vertical, 4).background(Color.white.opacity(0.12)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            Web(wv: wv).id(f.id).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    var picker: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text("Choose your AI").font(.system(size: 15, weight: .semibold))
                Text(m.found.isEmpty && m.scanned
                     ? "No AI apps found in Applications. Install ChatGPT, Claude, Gemini, Perplexity or similar, then come back."
                     : "Found on this Mac. It runs right here in the notch, no need to open the app. Sign in once and NOTCH remembers your pick.")
                    .font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(m.found) { f in
                        Button { m.choice = f.id } label: {
                            VStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 52, height: 52)
                                Text(f.p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            .frame(width: 92, height: 98)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if m.scanned {
                        Button { m.scan() } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 18)).frame(width: 52, height: 52)
                                Text("Rescan").font(.system(size: 11)).foregroundColor(.gray)
                            }
                            .frame(width: 92, height: 98)
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 2)
            }.frame(height: 106)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
