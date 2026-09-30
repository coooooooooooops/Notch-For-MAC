import SwiftUI
import AppKit

// Snake for the notch. Completely silent (no sounds, no beeps - handled keys are swallowed so macOS never "bonks").
// Controls: arrows / WASD to steer, Space or P to pause, R to restart. Click the board to start / pause.

let gameTab = 12   // index of the game tab in RootView.icons

struct GridPt: Hashable { var x: Int; var y: Int }

enum Heading {
    case up, down, left, right
    var dx: Int { switch self { case .left: return -1; case .right: return 1; default: return 0 } }
    var dy: Int { switch self { case .up: return -1; case .down: return 1; default: return 0 } }
    var opposite: Heading {
        switch self { case .up: return .down; case .down: return .up; case .left: return .right; case .right: return .left }
    }
}

enum SnakePhase { case ready, playing, paused, over }

struct Particle { var x: Double; var y: Double; var vx: Double; var vy: Double; var born: Double; var life: Double; var size: Double; var color: Color }
struct Pop { var x: Double; var y: Double; var text: String; var born: Double; var color: Color; var big: Bool }

func shade(_ c: Color, _ bright: CGFloat, _ sat: CGFloat = 1) -> Color {
    let n = NSColor(c).usingColorSpace(.deviceRGB) ?? NSColor.green
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    n.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: Double(h), saturation: Double(min(1, s * sat)), brightness: Double(min(1, b * bright)))
}

final class SnakeGame: ObservableObject {
    static let shared = SnakeGame()
    static let cols = 24
    static let rows = 14

    @Published var phase: SnakePhase = .ready
    @Published var score = 0
    @Published var best = 0
    @Published var length = 3
    @Published var level = 1
    @Published var newBest = false
    @Published var won = false
    @Published var wrap: Bool = UserDefaults.standard.bool(forKey: "snakeWrap") {
        didSet { UserDefaults.standard.set(wrap, forKey: "snakeWrap"); reset() }
    }

    // Frame-by-frame state (read by the Canvas every frame, so not @Published)
    var cells: [GridPt] = []
    var prev: [GridPt] = []
    var heading: Heading = .right
    var queue: [Heading] = []
    var food = GridPt(x: -1, y: -1)
    var bonus: GridPt?
    var bonusBorn = 0.0
    let bonusLife = 7.0
    var eaten = 0
    var pendingGrow = 0
    var interval = 0.16
    var lastStep = 0.0
    var frozenP = 1.0
    var deathTime = 0.0
    var startBest = 0
    var particles: [Particle] = []
    var pops: [Pop] = []
    var timer: Timer?
    var monitor: Any?

    init() { reset() }

    var bestKey: String { wrap ? "snakeBestWrap" : "snakeBestWalls" }
    func now() -> Double { Date().timeIntervalSinceReferenceDate }

    // MARK: lifecycle
    func reset() {
        let cy = SnakeGame.rows / 2
        cells = [GridPt(x: 6, y: cy), GridPt(x: 5, y: cy), GridPt(x: 4, y: cy)]
        prev = cells
        heading = .right; queue = []
        eaten = 0; pendingGrow = 0; interval = 0.16
        score = 0; length = 3; level = 1; newBest = false; won = false
        bonus = nil; particles = []; pops = []; frozenP = 1
        food = GridPt(x: -1, y: -1)
        best = UserDefaults.standard.integer(forKey: bestKey)
        startBest = best
        phase = .ready
        placeFood()
    }

    func begin() {
        guard phase == .ready else { return }
        lastStep = now()
        phase = .playing
    }
    func pause() {
        guard phase == .playing else { return }
        frozenP = progress(now())
        phase = .paused
    }
    func resume() {
        guard phase == .paused else { return }
        lastStep = now() - frozenP * interval
        phase = .playing
    }
    func toggle() {
        switch phase {
        case .ready: begin()
        case .playing: pause()
        case .paused: resume()
        case .over: restart()
        }
    }
    func restart() { reset(); begin() }

    func progress(_ t: Double) -> Double {
        switch phase {
        case .playing: return min(1, max(0, (t - lastStep) / interval))
        case .paused: return frozenP
        default: return 1
        }
    }

