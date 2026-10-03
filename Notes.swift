import SwiftUI
import AppKit

// Notes tab: as many notes as you like, each with a name at the top. The list button takes you to all of them.
// The note you were on stays open (even after the notch closes) until you press the list button yourself.

struct Note: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var modified: Date

    var shownTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        let first = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.isEmpty ? "Untitled" : String(first.prefix(40))
    }
    var snippet: String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let skip = title.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : 0     // the first line is already used as the title
        return lines.count > skip ? lines[skip] : ""
    }
}

final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published var notes: [Note] = []
    @Published var currentID: String = ""
    @Published var showList = false

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "noteList"), let n = try? JSONDecoder().decode([Note].self, from: data) { notes = n }
        if notes.isEmpty {
            // first launch of this version: the single old note becomes the first note
            let old = d.string(forKey: "notes") ?? ""
            notes = [Note(id: UUID().uuidString, title: old.isEmpty ? "" : "Notes", text: old, modified: Date())]
        }
        let saved = d.string(forKey: "noteCurrent") ?? ""
        currentID = notes.contains(where: { $0.id == saved }) ? saved : (notes.first?.id ?? "")
        save()
    }

    var currentIndex: Int? { notes.firstIndex { $0.id == currentID } }
    var current: Note? { currentIndex.map { notes[$0] } }

    func save() {
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: "noteList") }
        UserDefaults.standard.set(currentID, forKey: "noteCurrent")
    }

    func newNote() {
        let n = Note(id: UUID().uuidString, title: "", text: "", modified: Date())
        notes.insert(n, at: 0)
        currentID = n.id; showList = false
        save()
    }

    func open(_ n: Note) { currentID = n.id; showList = false; save() }

    func delete(_ n: Note) {
        notes.removeAll { $0.id == n.id }
        if notes.isEmpty { notes = [Note(id: UUID().uuidString, title: "", text: "", modified: Date())] }
        if !notes.contains(where: { $0.id == currentID }) { currentID = notes.first?.id ?? "" }
        save()
    }

    func setTitle(_ t: String) {
        guard let i = currentIndex, notes[i].title != t else { return }
        notes[i].title = t; notes[i].modified = Date(); save()
    }

    func setText(_ t: String) {
        guard let i = currentIndex, notes[i].text != t else { return }
        notes[i].text = t; notes[i].modified = Date(); save()
        // hidden commands typed into any note still work; the command line is removed
        if let cleaned = Store.shared.runCode(t) {
            DispatchQueue.main.async {
                if let j = self.currentIndex { self.notes[j].text = cleaned; self.save() }
            }
        }
    }

    /// Most recently edited first.
    var sorted: [Note] { notes.sorted { $0.modified > $1.modified } }
}

struct NotesPane: View {
    @ObservedObject var m = NotesModel.shared
    @AppStorage("accent") var accent = "green"

    func miniBtn(_ n: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: n).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24)
                .background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var editor: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                miniBtn("list.bullet") { m.showList = true }.help("All notes")
                TextField("Untitled", text: Binding(get: { m.current?.title ?? "" }, set: { m.setTitle($0) }))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 7))
                miniBtn("plus") { m.newNote() }.help("New note")
            }
            TextEditor(text: Binding(get: { m.current?.text ?? "" }, set: { m.setText($0) }))
                .scrollContentBackground(.hidden).background(Color.white.opacity(0.08)).cornerRadius(10)
        }
    }

    func dateText(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    var list: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                miniBtn("chevron.left") { m.showList = false }.help("Back to the note")
                Text("Notes").font(.system(size: 13, weight: .semibold))
                Text("\(m.notes.count)").font(.caption).foregroundColor(.gray)
                Spacer()
                Button { m.newNote() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New").font(.system(size: 11, weight: .medium))
                    }.padding(.horizontal, 9).padding(.vertical, 4).background(Color.white.opacity(0.12)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(m.sorted) { n in
                        HStack(spacing: 6) {
                            Button { m.open(n) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(n.shownTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        if !n.snippet.isEmpty { Text(n.snippet).font(.system(size: 10)).foregroundColor(.gray).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                    Text(dateText(n.modified)).font(.system(size: 9)).foregroundColor(.gray)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { m.delete(n) } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.gray).frame(width: 20, height: 20).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Delete note")
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(n.id == m.currentID ? presetColor(accent).opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contextMenu { Button("Delete") { m.delete(n) } }
                    }
                }
            }
        }
    }

    var body: some View {
        Group { if m.showList { list } else { editor } }
    }
}
