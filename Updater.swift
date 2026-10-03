import SwiftUI
import AppKit
import CryptoKit

// Updater tab: asks GitHub for the LATEST release of your repo, shows only that one, and when its tag is
// newer than the installed app it can download it, verify it, rebuild it with build.sh and relaunch.

let updaterTab = 13   // index of the Updater tab in RootView.icons

// MARK: GitHub release format
struct GHAsset: Decodable {
    var name: String
    var browser_download_url: String
    var digest: String?          // GitHub fills this in as "sha256:<hex>"
}
struct GHRelease: Decodable {
    var tag_name: String
    var name: String?
    var body: String?
    var published_at: String?
    var html_url: String?
    var zipball_url: String?
    var assets: [GHAsset]?
}

func cleanVersion(_ t: String) -> String {
    String(t.filter { "0123456789.".contains($0) })
}
func versionParts(_ v: String) -> [Int] {
    cleanVersion(v).split(separator: ".").map { Int($0) ?? 0 }
}
func isNewer(_ a: String, than b: String) -> Bool {
    let x = versionParts(a), y = versionParts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}
/// Accepts "owner/name" or a pasted github.com link and returns "owner/name".
func normalizeRepo(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    for p in ["https://github.com/", "http://github.com/", "github.com/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
    let parts = t.split(separator: "/").map(String.init)
    return parts.count >= 2 ? parts[0] + "/" + parts[1] : t
}

// MARK: model
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    static let defaultRepo = "coooooooooooops/Notch-For-MAC"
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NOTCH", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @Published var release: GHRelease?
    @Published var status = "Not checked yet"
    @Published var checking = false
    @Published var busy = false
    @Published var progress: Double? = nil

    var timer: Timer?
    var logWatch: Timer?
    var pendingSha: String?
    var pendingVersion = ""
    var attemptedTag = ""
    lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var hasUpdate: Bool {
        guard let r = release else { return false }
        return isNewer(r.tag_name, than: currentVersion)
    }
    /// Red dot on the tab icon.
    var badge: Bool { hasUpdate }

    var repo: String { Updater.defaultRepo }

    func start() {
        UserDefaults.standard.register(defaults: ["updAutoInstall": false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
    }
    func autoCheck() { check() }

    // MARK: ask GitHub for the latest release
    func check() {
        guard !checking else { return }
        let r = repo
        guard r.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(r)/releases/latest") else {
            status = "Tap the gear and enter your repo as owner/name"; return
        }
        checking = true
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NOTCH-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                if self.busy { return }
                if let err = err { self.status = "Can't reach GitHub (\(err.localizedDescription))"; return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { self.release = nil; self.status = "No published release found (repo must be public)"; return }
                if code == 403 || code == 429 { self.status = "GitHub says slow down - try again in a while"; return }
                guard code == 200, let data = data, let rel = try? JSONDecoder().decode(GHRelease.self, from: data) else {
                    self.status = "Couldn't read the release (HTTP \(code))"; return
                }
                self.release = rel
                self.status = self.hasUpdate ? "\(rel.tag_name) is available" : "You're up to date"
                if self.hasUpdate, UserDefaults.standard.bool(forKey: "updAutoInstall"), self.attemptedTag != rel.tag_name { self.install() }
            }
        }.resume()
    }

    // MARK: pick what to download
    func pick(_ r: GHRelease) -> (url: URL, sha: String?)? {
        let zips = (r.assets ?? []).filter { $0.name.lowercased().hasSuffix(".zip") }
        let a = zips.first { $0.name.lowercased().contains("notch") } ?? zips.first
        if let a = a, let u = URL(string: a.browser_download_url) {
            var sha: String? = nil
            if let d = a.digest, d.lowercased().hasPrefix("sha256:") { sha = String(d.dropFirst(7)) }
            return (u, sha)
        }
        if let z = r.zipball_url, let u = URL(string: z) { return (u, nil) }   // GitHub's automatic source zip
        return nil
    }

    // MARK: install
    static func hasBuildTools() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    func install() {
        guard !busy, let r = release, hasUpdate else { return }
        guard let src = pick(r) else { status = "This release has no download"; return }
        guard Updater.hasBuildTools() else {
            status = "Needs Apple's build tools: run xcode-select --install in Terminal, then try again"; return
        }
        attemptedTag = r.tag_name
        pendingSha = src.sha
        pendingVersion = cleanVersion(r.tag_name)
        busy = true; progress = 0; status = "Downloading \(r.tag_name)..."
        session.downloadTask(with: src.url).resume()
    }

    func fail(_ m: String) {
        DispatchQueue.main.async { self.busy = false; self.progress = nil; self.status = m }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = f }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, h.statusCode != 200 { fail("Download failed (\(h.statusCode))"); return }
        let fm = FileManager.default
        let dir = Updater.support.appendingPathComponent("update", isDirectory: true)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: dir.appendingPathComponent("update.zip"))
        } catch { fail("Couldn't save the download"); return }
        DispatchQueue.global().async { self.unpackAndBuild(dir) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { fail("Download failed: \(error.localizedDescription)") }
    }

    @discardableResult func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    /// build.sh can sit at the top of the zip, or inside one or two folders (GitHub's source zips add a folder).
    func findBuild(_ root: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent("build.sh")
        if fm.fileExists(atPath: direct.path) { return direct }
        guard depth < 3 else { return nil }
        for c in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue, let f = findBuild(c, depth: depth + 1) { return f }
        }
        return nil
    }

    func unpackAndBuild(_ dir: URL) {
        let zip = dir.appendingPathComponent("update.zip")
        DispatchQueue.main.async { self.progress = nil; self.status = "Checking the download..." }

        // 1. checksum (GitHub provides one for uploaded release files)
        if let want = pendingSha?.lowercased().trimmingCharacters(in: .whitespaces), !want.isEmpty {
            guard let d = try? Data(contentsOf: zip, options: .mappedIfSafe) else { fail("Couldn't read the download"); return }
            let got = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            if got != want { fail("Download doesn't match its checksum - not installed"); return }
        }

        // 2. unzip
        let src = dir.appendingPathComponent("src", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, src.path]) == 0 else { fail("Couldn't unzip the update"); return }
        guard let script = findBuild(src) else { fail("No build.sh inside the release zip"); return }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", src.path])

        // 3. build + install + relaunch, detached so it survives NOTCH quitting itself at the end of build.sh
        let log = Updater.support.appendingPathComponent("update.log")
        try? "".write(to: log, atomically: true, encoding: .utf8)
        DispatchQueue.main.async { self.status = "Building the update... NOTCH restarts by itself (1-2 min)" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "cd \"$1\" && ( /bin/bash build.sh > \"$2\" 2>&1 || echo __BUILD_FAILED__ >> \"$2\" ) </dev/null >/dev/null 2>&1 &",
            "sh", script.deletingLastPathComponent().path, log.path]
        var env = ProcessInfo.processInfo.environment
        env["NOTCH_VERSION"] = pendingVersion      // the release tag becomes the installed version
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { fail("Couldn't start the build"); return }

        // if the build fails the old NOTCH keeps running - say so
        DispatchQueue.main.async {
            let started = Date()
            self.logWatch?.invalidate()
            self.logWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                let txt = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if txt.contains("__BUILD_FAILED__") {
                    t.invalidate(); self.busy = false
                    // show the first real compiler error so a failed build explains itself
                    let firstErr = txt.components(separatedBy: "\n").first { $0.contains("error:") }
                    var why = ""
                    if let e = firstErr {
                        let parts = e.components(separatedBy: "/")
                        why = " First error: " + (parts.last ?? e)
                    }
                    self.status = "Build failed, your current NOTCH is untouched." + why + " (full log: update.log in Application Support/NOTCH)"
                } else if Date().timeIntervalSince(started) > 600 {
                    t.invalidate(); self.busy = false
                    self.status = "Build is taking too long - see update.log in Application Support/NOTCH"
                }
            }
        }
    }
}