    // MARK: input
    func turn(_ d: Heading) {
        switch phase {
        case .over: return
        case .ready:
            if d != .left { heading = d }
            begin()
            return
        case .paused: resume()
        case .playing: break
        }
        let last = queue.last ?? heading
        if d == last || d == last.opposite { return }
        if queue.count < 2 { queue.append(d) }
    }

    func startInput() {
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.loop() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
        }
    }
    func stopInput() {
        pause()
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Returns nil for keys the game handled, so the system never plays the error beep.
    func key(_ e: NSEvent) -> NSEvent? {
        let st = Store.shared
        guard st.expanded, st.tab == gameTab else { return e }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
        switch e.keyCode {
        case 126, 13: if !e.isARepeat { turn(.up) }
        case 125, 1: if !e.isARepeat { turn(.down) }
        case 123, 0: if !e.isARepeat { turn(.left) }
        case 124, 2: if !e.isARepeat { turn(.right) }
        case 49, 36: if !e.isARepeat { toggle() }
        case 35: if !e.isARepeat { if phase == .playing { pause() } else if phase == .paused { resume() } }
        case 15: if !e.isARepeat { restart() }
        default: return e
        }
        return nil
    }

    // MARK: simulation
    func loop() {
        let t = now()
        particles.removeAll { t - $0.born > $0.life }
        pops.removeAll { t - $0.born > 1.1 }
        guard phase == .playing else { return }
        if bonus != nil, t - bonusBorn > bonusLife { bonus = nil }
        var guardCount = 0
        while phase == .playing && t - lastStep >= interval && guardCount < 3 {
            lastStep += interval
            step(lastStep)
            guardCount += 1
        }
        if phase == .playing && t - lastStep > interval * 3 { lastStep = t }
    }

    func freeCell() -> GridPt? {
        let occ = Set(cells)
        var free: [GridPt] = []
        for y in 0..<SnakeGame.rows {
            for x in 0..<SnakeGame.cols {
                let c = GridPt(x: x, y: y)
                if occ.contains(c) || c == food { continue }
                if let b = bonus, b == c { continue }
                free.append(c)
            }
        }
        return free.randomElement()
    }
    func placeFood() {
        if let c = freeCell() { food = c } else { food = GridPt(x: -1, y: -1); finish(won: true) }
    }
    func spawnBonus(_ t: Double) {
        if let c = freeCell() { bonus = c; bonusBorn = t }
    }

    func step(_ t: Double) {
        if !queue.isEmpty {
            let n = queue.removeFirst()
            if n != heading.opposite { heading = n }
        }
        var h = GridPt(x: cells[0].x + heading.dx, y: cells[0].y + heading.dy)
        if wrap {
            h.x = (h.x + SnakeGame.cols) % SnakeGame.cols
            h.y = (h.y + SnakeGame.rows) % SnakeGame.rows
        } else if h.x < 0 || h.y < 0 || h.x >= SnakeGame.cols || h.y >= SnakeGame.rows {
            die(); return
        }
        let ateFood = (h == food)
        var ateBonus = false
        if let b = bonus, b == h { ateBonus = true }
        var grows = ateFood || ateBonus
        if !grows && pendingGrow > 0 { grows = true; pendingGrow -= 1 }
        let body = grows ? cells : Array(cells.dropLast())
        if body.contains(h) { die(); return }

        prev = cells
        cells.insert(h, at: 0)
        if !grows { cells.removeLast() }
        length = cells.count

        if ateFood {
            eaten += 1
            let pts = 10 + (level - 1) * 2
            score += pts
            burst(h, Color(red: 1.0, green: 0.3, blue: 0.4), 12)
            pop("+\(pts)", h, .white)
            let newLevel = eaten / 5 + 1
            if newLevel != level { level = newLevel; bigPop("LEVEL \(level)") }
            interval = max(0.065, 0.16 * pow(0.965, Double(eaten)))
            if eaten % 5 == 0 && bonus == nil { spawnBonus(t) }
            placeFood()
        }
        if ateBonus {
            let left = max(0, 1 - (t - bonusBorn) / bonusLife)
            let pts = 30 + Int(left * 40)
            score += pts
            pendingGrow += 2
            burst(h, Color(red: 1.0, green: 0.82, blue: 0.2), 18)
            pop("+\(pts)", h, Color(red: 1.0, green: 0.85, blue: 0.3))
            bonus = nil
        }
        if score > best {
            best = score
            newBest = startBest > 0
            UserDefaults.standard.set(best, forKey: bestKey)
        }
    }

    func die() {
        prev = cells
        deathTime = now()
        burst(cells[0], Color(red: 1.0, green: 0.25, blue: 0.25), 20)
        phase = .over
        UserDefaults.standard.set(best, forKey: bestKey)
    }
    func finish(won w: Bool) {
        won = w
        deathTime = now()
        phase = .over
        UserDefaults.standard.set(best, forKey: bestKey)
    }

    // MARK: effects
    func burst(_ c: GridPt, _ color: Color, _ n: Int) {
        let t = now()
        for _ in 0..<n {
            let a = Double.random(in: 0..<(2 * Double.pi)), sp = Double.random(in: 2...6)
            particles.append(Particle(x: Double(c.x) + 0.5, y: Double(c.y) + 0.5, vx: cos(a) * sp, vy: sin(a) * sp,
                                      born: t, life: Double.random(in: 0.35...0.7), size: Double.random(in: 0.08...0.18), color: color))
        }
    }
    func pop(_ text: String, _ c: GridPt, _ color: Color) {
        pops.append(Pop(x: Double(c.x) + 0.5, y: Double(c.y) + 0.2, text: text, born: now(), color: color, big: false))
    }
    func bigPop(_ text: String) {
        pops.append(Pop(x: Double(SnakeGame.cols) / 2, y: Double(SnakeGame.rows) / 2, text: text, born: now(), color: .white, big: true))
    }
}

