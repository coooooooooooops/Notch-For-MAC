import SwiftUI
import AppKit
import WebKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Tabs: hide and reorder

let tabIcons = ["music.note", "tray.and.arrow.down", "doc.on.clipboard", "timer", "note.text", "square.grid.2x2", "globe", "camera", "calendar", "gauge.medium", "switch.2", "gearshape.fill", unb64("Z2FtZWNvbnRyb2xsZXIuZmlsbA=="), "arrow.down.circle", "sparkles", "cloud.sun.fill"]
let tabNames: [Int: String] = [0: "Music", 1: "Shelf", 2: "Clipboard", 3: "Timers", 4: "Notes", 5: "Apps", 6: "Browser", 7: "Camera", 8: "Calendar",
                               9: "System", 10: "Control Centre", 11: "Settings", 12: unb64("R2FtZQ=="), 13: "Updates", 14: "AI", 15: "Weather"]

final class TabPrefs: ObservableObject {
    static let shared = TabPrefs()
    static let defaultOrder = [0, 1, 2, 3, 4, 5, aiTab, 6, 7, 8, weatherTab, 9, 10, 11, labTab, updaterTab]

    @Published var order: [Int]
    @Published var hidden: Set<Int>
    @Published var editing = false          // the "Customise tabs" screen is showing

    init() {
        let d = UserDefaults.standard
        var seen = Set<Int>()
        var o = ((d.array(forKey: "tabOrder") as? [Int]) ?? []).filter { TabPrefs.defaultOrder.contains($0) && seen.insert($0).inserted }
        // a tab added in a newer version slots in after the tab that precedes it by default
        for t in TabPrefs.defaultOrder where !o.contains(t) {
            let idx = TabPrefs.defaultOrder.firstIndex(of: t) ?? 0
            if idx > 0, let pi = o.firstIndex(of: TabPrefs.defaultOrder[idx - 1]) { o.insert(t, at: pi + 1) } else { o.insert(t, at: 0) }
        }
        order = o
        hidden = Set((d.array(forKey: "tabHidden") as? [Int]) ?? [])
    }

    func save() {
        UserDefaults.standard.set(order, forKey: "tabOrder")
        UserDefaults.standard.set(Array(hidden), forKey: "tabHidden")
    }

    /// Tabs shown in the bar, in order.
    func visible(labOn: Bool) -> [Int] {
        order.filter { !hidden.contains($0) && ($0 != labTab || labOn) }
    }

    /// Every tab the editor lists (the hidden tab only once it is switched on).
    func listed(labOn: Bool) -> [Int] { order.filter { $0 != labTab || labOn } }

    func move(_ t: Int, by d: Int, labOn: Bool) {
        let shown = listed(labOn: labOn)
        guard let si = shown.firstIndex(of: t), shown.indices.contains(si + d),
              let a = order.firstIndex(of: t), let b = order.firstIndex(of: shown[si + d]) else { return }
        order.swapAt(a, b); save()
    }

    func toggle(_ t: Int, labOn: Bool) {
        if hidden.contains(t) { hidden.remove(t) }
        else {
            guard visible(labOn: labOn).count > 1 else { NSSound.beep(); return }   // always keep one tab
            hidden.insert(t)
        }
        save()
    }

    func reset() { order = TabPrefs.defaultOrder; hidden = []; save() }
}

struct TabsEditor: View {
    @EnvironmentObject var s: Store
    @ObservedObject var p = TabPrefs.shared
    @AppStorage("accent") var accent = "green"
    @AppStorage("idleMins") var idleMins = 30

    var idleLabel: String { idleMins == 0 ? "never" : idleMins >= 60 ? "\(idleMins / 60) h" : "\(idleMins) min" }

    func row(_ t: Int) -> some View {
        let off = p.hidden.contains(t)
        return HStack(spacing: 8) {
            Image(systemName: tabIcons[t]).frame(width: 22)
            Text(tabNames[t] ?? "Tab").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            smallIcon("chevron.left") { p.move(t, by: -1, labOn: s.labOn) }
            smallIcon("chevron.right") { p.move(t, by: 1, labOn: s.labOn) }
            smallIcon(off ? "eye.slash" : "eye") {
                p.toggle(t, labOn: s.labOn)
                if !p.visible(labOn: s.labOn).contains(s.tab), let f = p.visible(labOn: s.labOn).first { s.tab = f }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(off ? 0.45 : 1)
    }

    func smallIcon(_ n: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: n).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func pillButton(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.white.opacity(0.12)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Customise tabs").font(.headline)
                Text("Arrows reorder, the eye hides").font(.caption).foregroundColor(.gray)
                Spacer()
                Menu {
                    ForEach([10, 30, 60, 120, 0], id: \.self) { m in
                        Button(m == 0 ? "Never" : m >= 60 ? "\(m / 60) h" : "\(m) min") { idleMins = m }
                    }
                } label: {
                    Text("Free idle web pages: \(idleLabel)").font(.system(size: 11)).foregroundColor(.gray)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                pillButton("Reset") { p.reset() }
                pillButton("Done") { p.editing = false }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 6) {
                    ForEach(p.listed(labOn: s.labOn), id: \.self) { row($0) }
                }
            }
        }
    }
}

