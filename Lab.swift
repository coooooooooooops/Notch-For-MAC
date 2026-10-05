import SwiftUI
import AppKit
import WebKit
import Network

// A locally hosted page in the notch. Its resources ship inside the app as one packed file
// (Contents/Resources/ui-cache.dat), are unpacked to a hidden cache folder on first use, and are served to a
// WKWebView by a tiny loopback-only web server (127.0.0.1), so workers, wasm and saved state
// (localStorage / IndexedDB) all behave exactly like a normal website.

let labTab = 12   // index of this tab in RootView.icons

/// Small helper for strings kept out of plain sight in the source.
func unb64(_ s: String) -> String { String(data: Data(base64Encoded: s) ?? Data(), encoding: .utf8) ?? "" }

// MARK: local static file server (loopback only)
final class LocalServer {
    static let shared = LocalServer()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let root: URL
    private let q = DispatchQueue(label: "notch.localserver")
    private var unpacking = false
    /// Scrambling key for the packed resource file (it is only there to keep the file from being readable at a glance).
    private static let blobKey: [UInt8] = [139, 79, 16, 115, 29, 26, 245, 191, 83, 17, 237, 73, 153, 172, 163, 190, 99, 27, 106, 213, 113, 194, 151, 186, 70, 177, 250, 235, 39, 46, 186, 245]

    /// Unpacked into the Caches folder (macOS clears the temp folder after a few idle days, which could pull files out from under a running page).
    static var rootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NOTCH", isDirectory: true).appendingPathComponent(".ui-cache", isDirectory: true)
    }
    static func cleanup() { try? FileManager.default.removeItem(at: rootURL) }

    init() {
        root = LocalServer.rootURL
        try? FileManager.default.removeItem(at: root)      // never reuse leftovers from an earlier run
    }

    var hasPage: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) }

    /// Unpacks the bundled resource file (first use only). `done` runs on the main queue.
    func prepare(_ done: @escaping (Bool) -> Void) {
        if hasPage { done(true); return }
        guard !unpacking else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.prepare(done) }; return }
        guard let src = Bundle.main.url(forResource: "ui-cache", withExtension: "dat") else { done(false); return }
        unpacking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.unpack(src)
            DispatchQueue.main.async { self.unpacking = false; done(ok) }
        }
    }

    private func unpack(_ src: URL) -> Bool {
        guard var data = try? Data(contentsOf: src) else { return false }
        let key = LocalServer.blobKey
        data.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            for i in 0..<b.count { b[i] ^= key[i & 31] }
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(".ui-" + UUID().uuidString + ".zip")
        guard (try? data.write(to: tmp)) != nil else { return false }
        defer { try? fm.removeItem(at: tmp) }
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tools: [(String, [String])] = [("/usr/bin/ditto", ["-x", "-k", tmp.path, root.path]),
                                           ("/usr/bin/unzip", ["-q", "-o", tmp.path, "-d", root.path])]
        for (exe, args) in tools {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 && hasPage { return true }
        }
        return false
    }

    /// Calls `done` on the main queue with the port, or nil if no port could be opened.
    /// The first port is fixed on purpose: the web origin stays the same between launches, so your saves persist.
    func start(_ done: @escaping (UInt16?) -> Void) {
        if isRunning { done(port); return }
        // a server that died in the background is dropped here so a fresh one can take its place
        listener?.cancel(); listener = nil; port = 0
        tryPort(47615, remaining: 12, done)
    }

    /// True while the loopback server is up and listening.
    var isRunning: Bool {
        if port != 0, let l = listener, case .ready = l.state { return true }
        return false
    }

    private func tryPort(_ p: UInt16, remaining: Int, _ done: @escaping (UInt16?) -> Void) {
        guard remaining > 0, let np = NWEndpoint.Port(rawValue: p) else { DispatchQueue.main.async { done(nil) }; return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: np) else { tryPort(p + 1, remaining: remaining - 1, done); return }
        var finished = false
        l.stateUpdateHandler = { [weak self, weak l] st in
            switch st {
            case .ready:
                guard !finished else { return }
                finished = true
                self?.listener = l; self?.port = p
                DispatchQueue.main.async { done(p) }
            case .failed:
                if finished {
                    l?.cancel()
                    if let me = self, me.listener === l { me.listener = nil; me.port = 0 }
                    return
                }
                finished = true
                l?.cancel()
                self?.tryPort(p + 1, remaining: remaining - 1, done)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: q)
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        readRequest(c, Data())
    }

    private func readRequest(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isDone, err in
            guard let self = self else { c.cancel(); return }
            var b = buf
            if let d = data { b.append(d) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: b[b.startIndex..<r.lowerBound], as: UTF8.self))
            } else if err != nil || isDone || b.count > 65536 {
                c.cancel()
            } else {
                self.readRequest(c, b)
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { send(c, 405, "Method Not Allowed", Data(), [:]); return }
        let isHead = parts[0] == "HEAD"
        var path = String(parts[1])
        if let i = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[path.startIndex..<i]) }
        path = path.removingPercentEncoding ?? path
        if path.hasSuffix("/") { path += "index.html" }
        let comps = path.split(separator: "/").map(String.init)
        if comps.contains("..") { send(c, 403, "Forbidden", Data(), [:]); return }
        let file = comps.reduce(root) { $0.appendingPathComponent($1) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            send(c, 404, "Not Found", Data("Not found".utf8), ["Content-Type": "text/plain"]); return
        }
        var headers = ["Content-Type": LocalServer.mime(file.pathExtension.lowercased()), "Accept-Ranges": "bytes"]
        // Range support (Safari's media player asks for byte ranges)
        if let rl = lines.first(where: { $0.lowercased().hasPrefix("range:") }), let eq = rl.range(of: "bytes=") {
            let spec = rl[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            let se = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if se.count == 2 {
                var a = 0, b = data.count - 1
                if se[0].isEmpty, let n = Int(se[1]) { a = max(0, data.count - n) }
                else if let s = Int(se[0]) { a = s; if let e = Int(se[1]) { b = min(e, data.count - 1) } }
                if a <= b, a < data.count {
                    headers["Content-Range"] = "bytes \(a)-\(b)/\(data.count)"
                    send(c, 206, "Partial Content", data.subdata(in: a..<(b + 1)), headers, head: isHead); return
                }
                headers["Content-Range"] = "bytes */\(data.count)"
                send(c, 416, "Range Not Satisfiable", Data(), headers); return
            }
        }
        send(c, 200, "OK", data, headers, head: isHead)
    }

    private func send(_ c: NWConnection, _ code: Int, _ text: String, _ body: Data, _ headers: [String: String], head: Bool = false) {
        var h = "HTTP/1.1 \(code) \(text)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        if !head { out.append(body) }
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    static func mime(_ ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "glb": return "model/gltf-binary"
        default: return "application/octet-stream"
        }
    }
}

