import SwiftUI
import Foundation

// MARK: Live lyrics (Spotify, Apple Music and Safari). Synced lyrics come from the free LRCLIB service;
// only the song name, artist and length are sent. Turn it off in Settings > Music.
//
// 4.3: the whole song is kept, so the lyrics panel can show every line sung so far (and what is coming),
// lines with several timestamps are handled, a miss is retried with a looser search, and plain
// (unsynced) lyrics are used when no synced version exists.

struct LyricLine {
    let t: Double
    let text: String
}

final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published var lines: [LyricLine] = []
    @Published var plain: [String] = []          // unsynced lyrics, used only when there is no synced version
    @Published var loading = false
    @Published var index = -1                    // the line being sung right now (-1 = before the first line)
    private var key = ""
    private var clockTimer: Timer?

    init() {
        // A light clock keeps `index` current. It only publishes when the line actually changes.
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.advance() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    var hasAny: Bool { !lines.isEmpty || !plain.isEmpty }

    private func advance() {
        guard !lines.isEmpty else { if index != -1 { index = -1 }; return }
        let i = indexFor(Store.shared.curPos())
        if i != index { index = i }
    }

    /// Binary search for the last line that has started at `t` seconds.
    func indexFor(_ t: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].t <= t + 0.25 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// Takes the junk off titles: "(feat. X)", "- Remastered 2011", "[Official Video]" and so on.
    static func cleanTitle(_ t: String) -> String {
        var s = t
        let patterns = ["\\s*[\\(\\[][^\\)\\]]*(feat|ft\\.|official|remaster|live|lyrics|video|audio|visuali[sz]er|explicit|clean)[^\\)\\]]*[\\)\\]]",
                        "\\s+-\\s+(\\d{4}\\s+)?(remaster(ed)?|live|single version|radio edit|mono|stereo).*$"]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    func clear() {
        key = ""; lines = []; plain = []; loading = false; index = -1
    }

    func load(track: String, artist: String, duration: Double) {
        guard UserDefaults.standard.bool(forKey: "lyrics"), !track.isEmpty, track != "Nothing playing" else { clear(); return }
        let k = track + "|" + artist
        if k == key { return }
        key = k
        lines = []; plain = []; index = -1; loading = true
        let title = LyricsStore.cleanTitle(track)
        let who = artist.trimmingCharacters(in: .whitespaces)
        let dur = duration

        fetch(path: "get", items: [("track_name", title), ("artist_name", who)], duration: dur) { [weak self] first in
            if let r = first, r.hasContent { self?.finish(k, r); return }
            // Looser: search by title and artist and take the closest-length hit.
            self?.search(title: title, artist: who, duration: dur) { second in
                if let r = second, r.hasContent { self?.finish(k, r); return }
                // Last try: a title-only search (artist names differ a lot between services).
                self?.search(title: title, artist: "", duration: dur) { third in
                    self?.finish(k, third ?? LRCResult())
                }
            }
        }
    }

    struct LRCResult {
        var synced: String = ""
        var plain: String = ""
        var hasContent: Bool { !synced.isEmpty || !plain.isEmpty }
    }

    private func finish(_ k: String, _ r: LRCResult) {
        let parsed = r.synced.isEmpty ? [] : LyricsStore.parse(r.synced)
        let plainLines = r.plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        DispatchQueue.main.async {
            guard self.key == k else { return }
            self.lines = parsed
            self.plain = parsed.isEmpty ? plainLines : []
            self.loading = false
            if !r.hasContent { self.key = "" }       // nothing found: let the next poll try again later
            self.advance()
        }
    }

    private func request(_ path: String, _ items: [(String, String)], duration: Double) -> URLRequest? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/" + path) else { return nil }
        var q = items.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        if duration > 0 && path == "get" { q.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        comps.queryItems = q
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("NOTCH-for-Mac", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func fetch(path: String, items: [(String, String)], duration: Double, _ done: @escaping (LRCResult?) -> Void) {
        guard let req = request(path, items, duration: duration) else { done(nil); return }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { done(nil); return }
            done(LRCResult(synced: (j["syncedLyrics"] as? String) ?? "", plain: (j["plainLyrics"] as? String) ?? ""))
        }.resume()
    }

    private func search(title: String, artist: String, duration: Double, _ done: @escaping (LRCResult?) -> Void) {
        guard let req = request("search", [("track_name", title), ("artist_name", artist)], duration: 0) else { done(nil); return }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !arr.isEmpty else { done(nil); return }
            // Prefer a synced hit whose length is closest to the song we are playing.
            func score(_ d: [String: Any]) -> Double {
                let hasSynced = ((d["syncedLyrics"] as? String) ?? "").isEmpty ? 1000.0 : 0.0
                let dd = (d["duration"] as? Double) ?? 0
                return hasSynced + (duration > 0 && dd > 0 ? abs(dd - duration) : 5)
            }
            guard let best = arr.min(by: { score($0) < score($1) }) else { done(nil); return }
            done(LRCResult(synced: (best["syncedLyrics"] as? String) ?? "", plain: (best["plainLyrics"] as? String) ?? ""))
        }.resume()
    }

    /// Understands "[01:23.45] words" and lines that carry several stamps: "[00:10.00][00:50.00] words".
    static func parse(_ lrc: String) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]") else { return [] }
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let ns = raw as NSString
            let ms = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(t: mm * 60 + ss, text: text))
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// The line being sung at `t` seconds into the song.
    func line(at t: Double) -> String {
        let i = indexFor(t)
        return i >= 0 && i < lines.count ? lines[i].text : ""
    }
}

