import SwiftUI
import Foundation

// MARK: Live lyrics under the song title (Spotify and Music). Synced lyrics come from the free LRCLIB service;
// only the song name, artist and length are sent. Turn it off in Settings > Music.

struct LyricLine {
    let t: Double
    let text: String
}

final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published var lines: [LyricLine] = []
    private var key = ""

    func load(track: String, artist: String, duration: Double) {
        guard UserDefaults.standard.bool(forKey: "lyrics"), !track.isEmpty else { lines = []; key = ""; return }
        let k = track + "|" + artist
        if k == key { return }
        key = k
        lines = []
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return }
        var items = [URLQueryItem(name: "track_name", value: track), URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        comps.queryItems = items
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("NOTCH-for-Mac", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = j["syncedLyrics"] as? String else { return }
            let parsed = LyricsStore.parse(lrc)
            DispatchQueue.main.async { if self?.key == k { self?.lines = parsed } }
        }.resume()
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        guard let re = try? NSRegularExpression(pattern: "^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]\\s*(.*)$") else { return [] }
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let ns = raw as NSString
            guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let text = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            out.append(LyricLine(t: mm * 60 + ss, text: text))
        }
        return out.sorted { $0.t < $1.t }
    }

    /// The line being sung at `t` seconds into the song.
    func line(at t: Double) -> String {
        var cur = ""
        for l in lines {
            if l.t <= t + 0.2 { cur = l.text } else { break }
        }
        return cur
    }
}

struct LyricsLine: View {
    @ObservedObject var lyr = LyricsStore.shared
    @AppStorage("lyrics") var on = true

    var body: some View {
        if on && !lyr.lines.isEmpty {
            TimelineView(.periodic(from: Date(), by: 0.4)) { _ in
                Text(lyr.line(at: Store.shared.curPos()))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}
