import SwiftUI
import AppKit

// Weather tab. Free data from Open-Meteo (no account or key). Search for a place, save as many as you like, pick one.
// Your saved places and the one you were looking at stay put until you change them yourself.

let weatherTab = 15   // index of the Weather tab in RootView.icons

struct Place: Codable, Identifiable, Equatable {
    var id: String          // "lat,lon" so the same place can't be saved twice
    var name: String
    var region: String      // state / country line shown under the name
    var lat: Double
    var lon: Double
}

// MARK: Open-Meteo responses (everything optional so one odd field can't break the whole decode)
private struct GeoResponse: Decodable {
    struct R: Decodable { var name: String?; var latitude: Double?; var longitude: Double?; var country: String?; var admin1: String? }
    var results: [R]?
}

private struct Forecast: Decodable {
    struct Cur: Decodable {
        var time: String?
        var temperature_2m: Double?
        var apparent_temperature: Double?
        var relative_humidity_2m: Double?
        var weather_code: Int?
        var wind_speed_10m: Double?
        var is_day: Int?
    }
    struct Hourly: Decodable {
        var time: [String]?
        var temperature_2m: [Double?]?
        var weather_code: [Int?]?
        var precipitation_probability: [Int?]?
        var is_day: [Int?]?
    }
    struct Daily: Decodable {
        var time: [String]?
        var weather_code: [Int?]?
        var temperature_2m_max: [Double?]?
        var temperature_2m_min: [Double?]?
        var precipitation_probability_max: [Int?]?
    }
    var utc_offset_seconds: Int?
    var current: Cur?
    var hourly: Hourly?
    var daily: Daily?
}

struct HourInfo: Identifiable { let id: Int; let label: String; let temp: Double; let code: Int; let rain: Int; let day: Bool }
struct DayInfo: Identifiable { let id: Int; let label: String; let hi: Double; let lo: Double; let code: Int; let rain: Int }
struct Wx {
    var temp: Double; var feels: Double; var humidity: Int; var wind: Double; var code: Int; var day: Bool
    var hi: Double; var lo: Double
    var hours: [HourInfo]; var days: [DayInfo]
    var fetched: Date
}

func wxText(_ code: Int) -> String {
    switch code {
    case 0: return "Clear"
    case 1: return "Mostly clear"
    case 2: return "Partly cloudy"
    case 3: return "Overcast"
    case 45, 48: return "Fog"
    case 51, 53, 55: return "Drizzle"
    case 56, 57: return "Freezing drizzle"
    case 61: return "Light rain"
    case 63: return "Rain"
    case 65: return "Heavy rain"
    case 66, 67: return "Freezing rain"
    case 71: return "Light snow"
    case 73: return "Snow"
    case 75: return "Heavy snow"
    case 77: return "Snow grains"
    case 80, 81: return "Showers"
    case 82: return "Heavy showers"
    case 85, 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm, hail"
    default: return "Unknown"
    }
}

func wxIcon(_ code: Int, day: Bool = true) -> String {
    switch code {
    case 0: return day ? "sun.max.fill" : "moon.stars.fill"
    case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
    case 61, 63, 80, 81: return "cloud.rain.fill"
    case 65, 82: return "cloud.heavyrain.fill"
    case 66, 67: return "cloud.sleet.fill"
    case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
    case 95: return "cloud.bolt.rain.fill"
    case 96, 99: return "cloud.bolt.fill"
    default: return "cloud.fill"
    }
}

final class WeatherModel: ObservableObject {
    static let shared = WeatherModel()

    @Published var places: [Place] = []
    @Published var selected: String = ""             // Place.id
    @Published var wx: Wx? = nil
    @Published var loading = false
    @Published var failed = false
    @Published var searching = false                 // search screen showing
    @Published var query = ""
    @Published var results: [Place] = []
    @Published var searchBusy = false
    @Published var searchNote = ""
    @Published var fahrenheit: Bool { didSet { UserDefaults.standard.set(fahrenheit, forKey: "wxF") } }

