import SwiftUI
import AppKit
import WebKit

// Apps tab: your favourite apps and websites. An app that has a web version (Spotify, WhatsApp, Discord, Notion,
// Slack, Apple's Notes / Reminders / Calendar and many more) opens right inside the notch, no need to open the
// Mac app. Anything else just launches normally. You can add any website as its own app, and give any Mac app a
// web address to open inside the notch instead.

struct WebApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
}

struct AppItem: Identifiable {
    let id: String          // the app's path, or "web:<id>" for a website app
    let name: String
    let path: String?       // nil = website app
    let web: String?        // address to run inside the notch, nil = launch the Mac app
}

/// Mac apps that have a good web version. Matched on the app's name.
let knownWebApps: [(keys: [String], url: String)] = [
    (["spotify"], "https://open.spotify.com"),
    (["music", "apple music"], "https://music.apple.com"),
    (["whatsapp"], "https://web.whatsapp.com"),
    (["discord"], "https://discord.com/app"),
    (["slack"], "https://app.slack.com/client"),
    (["telegram"], "https://web.telegram.org"),
    (["messenger"], "https://www.messenger.com"),
    (["notion"], "https://www.notion.so"),
    (["todoist"], "https://app.todoist.com"),
    (["trello"], "https://trello.com"),
    (["figma"], "https://www.figma.com"),
    (["canva"], "https://www.canva.com"),
    (["zoom", "zoom.us"], "https://app.zoom.us/wc"),
    (["microsoft teams", "teams"], "https://teams.microsoft.com"),
    (["microsoft outlook", "outlook"], "https://outlook.office.com/mail"),
    (["microsoft word"], "https://www.office.com/launch/word"),
    (["microsoft excel"], "https://www.office.com/launch/excel"),
    (["microsoft powerpoint"], "https://www.office.com/launch/powerpoint"),
    (["youtube"], "https://www.youtube.com"),
    (["netflix"], "https://www.netflix.com"),
    (["twitch"], "https://www.twitch.tv"),
    (["reddit"], "https://www.reddit.com"),
    (["twitter", "x"], "https://x.com"),
    (["github", "github desktop"], "https://github.com"),
    (["mail"], "https://www.icloud.com/mail"),
    (["notes"], "https://www.icloud.com/notes"),
    (["reminders"], "https://www.icloud.com/reminders"),
    (["calendar"], "https://www.icloud.com/calendar"),
    (["photos"], "https://www.icloud.com/photos"),
    (["pages"], "https://www.icloud.com/pages"),
    (["numbers"], "https://www.icloud.com/numbers"),
    (["keynote"], "https://www.icloud.com/keynote"),
    (["maps"], "https://maps.apple.com"),
]

func knownWebURL(_ appName: String) -> String? {
    let n = appName.lowercased()
    for k in knownWebApps { for key in k.keys where aiMatches(n, key) { return k.url } }
    for p in aiProviders { for key in p.keys where aiMatches(n, key) { return p.url } }
    return nil
}

/// "notion.so" -> "https://notion.so"; returns nil if it doesn't look like an address.
func cleanWebAddress(_ t: String) -> String? {
    var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
    guard let u = URL(string: s), let h = u.host, h.contains(".") else { return nil }
    return s
}

/// Small pop-up with one or more text boxes. Returns nil if cancelled.
func promptFields(_ title: String, _ message: String, ok: String, _ fields: [(String, String)]) -> [String]? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title; a.informativeText = message
    a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
    let h = CGFloat(fields.count) * 30
    let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: h))
    var tfs: [NSTextField] = []
    for (i, f) in fields.enumerated() {
        let t = NSTextField(frame: NSRect(x: 0, y: h - CGFloat(i + 1) * 30 + 3, width: 300, height: 24))
        t.placeholderString = f.0; t.stringValue = f.1
        v.addSubview(t); tfs.append(t)
    }
    a.accessoryView = v
    a.window.initialFirstResponder = tfs.first
    return a.runModal() == .alertFirstButtonReturn ? tfs.map { $0.stringValue } : nil
}