// MARK: tab
// (@State is a macro in the newest SDKs and fails with Command Line Tools only, so a tiny ObservableObject holds the flag.)
final class UpdUI: ObservableObject { @Published var editing = false }
struct UpdaterView: View {
    @ObservedObject var u = Updater.shared
    @AppStorage("accent") var accent = "green"
    @AppStorage("updAutoInstall") var autoInstall = false
    @StateObject var ui = UpdUI()

    func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("NOTCH \(u.currentVersion)").font(.headline)
                Text(u.status).font(.caption).foregroundColor(.gray).lineLimit(2)
                Spacer()
                if u.checking { ProgressView().controlSize(.small) }
                btn("arrow.clockwise") { u.check() }
                btn("gearshape") { ui.editing.toggle() }
            }

            if ui.editing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When a new version is found").font(.caption).foregroundColor(.gray)
                    Picker("", selection: $autoInstall) {
                        Text("Ask me first").tag(false)
                        Text("Update automatically").tag(true)
                    }.pickerStyle(.segmented).frame(width: 300)
                    Text(autoInstall ? "NOTCH downloads, rebuilds and restarts itself as soon as a new release is posted."
                                     : "You'll see a red dot and an Install button. NOTCH checks on launch and every 3 hours.")
                        .font(.caption2).foregroundColor(.gray)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.07)).cornerRadius(8)
            }

            if let r = u.release {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text((r.name?.isEmpty == false ? r.name! : r.tag_name)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(r.tag_name).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.white.opacity(0.12)).clipShape(Capsule())
                        Spacer()
                        Text(String((r.published_at ?? "").prefix(10))).font(.caption2).foregroundColor(.gray)
                    }
                    ScrollView {
                        Text(md((r.body?.isEmpty == false) ? r.body! : "No release notes."))
                            .font(.system(size: 12)).lineSpacing(2).foregroundColor(Color.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if u.hasUpdate {
                        HStack {
                            if let p = u.progress { ProgressView(value: p).frame(width: 140) }
                            else if u.busy { ProgressView().controlSize(.small) }
                            else { Button("Install \(r.tag_name)") { u.install() }.buttonStyle(.borderedProminent) }
                            Spacer()
                        }
                    } else {
                        Label("\(r.tag_name) is installed", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(presetColor(accent))
                    }
                }
                .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(u.hasUpdate ? presetColor(accent).opacity(0.15) : Color.white.opacity(0.07)).cornerRadius(10)
            } else if !u.checking {
                Text("No release loaded yet.").font(.caption).foregroundColor(.gray).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if u.release == nil { u.check() } }
    }
}
