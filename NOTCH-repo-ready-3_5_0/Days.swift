import SwiftUI
import AppKit

// Days card (Notes tab): countdowns you name, e.g. "Holiday" or "Exam". Add as many as you like and set how many
// days are left. The number drops by one each day by itself; after the day it counts how many days ago it was.

struct DayItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var target: Date
    var color: String
}

final class DaysModel: ObservableObject {
    static let shared = DaysModel()

    @Published var items: [DayItem] = []
    @Published var index = 0
    @Published var editing = false

    static var today: Date { Calendar.current.startOfDay(for: Date()) }

    static func inDays(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: today) ?? today
    }

    static func daysLeft(_ i: DayItem) -> Int {
        Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: i.target)).day ?? 0
    }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "dayList"), let list = try? JSONDecoder().decode([DayItem].self, from: data) { items = list }
        if items.isEmpty { items = [DayItem(id: UUID().uuidString, name: "Countdown", target: DaysModel.inDays(7), color: "pink")] }
        index = min(max(0, d.integer(forKey: "dayIndex")), items.count - 1)
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "dayList") }
        UserDefaults.standard.set(index, forKey: "dayIndex")
    }

    var current: DayItem? { items.indices.contains(index) ? items[index] : nil }

    func step(_ d: Int) {
        guard items.count > 1 else { return }
        index = (index + d + items.count) % items.count
        save()
    }

    func setName(_ t: String) {
        guard items.indices.contains(index) else { return }
        items[index].name = String(t.prefix(24))
        save()
    }

    func setColor(_ c: String) {
        guard items.indices.contains(index) else { return }
        items[index].color = c
        save()
    }

    /// Sets how many days from today the countdown lands on.
    func setDays(_ n: Int) {
        guard items.indices.contains(index) else { return }
        items[index].target = DaysModel.inDays(max(-36500, min(36500, n)))
        save()
    }

    func adjust(_ d: Int) {
        guard let c = current else { return }
        setDays(DaysModel.daysLeft(c) + d)
    }

    func add() {
        let n = items.count + 1
        let colour = colorNames[n % colorNames.count]
        items.append(DayItem(id: UUID().uuidString, name: "Countdown \(n)", target: DaysModel.inDays(7), color: colour == "white" ? "pink" : colour))
        index = items.count - 1
        save()
    }

    func remove() {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if items.isEmpty { items = [DayItem(id: UUID().uuidString, name: "Countdown", target: DaysModel.inDays(7), color: "pink")] }
        index = min(index, items.count - 1)
        save()
    }
}

struct DaysCard: View {
    @ObservedObject var m = DaysModel.shared

    func icon(_ name: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: name).font(.system(size: 11)).foregroundColor(.gray).frame(width: 18, height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func stepBtn(_ name: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: name).font(.system(size: 17)).foregroundColor(Color.white.opacity(0.85)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func caption(_ n: Int) -> String {
        if n == 0 { return "is the day" }
        if n > 0 { return n == 1 ? "day to go" : "days to go" }
        return n == -1 ? "day ago" : "days ago"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Group { if m.editing { editor } else { face } }
        }
        .padding(10)
        .frame(width: m.editing ? 230 : 156)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.08)).cornerRadius(10)
        .animation(.easeOut(duration: 0.18), value: m.editing)
    }

    var face: some View {
        let it = m.current ?? DayItem(id: "x", name: "Countdown", target: DaysModel.inDays(7), color: "pink")
        let n = DaysModel.daysLeft(it)
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                if m.items.count > 1 { icon("chevron.left") { m.step(-1) } }
                Text(it.name).font(.caption).foregroundColor(.gray).lineLimit(1)
                if m.items.count > 1 { icon("chevron.right") { m.step(1) } }
                Spacer(minLength: 0)
                icon("slider.horizontal.3") { m.editing = true }
            }
            VStack(spacing: 0) {
                Text(n == 0 ? "Today" : "\(abs(n))")
                    .font(.system(size: n == 0 ? 28 : 40, weight: .light)).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundColor(n < 0 ? Color.gray : presetColor(it.color))
                Text(caption(n)).font(.system(size: 9)).foregroundColor(.gray).lineLimit(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if m.items.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<min(m.items.count, 8), id: \.self) { i in
                        Circle().fill(i == m.index ? Color.white : Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    }
                }
            }
            HStack(spacing: 14) {
                stepBtn("minus.circle") { m.adjust(-1) }
                stepBtn("plus.circle") { m.adjust(1) }
            }
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Name", text: Binding(get: { m.current?.name ?? "" }, set: { m.setName($0) }))
                .textFieldStyle(.roundedBorder).font(.caption)
            HStack(spacing: 6) {
                Text("Days").font(.caption).foregroundColor(.gray).frame(width: 34, alignment: .leading)
                TextField("", value: Binding(get: { m.current.map { DaysModel.daysLeft($0) } ?? 0 }, set: { m.setDays($0) }), format: .number)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(width: 58)
                Text("from today").font(.system(size: 9)).foregroundColor(.gray).lineLimit(1)
            }
            HStack(spacing: 3) {
                ForEach(colorNames.filter { $0 != "white" }, id: \.self) { n in
                    Circle().fill(presetColor(n)).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: m.current?.color == n ? 2 : 0))
                        .onTapGesture { m.setColor(n) }
                }
            }
            HStack(spacing: 8) {
                Button("Add another") { m.add() }.font(.caption)
                Button("Delete") { m.remove() }.font(.caption)
                Spacer(minLength: 0)
                Button("Done") { m.editing = false }.font(.caption)
            }
            Text("\(m.index + 1) of \(m.items.count)").font(.system(size: 9)).foregroundColor(.gray)
        }
    }
}