struct SnakeView: View {
    @ObservedObject var g = SnakeGame.shared
    @AppStorage("accent") var accent = "green"
    let cell: CGFloat = 18

    var body: some View {
        HStack(spacing: 14) {
            board
            hud
        }
        .onAppear { g.startInput() }
        .onDisappear { g.stopInput() }
    }

    // MARK: board
    var board: some View {
        let w = CGFloat(SnakeGame.cols) * cell, h = CGFloat(SnakeGame.rows) * cell
        return ZStack {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let _ = tl.date
                    draw(ctx, size, g.now())
                }
            }
            phaseOverlay.allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(presetColor(accent).opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            (NSApp.delegate as? AppDelegate)?.panel.makeKey()
            g.toggle()
        }
    }

    @ViewBuilder var phaseOverlay: some View {
        switch g.phase {
        case .ready:
            card {
                Text("SNAKE").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundColor(presetColor(accent))
                Text("Arrow keys or WASD to start").font(.caption).foregroundColor(.white.opacity(0.8))
                Text(g.wrap ? "Wrap mode: walls are portals" : "Classic mode: walls are deadly").font(.caption2).foregroundColor(.gray)
            }
        case .paused:
            card {
                Text("PAUSED").font(.system(size: 24, weight: .heavy, design: .rounded))
                Text("Space to resume").font(.caption).foregroundColor(.gray)
            }
        case .over:
            card {
                Text(g.won ? "YOU WIN!" : "GAME OVER").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundColor(g.won ? .yellow : .red)
                Text("Score \(g.score)").font(.system(size: 16, weight: .semibold, design: .rounded))
                if g.newBest { Text("New best!").font(.caption.bold()).foregroundColor(.yellow) }
                Text("Space or R to play again").font(.caption).foregroundColor(.gray)
            }
        case .playing:
            EmptyView()
        }
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 5) { content() }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: HUD
    var hud: some View {
        VStack(alignment: .leading, spacing: 9) {
            stat("SCORE", "\(g.score)", big: true)
            HStack(spacing: 6) {
                stat("BEST", "\(g.best)")
                if g.newBest { Text("NEW").font(.system(size: 9, weight: .heavy)).foregroundColor(.black).padding(.horizontal, 4).padding(.vertical, 1).background(Color.yellow).clipShape(Capsule()) }
            }
            HStack(spacing: 16) {
                stat("LENGTH", "\(g.length)")
                stat("LEVEL", "\(g.level)")
            }
            Picker("", selection: $g.wrap) {
                Text("Walls").tag(false)
                Text("Wrap").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 124)
            HStack(spacing: 10) {
                btn(g.phase == .playing ? "pause.fill" : "play.fill") { g.toggle() }
                btn("arrow.counterclockwise") { g.restart() }
            }
            Text("Arrows / WASD to steer\nSpace pause  ·  R restart\nGold star = bonus").font(.system(size: 9)).foregroundColor(.gray)
            Spacer(minLength: 0)
        }.frame(width: 124, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
    }

    func stat(_ t: String, _ v: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.system(size: 9, weight: .semibold)).foregroundColor(.gray).tracking(1)
            Text(v).font(.system(size: big ? 34 : 18, weight: big ? .semibold : .regular, design: .rounded)).monospacedDigit()
        }
    }

    // MARK: drawing
    func draw(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        var ctx = context
        let cols = SnakeGame.cols, rows = SnakeGame.rows
        let cs = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
        let ox = (size.width - cs * CGFloat(cols)) / 2, oy = (size.height - cs * CGFloat(rows)) / 2
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x) * cs, y: oy + CGFloat(y) * cs) }
        func disc(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        let acc = presetColor(accent)

        // checkerboard
        for y in 0..<rows {
            for x in 0..<cols where (x + y) % 2 == 0 {
                ctx.fill(Path(CGRect(x: ox + CGFloat(x) * cs, y: oy + CGFloat(y) * cs, width: cs, height: cs)), with: .color(Color.white.opacity(0.03)))
            }
        }
        // border hint: dashed = portals, red = deadly walls
        let frame = CGRect(x: ox, y: oy, width: cs * CGFloat(cols), height: cs * CGFloat(rows)).insetBy(dx: 1, dy: 1)
        if g.wrap { ctx.stroke(Path(frame), with: .color(acc.opacity(0.55)), style: StrokeStyle(lineWidth: 2, dash: [4, 4])) }
        else { ctx.stroke(Path(frame), with: .color(Color.red.opacity(0.35)), lineWidth: 2) }

        // apple
        if g.food.x >= 0 {
            let apple = Color(red: 1.0, green: 0.28, blue: 0.38)
            let c = pt(Double(g.food.x) + 0.5, Double(g.food.y) + 0.5)
            let r = cs * 0.36 * CGFloat(1 + 0.08 * sin(t * 6))
            ctx.fill(disc(c, cs * 1.1), with: .radialGradient(Gradient(colors: [apple.opacity(0.4), apple.opacity(0)]), center: c, startRadius: 0, endRadius: cs * 1.1))
            ctx.fill(disc(c, r), with: .color(apple))
            ctx.fill(disc(CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35), r * 0.25), with: .color(Color.white.opacity(0.55)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x + r * 0.05, y: c.y - r * 1.3, width: r * 0.75, height: r * 0.4)), with: .color(Color.green))
        }

        // golden bonus with countdown ring
        if let b = g.bonus {
            let gold = Color(red: 1.0, green: 0.82, blue: 0.2)
            let left = max(0, 1 - (t - g.bonusBorn) / g.bonusLife)
            let blink: Double = (left < 0.25 && sin(t * 22) < 0) ? 0.35 : 1
            let c = pt(Double(b.x) + 0.5, Double(b.y) + 0.5)
            var lc = ctx
            lc.opacity = blink
            lc.fill(disc(c, cs * 1.2), with: .radialGradient(Gradient(colors: [gold.opacity(0.5), gold.opacity(0)]), center: c, startRadius: 0, endRadius: cs * 1.2))
            lc.fill(disc(c, cs * 0.4 * CGFloat(1 + 0.1 * sin(t * 10))), with: .color(gold))
            lc.draw(Text("★").font(.system(size: cs * 0.6, weight: .bold)).foregroundColor(Color(red: 0.55, green: 0.35, blue: 0)), at: c)
            var arc = Path()
            arc.addArc(center: c, radius: cs * 0.66, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * left), clockwise: false)
            lc.stroke(arc, with: .color(gold.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // snake (smoothly interpolated between the previous and current grid step)
        let cells = g.cells, prev = g.prev
        let n = cells.count
        let p = g.progress(t)
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let to = cells[i]
            var from = i < prev.count ? prev[i] : (prev.last ?? to)
            if abs(to.x - from.x) > 1 || abs(to.y - from.y) > 1 { from = to }   // wrapped: snap, don't fly across
            let px = Double(from.x) + Double(to.x - from.x) * p + 0.5
            let py = Double(from.y) + Double(to.y - from.y) * p + 0.5
            pts.append(pt(px, py))
        }

        let dead = g.phase == .over
        var tint: Color? = nil
        if dead {
            let dt = t - g.deathTime
            if dt < 1.0 { tint = Int(dt * 6) % 2 == 0 ? Color.red : nil; ctx.opacity = 1 } else { ctx.opacity = 0.55 }
        }
        func bodyColor(_ i: Int) -> Color {
            if let tc = tint { return tc }
            let k = n > 1 ? Double(i) / Double(n - 1) : 0
            return shade(acc, CGFloat(1.0 - 0.6 * k))
        }
        let bw = cs * 0.74
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) {
                let a = pts[i], b = pts[i - 1]
                let w = bw * CGFloat(0.65 + 0.35 * min(1.0, Double(n - i) / 4.0))
                if hypot(a.x - b.x, a.y - b.y) < cs * 1.6 {
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    ctx.stroke(path, with: .color(bodyColor(i)), style: StrokeStyle(lineWidth: w, lineCap: .round))
                    ctx.stroke(path, with: .color(Color.white.opacity(0.10)), style: StrokeStyle(lineWidth: w * 0.35, lineCap: .round))
                } else {
                    ctx.fill(disc(a, w / 2), with: .color(bodyColor(i)))
                }
            }
        }

        // head
        if let head = pts.first {
            let hr = cs * 0.5
            ctx.fill(disc(head, cs * 1.3), with: .radialGradient(Gradient(colors: [acc.opacity(dead ? 0 : 0.35), acc.opacity(0)]), center: head, startRadius: 0, endRadius: cs * 1.3))
            let fx = CGFloat(g.heading.dx), fy = CGFloat(g.heading.dy)
            let sx = -fy, sy = fx
            // tongue flicks now and then
            if g.phase == .playing && (t * 1.6).truncatingRemainder(dividingBy: 1) < 0.22 {
                var tg = Path()
                let base = CGPoint(x: head.x + fx * hr * 0.9, y: head.y + fy * hr * 0.9)
                let tip = CGPoint(x: head.x + fx * (hr + cs * 0.38), y: head.y + fy * (hr + cs * 0.38))
                tg.move(to: base); tg.addLine(to: tip)
                tg.move(to: tip); tg.addLine(to: CGPoint(x: tip.x + fx * cs * 0.12 + sx * cs * 0.1, y: tip.y + fy * cs * 0.12 + sy * cs * 0.1))
                tg.move(to: tip); tg.addLine(to: CGPoint(x: tip.x + fx * cs * 0.12 - sx * cs * 0.1, y: tip.y + fy * cs * 0.12 - sy * cs * 0.1))
                ctx.stroke(tg, with: .color(Color(red: 1, green: 0.3, blue: 0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            ctx.fill(disc(head, hr), with: .color(tint ?? shade(acc, 1.12)))
            for sgn: CGFloat in [-1, 1] {
                let e = CGPoint(x: head.x + (fx * 0.14 + sx * sgn * 0.24) * cs, y: head.y + (fy * 0.14 + sy * sgn * 0.24) * cs)
                ctx.fill(disc(e, cs * 0.15), with: .color(.white))
                ctx.fill(disc(CGPoint(x: e.x + fx * cs * 0.04, y: e.y + fy * cs * 0.04), cs * 0.075), with: .color(.black))
            }
        }

        // particles + floating score text
        ctx.opacity = 1
        for q in g.particles {
            let age = t - q.born, k = age / q.life
            if k >= 1 || k < 0 { continue }
            let d = (1 - exp(-4 * age)) / 4
            let c = pt(q.x + q.vx * d, q.y + q.vy * d)
            ctx.fill(disc(c, cs * CGFloat(q.size * (1 - k * 0.6))), with: .color(q.color.opacity(1 - k)))
        }
        for pp in g.pops {
            let age = t - pp.born, k = age / 1.1
            if k >= 1 || k < 0 { continue }
            var pc = ctx
            pc.opacity = pp.big ? 1 - k * k : 1 - k
            let c = pt(pp.x, pp.y - age * (pp.big ? 0.6 : 1.4))
            pc.draw(Text(pp.text).font(.system(size: pp.big ? cs * 1.1 : cs * 0.7, weight: .heavy, design: .rounded)).foregroundColor(pp.color), at: c)
        }
    }
}