    var loadedFor = ""
    var pending: DispatchWorkItem?

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "wxF") == nil { fahrenheit = !Locale.current.usesMetricSystem } else { fahrenheit = d.bool(forKey: "wxF") }
        if let data = d.data(forKey: "wxPlaces"), let p = try? JSONDecoder().decode([Place].self, from: data) { places = p }
        selected = d.string(forKey: "wxSelected") ?? ""
        if !places.contains(where: { $0.id == selected }) { selected = places.first?.id ?? "" }
        searching = places.isEmpty
    }

    var current: Place? { places.first { $0.id == selected } }

    func save() {
        if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "wxPlaces") }
        UserDefaults.standard.set(selected, forKey: "wxSelected")
    }

    func select(_ p: Place) {
        selected = p.id; save()
        searching = false
        wx = nil; failed = false
        refresh(force: true)
    }

    func add(_ p: Place) {
        if !places.contains(where: { $0.id == p.id }) { places.append(p) }
        query = ""; results = []; searchNote = ""
        select(p)
    }

    func remove(_ p: Place) {
        places.removeAll { $0.id == p.id }
        if selected == p.id { selected = places.first?.id ?? ""; wx = nil; loadedFor = "" }
        if places.isEmpty { searching = true }
        save()
        if !selected.isEmpty && wx == nil { refresh(force: true) }
    }

    // MARK: search
    func scheduleSearch() {
        pending?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 { results = []; searchNote = ""; searchBusy = false; return }
        let w = DispatchWorkItem { [weak self] in self?.runSearch(q) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func runSearch(_ q: String) {
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=8&language=en&format=json") else { return }
        searchBusy = true
        URLSession.shared.dataTask(with: url) { data, _, err in
            var out: [Place] = []
            var note = ""
            if let data = data, let g = try? JSONDecoder().decode(GeoResponse.self, from: data) {
                for r in g.results ?? [] {
                    guard let n = r.name, let la = r.latitude, let lo = r.longitude else { continue }
                    let reg = [r.admin1, r.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                    out.append(Place(id: String(format: "%.3f,%.3f", la, lo), name: n, region: reg, lat: la, lon: lo))
                }
                if out.isEmpty { note = "No places found" }
            } else { note = err == nil ? "Couldn't read the search results" : "No connection" }
            DispatchQueue.main.async {
                if q != self.query.trimmingCharacters(in: .whitespaces) { return }     // an older search finished late
                self.results = out; self.searchNote = note; self.searchBusy = false
            }
        }.resume()
    }

    // MARK: forecast
    /// Reloads if the data is older than 10 minutes (or `force`).
    func refresh(force: Bool = false) {
        guard let p = current else { return }
        if !force, loadedFor == p.id, let w = wx, Date().timeIntervalSince(w.fetched) < 600 { return }
        if loading { return }
        let urlS = "https://api.open-meteo.com/v1/forecast?latitude=\(p.lat)&longitude=\(p.lon)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
            + "&hourly=temperature_2m,weather_code,precipitation_probability,is_day"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=auto&forecast_days=7"
        guard let url = URL(string: urlS) else { return }
        loading = true; failed = false
        let want = p.id
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var result: Wx? = nil
            if let data = data, let f = try? JSONDecoder().decode(Forecast.self, from: data) { result = WeatherModel.build(f) }
            DispatchQueue.main.async {
                self.loading = false
                if want != self.selected { return }                    // switched place while loading
                if let r = result { self.wx = r; self.loadedFor = want; self.failed = false } else if self.wx == nil { self.failed = true }
            }
        }.resume()
    }

    private static func build(_ f: Forecast) -> Wx? {
        guard let c = f.current, let t = c.temperature_2m else { return nil }
        let tz = TimeZone(secondsFromGMT: f.utc_offset_seconds ?? 0) ?? .current
        let hf = DateFormatter(); hf.locale = Locale(identifier: "en_US_POSIX"); hf.timeZone = tz; hf.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = tz; df.dateFormat = "yyyy-MM-dd"
        let nameF = DateFormatter(); nameF.timeZone = tz; nameF.dateFormat = "EEE"
        let hourF = DateFormatter(); hourF.timeZone = tz; hourF.dateFormat = "ha"

        // "now" in the place's own clock, so the hourly strip starts at the right hour
        let nowD: Date = c.time.flatMap { hf.date(from: $0) } ?? Date()
        var hours: [HourInfo] = []
        if let h = f.hourly, let times = h.time {
            for (i, ts) in times.enumerated() {
                guard let d = hf.date(from: ts), d >= nowD.addingTimeInterval(-3000), hours.count < 12 else { continue }
                let temp: Double = (h.temperature_2m.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? t
                let code: Int = (h.weather_code.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? 0
                let rain: Int = (h.precipitation_probability.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? 0
                let day: Bool = ((h.is_day.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? 1) != 0
                let label = hours.isEmpty ? "Now" : hourF.string(from: d).lowercased()
                hours.append(HourInfo(id: i, label: label, temp: temp, code: code, rain: rain, day: day))
            }
        }
        var days: [DayInfo] = []
        var hi = t, lo = t
        if let d = f.daily, let times = d.time {
            for (i, ts) in times.enumerated() {
                let h: Double = (d.temperature_2m_max.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? t
                let l: Double = (d.temperature_2m_min.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? t
                let code: Int = (d.weather_code.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? 0
                let rain: Int = (d.precipitation_probability_max.flatMap { $0.indices.contains(i) ? $0[i] : nil }) ?? 0
                if i == 0 { hi = h; lo = l }
                let label = i == 0 ? "Today" : (df.date(from: ts).map { nameF.string(from: $0) } ?? ts)
                days.append(DayInfo(id: i, label: label, hi: h, lo: l, code: code, rain: rain))
            }
        }
        return Wx(temp: t, feels: c.apparent_temperature ?? t, humidity: Int((c.relative_humidity_2m ?? 0).rounded()),
                  wind: c.wind_speed_10m ?? 0, code: c.weather_code ?? 0, day: (c.is_day ?? 1) != 0,
                  hi: hi, lo: lo, hours: hours, days: days, fetched: Date())
    }

    // MARK: display helpers (data is stored in °C and km/h)
    func deg(_ c: Double) -> String { "\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°" }
    func windText(_ kmh: Double) -> String { fahrenheit ? "\(Int((kmh / 1.609).rounded())) mph" : "\(Int(kmh.rounded())) km/h" }
}

struct WeatherView: View {
    @ObservedObject var m = WeatherModel.shared
    @AppStorage("accent") var accent = "green"

    func pill(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.white.opacity(0.12)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    func icon(_ code: Int, day: Bool, size: CGFloat) -> some View {
        Image(systemName: wxIcon(code, day: day)).symbolRenderingMode(.multicolor).font(.system(size: size))
    }

    // MARK: header with saved places
    var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(m.places) { p in
                        Button { m.select(p) } label: {
                            Text(p.name).font(.system(size: 11, weight: p.id == m.selected && !m.searching ? .semibold : .regular)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(p.id == m.selected && !m.searching ? presetColor(accent).opacity(0.35) : Color.white.opacity(0.1))
                                .clipShape(Capsule()).contentShape(Capsule())
                        }.buttonStyle(.plain)
                        .contextMenu { Button("Remove \(p.name)") { m.remove(p) } }
                    }
                    Button { m.searching = true } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 22)
                            .background(Color.white.opacity(0.1)).clipShape(Circle()).contentShape(Circle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            if m.loading { ProgressView().controlSize(.small) }
            pill(m.fahrenheit ? "°F" : "°C") { m.fahrenheit.toggle() }
            btn("arrow.clockwise") { m.refresh(force: true) }
        }
    }

    // MARK: search screen
    var searchScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !m.places.isEmpty { btn("chevron.left") { m.searching = false } }
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search for a city or town", text: $m.query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onChange(of: m.query) { _ in m.scheduleSearch() }
                if m.searchBusy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 9))

            ScrollView {
                VStack(spacing: 4) {
                    if !m.searchNote.isEmpty { Text(m.searchNote).font(.caption).foregroundColor(.gray).padding(.top, 6) }
                    ForEach(m.results) { r in
                        Button { m.add(r) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.name).font(.system(size: 12, weight: .medium))
                                    Text(r.region).font(.system(size: 10)).foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundColor(.gray)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if m.results.isEmpty && m.query.isEmpty && !m.places.isEmpty {
                        Text("Saved places").font(.caption).foregroundColor(.gray).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        ForEach(m.places) { p in
                            HStack {
                                Text(p.name).font(.system(size: 12)); Text(p.region).font(.system(size: 10)).foregroundColor(.gray)
                                Spacer()
                                Button { m.remove(p) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if m.places.isEmpty && m.query.isEmpty {
                        Text("Type a city to get started. Your places are saved, and the weather stays on the one you pick.")
                            .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center).padding(.top, 14)
                    }
                }
            }
        }
    }

    // MARK: forecast screen
    func forecast(_ w: Wx, _ p: Place) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    icon(w.code, day: w.day, size: 30)
                    Text(m.deg(w.temp)).font(.system(size: 42, weight: .light))
                }
                Text(wxText(w.code)).font(.system(size: 12))
                Text("Feels \(m.deg(w.feels))   H \(m.deg(w.hi))  L \(m.deg(w.lo))").font(.system(size: 10)).foregroundColor(.gray)
                Text("Humidity \(w.humidity)%   Wind \(m.windText(w.wind))").font(.system(size: 10)).foregroundColor(.gray)
            }.frame(width: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(w.hours) { h in
                            VStack(spacing: 3) {
                                Text(h.label).font(.system(size: 10)).foregroundColor(.gray)
                                icon(h.code, day: h.day, size: 15)
                                Text(m.deg(h.temp)).font(.system(size: 11, weight: .medium))
                                Text(h.rain >= 10 ? "\(h.rain)%" : " ").font(.system(size: 9)).foregroundColor(Color.cyan)
                            }.frame(width: 38)
                        }
                    }
                }
                Divider().opacity(0.3)
                HStack(spacing: 6) {
                    ForEach(w.days) { d in
                        VStack(spacing: 3) {
                            Text(d.label).font(.system(size: 10)).foregroundColor(.gray)
                            icon(d.code, day: true, size: 15)
                            Text(m.deg(d.hi)).font(.system(size: 11, weight: .medium))
                            Text(m.deg(d.lo)).font(.system(size: 10)).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(d.id == 0 ? Color.white.opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if m.searching { searchScreen }
            else if let w = m.wx, let p = m.current { forecast(w, p).frame(maxHeight: .infinity, alignment: .top) }
            else if m.failed {
                VStack(spacing: 8) {
                    Text("Couldn't load the weather. Check your connection.").font(.caption).foregroundColor(.gray)
                    pill("Try again") { m.refresh(force: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { m.refresh() }
    }
}