final class AppsModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = AppsModel()
    @Published var web: [WebApp] = []
    @Published var openKey: String? = nil              // the app currently running inside the notch
    @Published var icons: [String: NSImage] = [:]      // website-app icons
    @Published var zoom: Double = 0.6
    var overrides: [String: String] = [:]              // Mac app path -> web address chosen by you
    var views: [String: WKWebView] = [:]               // one live page per app, so music keeps playing / chats stay put
    var lastUsed: [String: Date] = [:]                 // when each page was last on screen (idle pages get unloaded)

    override init() {
        super.init()
        let d = UserDefaults.standard
        if let data = d.data(forKey: "webApps"), let w = try? JSONDecoder().decode([WebApp].self, from: data) { web = w }
        overrides = (d.dictionary(forKey: "appWebOverride") as? [String: String]) ?? [:]
        let z = d.double(forKey: "appsZoom")
        zoom = z == 0 ? 0.6 : min(1.5, max(0.4, z))
        for w in web { loadIcon(w) }
    }

    func saveWeb() {
        if let data = try? JSONEncoder().encode(web) { UserDefaults.standard.set(data, forKey: "webApps") }
    }
    func saveOverrides() { UserDefaults.standard.set(overrides, forKey: "appWebOverride") }

    func items(_ apps: [String]) -> [AppItem] {
        var out: [AppItem] = apps.map { p in
            let name = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
            return AppItem(id: p, name: name, path: p, web: overrides[p] ?? knownWebURL(name))
        }
        out += web.map { AppItem(id: "web:" + $0.id, name: $0.name, path: nil, web: $0.url) }
        return out
    }

    func addWeb(name: String, url: String) {
        let w = WebApp(id: UUID().uuidString, name: name, url: url)
        web.append(w); saveWeb(); loadIcon(w)
    }

    func remove(_ item: AppItem) {
        drop(item.id)
        if let p = item.path { overrides[p] = nil; saveOverrides() }
        else { web.removeAll { "web:" + $0.id == item.id }; saveWeb() }
    }

    func drop(_ key: String) {
        if openKey == key { openKey = nil }
        if let v = views[key] { v.stopLoading(); v.loadHTMLString("", baseURL: nil); views[key] = nil }
    }

    func setOverride(_ item: AppItem, _ url: String) {
        guard let p = item.path else { return }
        overrides[p] = url; saveOverrides()
        drop(item.id)       // reload with the new address next time
    }

    func setZoom(_ z: Double) {
        let c = min(1.5, max(0.4, (z * 10).rounded() / 10))
        zoom = c
        UserDefaults.standard.set(c, forKey: "appsZoom")
        for v in views.values { v.pageZoom = CGFloat(c) }
    }

    func loadIcon(_ w: WebApp) {
        guard let host = URL(string: w.url)?.host,
              let u = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { return }
        DispatchQueue.global(qos: .utility).async {
            if let d = try? Data(contentsOf: u), let i = NSImage(data: d) { DispatchQueue.main.async { self.icons[w.id] = i } }
        }
    }

    /// Throws the page away to free memory; it reloads next time the app is opened.
    func unload(_ key: String) {
        if let v = views[key] { v.stopLoading(); v.navigationDelegate = nil; v.uiDelegate = nil; v.loadHTMLString("", baseURL: nil) }
        views[key] = nil; lastUsed[key] = nil
    }

    func webView(for item: AppItem) -> WKWebView? {
        lastUsed[item.id] = Date()
        if let v = views[item.id] { return v }
        guard let a = item.web, let u = URL(string: a) else { return nil }
        let w = DropWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        w.pageZoom = CGFloat(zoom)
        w.navigationDelegate = self
        w.uiDelegate = self
        BModel.noBounce(w)
        w.load(URLRequest(url: u))
        views[item.id] = w
        return w
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { BModel.noBounce(w); w.pageZoom = CGFloat(zoom) }
    // sign-in pop-ups and "new tab" links just open in the same view
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if a.targetFrame == nil { w.load(a.request) }
        return nil
    }
}

struct AppsView: View {
    @EnvironmentObject var s: Store
    @ObservedObject var m = AppsModel.shared
    @AppStorage("accent") var accent = "green"

    var body: some View {
        let items = m.items(s.apps)
        if let key = m.openKey, let item = items.first(where: { $0.id == key }), let wv = m.webView(for: item) {
            runner(item, wv)
        } else {
            grid(items)
        }
    }