// MARK: page web view
// The web view lives inside ONE permanent container view (LabHost) that SwiftUI simply re-uses every time the
// tab opens, so the page (and whatever you were doing in it) is still there when you reopen. Its saved state lives in
// the web view's persistent storage AND in a mirror file (~/Library/Application Support/NOTCH/page-state.json)
// that is restored automatically if the page's storage is ever empty.
final class LabModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = LabModel()
    static let keyPrefix = unb64("cG9seXRyYWNr")
    static let legacyStateName = unb64("cG9seXRyYWNrLXNhdmUuanNvbg==")
    @Published var ready = false
    @Published var error: String? { didSet { host.isHidden = (error != nil) } }
    let wv: WKWebView
    let host: LabHost
    private var started = false
    private var loadTimer: DispatchWorkItem?
    private let saveQ = DispatchQueue(label: "notch.statesave")

    static var saveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NOTCH", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let new = base.appendingPathComponent("page-state.json")
        let old = base.appendingPathComponent(LabModel.legacyStateName)
        if !FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: new)       // keep existing saves from before the rename
        }
        return new
    }

    /// Mirror file contents as a JSON object literal ("{}" if missing or damaged).
    static func savedJSON() -> String {
        guard let d = try? Data(contentsOf: saveURL),
              (try? JSONSerialization.jsonObject(with: d)) is [String: Any],
              let t = String(data: d, encoding: .utf8) else { return "{}" }
        return t
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []       // let the page play sound without an extra click
        cfg.websiteDataStore = WKWebsiteDataStore.default()      // persistent: keeps the page's saved state
        let js = """
        (function(){
          var A=window.AudioContext||window.webkitAudioContext;
          if(A){window.__ac=[];var P=new Proxy(A,{construct:function(t,a){var c=new t(...a);window.__ac.push(c);return c;}});window.AudioContext=P;window.webkitAudioContext=P;}
          document.addEventListener('contextmenu',function(e){e.preventDefault();});
          var st=document.createElement('style');st.textContent='html,body{overscroll-behavior:none !important;}';
          (document.head||document.documentElement).appendChild(st);
          var ls;try{ls=window.localStorage;}catch(e){return;}
          var saved=\(LabModel.savedJSON());
          try{for(var k in saved){if(ls.getItem(k)===null){ls.setItem(k,saved[k]);}}}catch(e){}
          var timer=null;
          function dump(){
            var o={};
            try{for(var i=0;i<ls.length;i++){var k=ls.key(i);if(k&&k.indexOf('\(LabModel.keyPrefix)')===0){o[k]=ls.getItem(k);}}}catch(e){}
            try{window.webkit.messageHandlers.notchSave.postMessage(JSON.stringify(o));}catch(e){}
          }
          window.__notchDump=dump;
          function sched(){clearTimeout(timer);timer=setTimeout(dump,400);}
          var sp=Storage.prototype,si=sp.setItem,ri=sp.removeItem,ci=sp.clear;
          sp.setItem=function(){var r=si.apply(this,arguments);if(this===ls)sched();return r;};
          sp.removeItem=function(){var r=ri.apply(this,arguments);if(this===ls)sched();return r;};
          sp.clear=function(){var r=ci.apply(this,arguments);if(this===ls)sched();return r;};
          window.addEventListener('pagehide',dump);
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 380), configuration: cfg)
        wv = web
        host = LabHost(web: web)
        super.init()
        wv.configuration.userContentController.add(self, name: "notchSave")
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        if wv.responds(to: NSSelectorFromString("setDrawsBackground:")) { wv.setValue(false, forKey: "drawsBackground") }   // transparent until the page paints
        BModel.noBounce(wv)
    }

    /// Loads the page the first time the tab is opened.
    func start() {
        guard !started else { return }
        started = true
        error = nil
        LocalServer.shared.prepare { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.error = "A resource is missing from the app.\nRebuild with the resource file next to build.sh."
                self.started = false
                return
            }
            LocalServer.shared.start { [weak self] port in
                guard let self = self else { return }
                guard let port = port, let u = URL(string: "http://127.0.0.1:\(port)/index.html") else {
                    self.error = "Couldn't start the local page server."
                    self.started = false
                    return
                }
                self.wv.load(URLRequest(url: u))
                // if nothing has loaded after 20 s, say so instead of sitting on a black panel
                self.loadTimer?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.ready, self.error == nil else { return }
                    self.error = "The page didn't load.\nClick to retry."
                }
                self.loadTimer = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
            }
        }
    }

    /// Try again after an error (click the message).
    func retry() {
        loadTimer?.cancel()
        error = nil; ready = false; started = false
        start()
    }

    func focus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, let p = (NSApp.delegate as? AppDelegate)?.panel else { return }
            p.makeKey()
            p.makeFirstResponder(self.wv)
        }
    }

    /// Notch closed / tab left: silence audio, flush the state mirror, tell the page it lost focus. The page itself stays loaded.
    func suspend() {
        guard started else { return }
        wv.evaluateJavaScript("""
        try{
          if(window.__notchDump)window.__notchDump();
          (window.__ac||[]).forEach(function(c){c.suspend();});
          window.__pl=[].slice.call(document.querySelectorAll('audio,video')).filter(function(m){return !m.paused;});
          window.__pl.forEach(function(m){m.pause();});
          window.dispatchEvent(new Event('blur'));
        }catch(e){}
        """, completionHandler: nil)
    }

    /// Starts the page again from scratch (and the server if needed) without having to quit the app.
    func revive() {
        loadTimer?.cancel()
        ready = false; error = nil; started = false
        start()
    }

    func resume() {
        guard started else { return }
        if ready {
            if !LocalServer.shared.isRunning { revive(); return }
            wv.evaluateJavaScript("1") { [weak self] _, err in
                if err != nil { self?.revive() }
            }
        }
        wv.evaluateJavaScript("""
        try{
          (window.__ac||[]).forEach(function(c){c.resume();});
          (window.__pl||[]).forEach(function(m){m.play();});
          window.__pl=[];
          window.dispatchEvent(new Event('focus'));
        }catch(e){}
        """, completionHandler: nil)
    }

    // MARK: state mirror
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "notchSave", let text = message.body as? String,
              let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return }
        saveQ.async { try? data.write(to: LabModel.saveURL, options: .atomic) }
    }

    // MARK: navigation
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loadTimer?.cancel(); error = nil; ready = true; BModel.noBounce(w) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { error = e.localizedDescription }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { error = e.localizedDescription }
    /// If macOS ever reclaims the web process while the notch is closed, bring the page straight back.
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        ready = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.revive() }   // short pause so a page that keeps failing can't spin
    }
}

/// Permanent container for the page's web view. SwiftUI is handed this same view every time the tab opens,
/// so the web view always sizes itself to whatever space the tab gives it (no manual frame maths).
final class LabHost: NSView {
    let web: WKWebView
    init(web: WKWebView) {
        self.web = web
        super.init(frame: NSRect(x: 0, y: 0, width: 780, height: 380))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        web.frame = bounds
        web.autoresizingMask = []
        addSubview(web)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // pages divide by their own size, so never hand one a zero-size frame while the panel is collapsing
        if bounds.width >= 200 && bounds.height >= 120 { web.frame = bounds }
    }
}

struct LabSlot: NSViewRepresentable {
    func makeNSView(context: Context) -> LabHost { LabModel.shared.host }
    func updateNSView(_ v: LabHost, context: Context) {}
}

struct LabView: View {
    @ObservedObject var m = LabModel.shared

    var body: some View {
        ZStack {
            Color.black
            if let e = m.error {
                Button { m.retry() } label: {
                    Text(e).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center).padding()
                }.buttonStyle(.plain)
            } else if !m.ready {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading...").font(.caption).foregroundColor(.gray)
                }
            }
            LabSlot()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { m.start(); m.resume(); m.focus() }
        .onDisappear { m.suspend() }
    }
}