/// One line of the current lyric under the song title. Click it to open the full lyrics.
struct LyricsLine: View {
    @ObservedObject var lyr = LyricsStore.shared
    @EnvironmentObject var s: Store
    @AppStorage("lyrics") var on = true

    var body: some View {
        if on {
            Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { s.lyricsOpen.toggle() } } label: {
                let i = lyr.index
                let txt: String = !lyr.lines.isEmpty
                    ? (i >= 0 && i < lyr.lines.count && !lyr.lines[i].text.isEmpty ? lyr.lines[i].text : "♪")
                    : (lyr.loading ? "Finding lyrics..." : (lyr.plain.isEmpty ? "" : "Lyrics (not timed) - click to read"))
                Text(txt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .id(txt)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.22), value: lyr.index)
            .frame(height: 16)
            .clipped()
        }
    }
}

/// The full lyrics: every line sung so far stays on screen, the current one is bright, the rest are faded.
/// It follows the song on its own. Click any line to jump the song to it.
struct LyricsPanel: View {
    @ObservedObject var lyr = LyricsStore.shared
    @EnvironmentObject var s: Store
    @AppStorage("accent") var accent = "green"

    var body: some View {
        Group {
            if !lyr.lines.isEmpty { synced }
            else if !lyr.plain.isEmpty { unsynced }
            else {
                VStack(spacing: 6) {
                    Image(systemName: lyr.loading ? "ellipsis" : "text.quote").font(.system(size: 22)).foregroundColor(.gray)
                    Text(lyr.loading ? "Finding lyrics..." : "No lyrics found for this song").font(.caption).foregroundColor(.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var synced: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 9) {
                    Color.clear.frame(height: 40)
                    ForEach(0..<lyr.lines.count, id: \.self) { i in
                        let d = lyr.index - i                      // > 0 = already sung
                        let cur = d == 0
                        Text(lyr.lines[i].text.isEmpty ? "♪" : lyr.lines[i].text)
                            .font(.system(size: cur ? 19 : 15, weight: cur ? .bold : .semibold))
                            .foregroundColor(cur ? Color.white : Color.white.opacity(d > 0 ? 0.5 : 0.3))
                            .scaleEffect(cur ? 1.0 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { s.seek(lyr.lines[i].t) }
                            .id(i)
                            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: lyr.index)
                    }
                    Color.clear.frame(height: 60)
                }.padding(.horizontal, 4)
            }
            .onChange(of: lyr.index) { i in
                guard i >= 0 else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { proxy.scrollTo(i, anchor: .center) }
            }
            .onAppear { if lyr.index >= 0 { proxy.scrollTo(lyr.index, anchor: .center) } }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                      .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    var unsynced: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<lyr.plain.count, id: \.self) { i in
                    Text(lyr.plain[i].isEmpty ? " " : lyr.plain[i]).font(.system(size: 14, weight: .medium)).foregroundColor(Color.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 4).padding(.vertical, 8)
        }
    }
}
