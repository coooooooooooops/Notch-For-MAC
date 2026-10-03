import SwiftUI
import AppKit
import CryptoKit

// Clipboard image history. Deliberately small: the last 10 images only, shown as little thumbnails, kept on disk
// (not in memory) and wiped every time NOTCH starts. Text history is handled in Store as before.

final class ClipImage: Identifiable {
    let id: String
    let url: URL
    let thumb: NSImage
    init(id: String, url: URL, thumb: NSImage) { self.id = id; self.url = url; self.thumb = thumb }
}

final class ClipImages: ObservableObject {
    static let shared = ClipImages()
    static let maxItems = 10
    static let maxBytes = 60_000_000      // total on disk
    static let skipBytes = 25_000_000     // a single huge image is ignored

    @Published var items: [ClipImage] = []
    let dir: URL

    init() {
        dir = Updater.support.appendingPathComponent("clips")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Called when the clipboard changes and holds no text. Files copied in Finder are ignored.
    func capture(_ pb: NSPasteboard) {
        if pb.types?.contains(.fileURL) == true { return }
        guard let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff), raw.count < ClipImages.skipBytes else { return }
        let isPNG = pb.data(forType: .png) != nil
        DispatchQueue.global(qos: .utility).async {
            var png = raw
            if !isPNG {
                guard let rep = NSBitmapImageRep(data: raw), let p = rep.representation(using: .png, properties: [:]) else { return }
                png = p
            }
            let id = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined().prefix(24).description
            let url = self.dir.appendingPathComponent(id + ".png")
            if !FileManager.default.fileExists(atPath: url.path) { guard (try? png.write(to: url)) != nil else { return } }
            guard let full = NSImage(data: png) else { return }
            let thumb = ClipImages.makeThumb(full, maxSide: 120)
            DispatchQueue.main.async {
                self.items.removeAll { $0.id == id }
                self.items.insert(ClipImage(id: id, url: url, thumb: thumb), at: 0)
                self.trim()
            }
        }
    }

    static func makeThumb(_ img: NSImage, maxSide: CGFloat) -> NSImage {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return img }
        let k = min(1, maxSide / max(s.width, s.height))
        let ts = NSSize(width: max(1, s.width * k), height: max(1, s.height * k))
        return NSImage(size: ts, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }

    func trim() {
        while items.count > ClipImages.maxItems { remove(items[items.count - 1]) }
        var total = 0
        for it in items {
            total += (try? it.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        while total > ClipImages.maxBytes, items.count > 1, let last = items.last {
            total -= (try? last.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            remove(last)
        }
    }

    func remove(_ it: ClipImage) {
        try? FileManager.default.removeItem(at: it.url)
        items.removeAll { $0.id == it.id }
    }

    func clear() {
        for it in items { try? FileManager.default.removeItem(at: it.url) }
        items = []
    }

    /// Puts the image back on the clipboard (and keeps it out of the history as a "new" copy).
    func copy(_ it: ClipImage) {
        guard let img = NSImage(contentsOf: it.url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        Store.shared.lastPB = pb.changeCount
    }
}

/// Small strip of image thumbnails shown above the text history.
struct ClipImageStrip: View {
    @ObservedObject var imgs = ClipImages.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 10)).foregroundColor(.gray)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(imgs.items) { it in
                        Button { imgs.copy(it) } label: {
                            Image(nsImage: it.thumb).resizable().scaledToFill()
                                .frame(width: 42, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy it again, or drag it out")
                        .onDrag { NSItemProvider(contentsOf: it.url) ?? NSItemProvider() }
                        .contextMenu {
                            Button("Copy") { imgs.copy(it) }
                            Button("Delete") { imgs.remove(it) }
                        }
                    }
                }
            }
        }.frame(height: 36)
    }
}