    func icon(_ i: AppItem, _ size: CGFloat) -> some View {
        Group {
            if let p = i.path { Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable() }
            else if let id = i.id.split(separator: ":").last.map(String.init), let img = m.icons[id] {
                Image(nsImage: img).resizable().clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Image(systemName: "globe").resizable().scaledToFit().padding(size * 0.15).foregroundColor(.gray)
            }
        }.frame(width: size, height: size)
    }

    func open(_ i: AppItem) {
        if i.web != nil { m.openKey = i.id }
        else if let p = i.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    // MARK: grid of apps
    func grid(_ items: [AppItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { i in
                        Button { open(i) } label: {
                            VStack(spacing: 6) {
                                icon(i, 42)
                                Text(i.name).font(.caption2).lineLimit(1)
                            }
                            .frame(width: 76, height: 80)
                            .background(Color.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                if i.web != nil {
                                    Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 9))
                                        .foregroundColor(presetColor(accent)).padding(5)
                                }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu { menu(i) }
                    }
                    Menu {
                        Button("Add a Mac app...") { addNative() }
                        Button("Add a website as an app...") { addWebsite() }
                    } label: {
                        Image(systemName: "plus.circle").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 44)
                }.padding(.vertical, 2)
            }
            HStack(spacing: 5) {
                Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 9)).foregroundColor(presetColor(accent))
                Text("Opens inside the notch. Other apps launch as normal. Right-click an app for options.")
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder func menu(_ i: AppItem) -> some View {
        if i.path != nil {
            if i.web != nil { Button("Open the Mac app instead") { if let p = i.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } } }
            Button(i.web != nil ? "Change web address..." : "Open inside the notch (set web address)...") { setWeb(i) }
            Divider()
        }
        Button("Remove") { m.remove(i); if let p = i.path { s.apps.removeAll { $0 == p } } }
    }

    func addNative() {
        NSApp.activate(ignoringOtherApps: true)
        let o = NSOpenPanel(); o.directoryURL = URL(fileURLWithPath: "/Applications"); o.allowedContentTypes = [.application]
        if o.runModal() == .OK, let u = o.url, !s.apps.contains(u.path) { s.apps.append(u.path) }
    }

    func addWebsite() {
        guard let r = promptFields("Add a website as an app", "It opens inside the notch and keeps you signed in.", ok: "Add",
                                   [("Name (e.g. Notion)", ""), ("Address (e.g. notion.so)", "")]) else { return }
        guard let url = cleanWebAddress(r[1]) else { NSSound.beep(); return }
        let host = URL(string: url)?.host ?? "Website"
        let name = r[0].trimmingCharacters(in: .whitespaces)
        m.addWeb(name: name.isEmpty ? host.replacingOccurrences(of: "www.", with: "") : name, url: url)
    }

    func setWeb(_ i: AppItem) {
        guard let r = promptFields("Open \(i.name) inside the notch", "Enter the web version's address.", ok: "Save",
                                   [("Address (e.g. app.example.com)", i.web ?? "")]) else { return }
        guard let url = cleanWebAddress(r[0]) else { NSSound.beep(); return }
        m.setOverride(i, url)
    }

    // MARK: an app running inside the notch
    func runner(_ i: AppItem, _ wv: WKWebView) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { m.openKey = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Apps").font(.system(size: 11, weight: .medium))
                    }.padding(.horizontal, 10).padding(.vertical, 4).background(Color.white.opacity(0.12)).clipShape(Capsule())
                }.buttonStyle(.plain)
                icon(i, 20)
                Text(i.name).font(.headline).lineLimit(1)
                Spacer()
                btn("minus.magnifyingglass") { m.setZoom(m.zoom - 0.1) }
                Text("\(Int((m.zoom * 100).rounded()))%").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    .frame(width: 34).onTapGesture { m.setZoom(0.6) }
                btn("plus.magnifyingglass") { m.setZoom(m.zoom + 0.1) }
                if let p = i.path { btn("arrow.up.forward.app") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
                btn("arrow.clockwise") { wv.reload() }
            }
            Web(wv: wv).id(i.id).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