// MARK: - Web pages that accept dropped files / text (AI tab and Apps tab)

/// A web view that catches files and text dragged onto it and pastes them into the page's input box,
/// instead of letting the page react to the drop in its own way.
final class DropWebView: WKWebView {
    var accent: NSColor = .systemGreen

    private func light(_ on: Bool) {
        wantsLayer = true
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = accent.cgColor
        layer?.cornerRadius = 8
    }

    // Newer SDKs declare these on NSView itself, so they need `override` (older SDKs didn't, which caused the earlier errors).
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { light(true); return .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { light(false) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { true }
    override func concludeDragOperation(_ s: NSDraggingInfo?) { light(false) }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        light(false)
        let pb = s.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            WebDrop.insert(self, urls: urls); return true
        }
        if let t = pb.string(forType: .string), !t.isEmpty { WebDrop.insert(self, text: t); return true }
        return false
    }
}

enum WebDrop {
    static let textExts: Set<String> = ["txt", "md", "markdown", "swift", "py", "js", "ts", "tsx", "jsx", "json", "csv", "tsv", "log", "html", "css",
                                        "yml", "yaml", "xml", "sh", "c", "h", "cpp", "java", "go", "rs", "rb", "php", "sql", "toml", "ini", "tex"]

    static let focusJS = "(function(){var a=document.activeElement;if(a&&(a.isContentEditable||a.tagName==='TEXTAREA'||a.tagName==='INPUT'))return true;var e=document.querySelector('textarea,[contenteditable=\"true\"],[role=\"textbox\"],input[type=\"text\"]');if(e){e.focus();}return true;})()"

    /// Small text files are pasted as text; anything else (images, PDFs...) is pasted as a file.
    static func readText(_ u: URL) -> String? {
        guard textExts.contains(u.pathExtension.lowercased()),
              let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 120_000 else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    static func insert(_ wv: WKWebView, urls: [URL]) {
        var texts: [String] = []
        var files: [URL] = []
        for u in urls {
            if let t = readText(u) { texts.append("\(u.lastPathComponent):\n```\n\(t)\n```") } else { files.append(u) }
        }
        var steps: [(NSPasteboard) -> Void] = []
        if !texts.isEmpty { let joined = texts.joined(separator: "\n\n"); steps.append { $0.setString(joined, forType: .string) } }
        if !files.isEmpty { steps.append { $0.writeObjects(files.map { $0 as NSURL }) } }
        run(wv, steps)
    }

    static func insert(_ wv: WKWebView, text: String) { run(wv, [{ $0.setString(text, forType: .string) }]) }

    static func snapshot() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    static func restore(_ snap: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = snap.map { arr -> NSPasteboardItem in
            let i = NSPasteboardItem()
            for (t, d) in arr { i.setData(d, forType: t) }
            return i
        }
        if !items.isEmpty { pb.writeObjects(items) }
        Store.shared.lastPB = pb.changeCount
    }

    /// Pastes each step into the page, one after another, then puts your clipboard back the way it was.
    static func run(_ wv: WKWebView, _ steps: [(NSPasteboard) -> Void]) {
        let snap = snapshot()
        var i = 0
        func next() {
            guard i < steps.count else { restore(snap); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            steps[i](pb)
            i += 1
            Store.shared.lastPB = pb.changeCount     // keep these out of the clipboard history
            wv.window?.makeFirstResponder(wv)
            wv.evaluateJavaScript(focusJS) { _, _ in
                _ = wv.tryToPerform(Selector(("paste:")), with: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { next() }
            }
        }
        next()
    }
}

// MARK: - Free the memory of web pages you haven't used for a while

enum IdleSweeper {
    /// Runs once a minute. Pages in the AI and Apps tabs that haven't been on screen for the chosen time are
    /// thrown away (unless they are playing audio). They reload next time you open them.
    static func run() {
        let mins = (UserDefaults.standard.object(forKey: "idleMins") as? Int) ?? 30
        let s = Store.shared, ai = AIModel.shared, apps = AppsModel.shared
        let now = Date()
        if s.expanded && s.tab == aiTab && !ai.choice.isEmpty { ai.lastUsed[ai.choice] = now }
        if s.expanded && s.tab == 5, let k = apps.openKey { apps.lastUsed[k] = now }
        guard mins > 0 else { return }
        let limit = Double(mins) * 60
        for (k, v) in Array(ai.views) where now.timeIntervalSince(ai.lastUsed[k] ?? now) > limit {
            v.requestMediaPlaybackState { st in
                if st == .playing { return }
                DispatchQueue.main.async { ai.unload(k) }
            }
        }
        for (k, v) in Array(apps.views) where now.timeIntervalSince(apps.lastUsed[k] ?? now) > limit {
            v.requestMediaPlaybackState { st in
                if st == .playing { return }
                DispatchQueue.main.async { apps.unload(k) }
            }
        }
    }
}
