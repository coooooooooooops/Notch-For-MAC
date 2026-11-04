import SwiftUI
import AppKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: Stage 3: shelf tools. Zip / unzip, convert, share, copy text out of images, scan text from the screen,
// remove an image background. Everything heavy runs in the background; results land back on the shelf.

enum FileTools {
    static var picker: NSSharingServicePicker?

    static let outDir: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("NOTCH-tools")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    enum Kind { case image, video, audio, zip, other }

    static func kind(_ u: URL) -> Kind {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .zip) { return .zip }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) { return .video }
        if t.conforms(to: .audio) { return .audio }
        return .other
    }

    /// A file name inside the scratch folder that does not exist yet ("Photo.png", "Photo 1.png", ...).
    static func unique(name: String, ext: String) -> URL {
        let fm = FileManager.default
        var n = 0
        while true {
            let leaf = n == 0 ? name : "\(name) \(n)"
            let u = outDir.appendingPathComponent(ext.isEmpty ? leaf : leaf + "." + ext)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Runs a job in the background with a message on screen, then puts whatever it made on the shelf.
    static func work(_ message: String, _ job: @escaping () -> [URL]?) {
        Store.shared.say(message, hold: 120)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = job()
            DispatchQueue.main.async {
                let s = Store.shared
                if let out = out, !out.isEmpty {
                    for u in out where !s.files.contains(u) { s.files.append(u) }
                    s.say("Done. It's on the shelf")
                } else {
                    s.say("That didn't work")
                }
            }
        }
    }

    // MARK: zip / unzip
    static func zip(_ urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let fm = FileManager.default
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let holder = outDir.appendingPathComponent(UUID().uuidString)
        let stage = holder.appendingPathComponent(base)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for u in urls { try? fm.copyItem(at: u, to: stage.appendingPathComponent(u.lastPathComponent)) }
        let out = unique(name: base, ext: "zip")
        let rc = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", stage.path, out.path])
        try? fm.removeItem(at: holder)
        return (rc == 0 && fm.fileExists(atPath: out.path)) ? out : nil
    }

    static func unzip(_ u: URL) -> [URL]? {
        let fm = FileManager.default
        let dest = unique(name: u.deletingPathExtension().lastPathComponent, ext: "")
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", u.path, dest.path]) == 0 else { return nil }
        let items = ((try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        return items.count == 1 ? items : [dest]
    }

    static func zipAll(_ urls: [URL]) { work("Zipping...") { zip(urls).map { [$0] } } }

    // MARK: convert
    static func convertImage(_ u: URL, _ format: String) -> URL? {
        let ext = format == "jpeg" ? "jpg" : format
        let out = unique(name: u.deletingPathExtension().lastPathComponent, ext: ext)
        let rc = run("/usr/bin/sips", ["-s", "format", format, u.path, "--out", out.path])
        return (rc == 0 && FileManager.default.fileExists(atPath: out.path)) ? out : nil
    }

    static func convertVideo(_ u: URL) -> URL? {
        let out = unique(name: u.deletingPathExtension().lastPathComponent + " 720p", ext: "m4v")
        let rc = run("/usr/bin/avconvert", ["--preset", "PresetAppleM4V720pHD", "--source", u.path, "--output", out.path, "--replace"])
        return (rc == 0 && FileManager.default.fileExists(atPath: out.path)) ? out : nil
    }

    static func convertAudio(_ u: URL) -> URL? {
        let out = unique(name: u.deletingPathExtension().lastPathComponent, ext: "m4a")
        let rc = run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", u.path, out.path])
        return (rc == 0 && FileManager.default.fileExists(atPath: out.path)) ? out : nil
    }

    // MARK: share
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView else { return }
        let p = NSSharingServicePicker(items: urls)
        picker = p
        p.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 24, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    // MARK: text from images (Vision)
    static func cgImage(_ u: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func ocr(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let h = VNImageRequestHandler(cgImage: cg, options: [:])
        try? h.perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func putText(_ text: String) {
        let s = Store.shared
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.say("No text found"); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSSound(named: NSSound.Name("Pop"))?.play()
        s.say("Copied \(text.count) characters")
    }

    static func copyText(from u: URL) {
        Store.shared.say("Reading text...", hold: 60)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = cgImage(u).map { ocr($0) } ?? ""
            DispatchQueue.main.async { putText(text) }
        }
    }

    /// Drag a box on the screen; the text inside it is copied.
    static func scanScreenText() {
        DispatchQueue.global(qos: .userInitiated).async {
            let before = NSPasteboard.general.changeCount
            let rc = run("/usr/sbin/screencapture", ["-i", "-x", "-c"])
            let pb = NSPasteboard.general
            guard rc == 0, pb.changeCount != before,
                  let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                  let cg = NSBitmapImageRep(data: data)?.cgImage else { return }
            let text = ocr(cg)
            DispatchQueue.main.async { putText(text) }
        }
    }

    // MARK: remove background (macOS 14 and later)
    static func removeBackground(_ u: URL) -> URL? {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            guard let ci = CIImage(contentsOf: u) else { return nil }
            let handler = VNImageRequestHandler(ciImage: ci, options: [:])
            let req = VNGenerateForegroundInstanceMaskRequest()
            do { try handler.perform([req]) } catch { return nil }
            guard let obs = req.results?.first,
                  let buf = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false) else { return nil }
            let out = CIImage(cvPixelBuffer: buf)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let png = CIContext().pngRepresentation(of: out, format: .RGBA8, colorSpace: space) else { return nil }
            let dest = unique(name: u.deletingPathExtension().lastPathComponent + " (no background)", ext: "png")
            do { try png.write(to: dest) } catch { return nil }
            return dest
        }
        #endif
        return nil
    }
}

// MARK: shelf menu, shelf buttons and the little message bubble
extension RootView {
    @ViewBuilder func shelfMenu(_ u: URL) -> some View {
        let k = FileTools.kind(u)
        Button("Remove") { s.files.removeAll { $0 == u } }
        Divider()
        if k == .zip { Button("Unzip") { FileTools.work("Unzipping...") { FileTools.unzip(u) } } }
        Button("Zip") { FileTools.work("Zipping...") { FileTools.zip([u]).map { [$0] } } }
        if k == .image {
            Menu("Convert to") {
                Button("PNG") { FileTools.work("Converting...") { FileTools.convertImage(u, "png").map { [$0] } } }
                Button("JPEG") { FileTools.work("Converting...") { FileTools.convertImage(u, "jpeg").map { [$0] } } }
                Button("HEIC") { FileTools.work("Converting...") { FileTools.convertImage(u, "heic").map { [$0] } } }
                Button("TIFF") { FileTools.work("Converting...") { FileTools.convertImage(u, "tiff").map { [$0] } } }
            }
            Button("Copy text from image") { FileTools.copyText(from: u) }
            if #available(macOS 14.0, *) {
                Button("Remove background") { FileTools.work("Removing background...") { FileTools.removeBackground(u).map { [$0] } } }
            }
        }
        if k == .video { Button("Convert to 720p M4V") { FileTools.work("Converting video...") { FileTools.convertVideo(u).map { [$0] } } } }
        if k == .audio { Button("Convert to M4A") { FileTools.work("Converting audio...") { FileTools.convertAudio(u).map { [$0] } } } }
        Divider()
        Button("Share...") { FileTools.share([u]) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    var shelfTools: some View {
        VStack(spacing: 6) {
            btn("doc.zipper") { FileTools.zipAll(s.files) }
                .help("Zip everything on the shelf")
                .opacity(s.files.isEmpty ? 0.3 : 1).disabled(s.files.isEmpty)
            btn("square.and.arrow.up") { FileTools.share(s.files) }
                .help("Share the shelf")
                .opacity(s.files.isEmpty ? 0.3 : 1).disabled(s.files.isEmpty)
            btn("text.viewfinder") { FileTools.scanScreenText() }
                .help("Drag a box on the screen to copy the text in it")
        }.frame(width: 34)
    }

    @ViewBuilder var toastView: some View {
        if !s.toast.isEmpty {
            Text(s.toast)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(GlassIf(shape: Capsule(), tint: nil, interactive: false, classic: Color.white.opacity(0.18)))
                .padding(.bottom, 6)
                .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)).combined(with: .offset(x: 0, y: 8)))
        }
    }
}
