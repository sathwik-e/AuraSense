import SwiftUI

// MARK: - Styles

/// The unlock animations the user can pick on the Sound page.
public enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case eclipse
    case aperture
    case stardust

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .eclipse: return "Eclipse"
        case .aperture: return "Aperture"
        case .stardust: return "Stardust"
        }
    }

    public var summary: String {
        switch self {
        case .eclipse: return "The AuraSense ring blooms and ripples outward."
        case .aperture: return "A camera iris spins open to reveal your desktop."
        case .stardust: return "Light spirals into a ring, then bursts into sparks."
        }
    }

    /// How long the overlay stays on screen.
    public var duration: TimeInterval {
        switch self {
        case .eclipse: return 2.1
        case .aperture: return 2.0
        case .stardust: return 2.4
        }
    }
}

// MARK: - Shared helpers

enum UnlockMotion {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }

    /// Linear progress of `t` through [start, end], clamped to 0...1.
    static func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
        clamp((t - start) / (end - start))
    }

    static func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }

    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeInCubic(_ x: Double) -> Double { x * x * x }
    static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func easeOutExpo(_ x: Double) -> Double { x >= 1 ? 1 : 1 - pow(2, -10 * x) }
    static func easeOutBack(_ x: Double, overshoot s: Double = 1.70158) -> Double {
        let u = x - 1
        return 1 + (s + 1) * u * u * u + s * u * u
    }
    static func smoothstep(_ x: Double) -> Double {
        let c = clamp(x)
        return c * c * (3 - 2 * c)
    }
}

enum UnlockPalette {
    static let midnight = Color(red: 0.02, green: 0.04, blue: 0.09)
    static let bladeLit = Color(red: 0.15, green: 0.19, blue: 0.29)
    static let bladeDark = Color(red: 0.025, green: 0.04, blue: 0.085)
    static let blue = Color(red: 0.24, green: 0.50, blue: 1.00)
    static let cyan = Color(red: 0.36, green: 0.86, blue: 1.00)
    static let teal = Color(red: 0.42, green: 1.00, blue: 0.92)
    static let violet = Color(red: 0.62, green: 0.55, blue: 1.00)
    static let ice = Color(red: 0.80, green: 0.88, blue: 1.00)

    static let auraGradient = Gradient(colors: [
        Color(red: 0.12, green: 0.36, blue: 0.98),
        Color(red: 0.22, green: 0.78, blue: 1.00),
        Color(red: 0.26, green: 0.95, blue: 0.92)
    ])
}

/// A padlock drawn with paths so its shackle can lift and swing open smoothly.
enum UnlockGlyph {
    /// - Parameters:
    ///   - size: width of the lock body.
    ///   - open: 0 = closed, 1 = shackle lifted and swung open (values past 1 overshoot).
    ///   - glow: strength of the cyan halo, 0...1.
    static func drawLock(
        in context: GraphicsContext,
        at center: CGPoint,
        size s: CGFloat,
        open: Double,
        alpha: Double,
        glow: Double
    ) {
        guard alpha > 0.001 else { return }
        var g = context
        g.translateBy(x: center.x, y: center.y)
        g.opacity = alpha

        let bodyH = s * 0.80
        let body = CGRect(x: -s / 2, y: -bodyH / 2 + s * 0.24, width: s, height: bodyH)
        let legX = s * 0.29
        let archY = body.minY - s * 0.12
        let legBottom = body.minY + s * 0.14
        let stroke = s * 0.14

        var shackle = Path()
        shackle.move(to: CGPoint(x: -legX, y: legBottom))
        shackle.addLine(to: CGPoint(x: -legX, y: archY))
        // Sample the arch so it always bows upward regardless of arc-direction conventions.
        for i in 1...28 {
            let a = Double.pi + Double.pi * Double(i) / 28
            shackle.addLine(to: CGPoint(x: legX * cos(a), y: archY + legX * sin(a)))
        }
        shackle.addLine(to: CGPoint(x: legX, y: legBottom))

        if glow > 0.001 {
            g.addFilter(.shadow(color: UnlockPalette.cyan.opacity(0.85 * glow), radius: s * 0.45))
        }
        g.drawLayer { layer in
            // Shackle: lift straight up, then swing around the left leg.
            var sh = layer
            let lift = CGFloat(min(open, 1.15)) * s * 0.20
            sh.translateBy(x: -legX, y: legBottom - lift)
            sh.rotate(by: .degrees(-16 * open))
            sh.translateBy(x: legX, y: -legBottom)
            sh.stroke(
                shackle,
                with: .linearGradient(
                    Gradient(colors: [.white, UnlockPalette.ice]),
                    startPoint: CGPoint(x: 0, y: archY - legX),
                    endPoint: CGPoint(x: 0, y: legBottom)
                ),
                style: StrokeStyle(lineWidth: stroke, lineCap: .butt, lineJoin: .round)
            )

            // Body.
            let bodyPath = Path(roundedRect: body, cornerRadius: s * 0.20, style: .continuous)
            layer.fill(
                bodyPath,
                with: .linearGradient(
                    Gradient(colors: [.white, Color(red: 0.84, green: 0.90, blue: 1.0)]),
                    startPoint: CGPoint(x: 0, y: body.minY),
                    endPoint: CGPoint(x: 0, y: body.maxY)
                )
            )
            // Soft top sheen.
            let sheen = Path(roundedRect: body.insetBy(dx: s * 0.06, dy: s * 0.05)
                .divided(atDistance: bodyH * 0.32, from: .minYEdge).slice,
                cornerRadius: s * 0.14, style: .continuous)
            layer.fill(sheen, with: .color(.white.opacity(0.55)))

            // Keyhole.
            let holeCenter = CGPoint(x: 0, y: body.midY - s * 0.05)
            let r = s * 0.085
            var hole = Path(ellipseIn: CGRect(x: holeCenter.x - r, y: holeCenter.y - r, width: r * 2, height: r * 2))
            hole.addRoundedRect(
                in: CGRect(x: -s * 0.035, y: holeCenter.y, width: s * 0.07, height: s * 0.19),
                cornerSize: CGSize(width: s * 0.03, height: s * 0.03)
            )
            layer.fill(hole, with: .color(UnlockPalette.midnight.opacity(0.88)))
        }
    }
}

/// "Welcome back / Unlocked by …" caption shared by the scenes.
struct UnlockCaption: View {
    let deviceName: String?
    let base: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text("Welcome back")
                .font(.system(size: max(22, base * 0.032), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let name = deviceName, !name.isEmpty {
                Text("Unlocked by \(name)")
                    .font(.system(size: max(13, base * 0.016), weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 10)
    }
}

/// Drives a time-based scene from the display's refresh, starting at `start`.
struct TimedUnlockScene: View {
    let style: UnlockAnimationStyle
    let start: Date
    let deviceName: String?
    let showsCaption: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            UnlockSceneFrame(
                style: style,
                t: timeline.date.timeIntervalSince(start),
                deviceName: deviceName,
                showsCaption: showsCaption
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One frame of a scene at time `t` (seconds since the animation began).
struct UnlockSceneFrame: View {
    let style: UnlockAnimationStyle
    let t: Double
    let deviceName: String?
    let showsCaption: Bool

    var body: some View {
        switch style {
        case .aperture:
            ApertureScene(t: t, deviceName: deviceName, showsCaption: showsCaption)
        case .stardust:
            StardustScene(t: t, deviceName: deviceName, showsCaption: showsCaption)
        case .eclipse:
            EclipseThumbnail(t: t)
        }
    }
}

// MARK: - Aperture

/// A nine-blade camera iris closes over the screen, the lock clicks open, and the iris spins
/// wide to reveal the desktop, its rim lit by the AuraSense gradient.
struct ApertureScene: View {
    let t: Double
    let deviceName: String?
    let showsCaption: Bool

    var body: some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { context, size in
                    ApertureRenderer.draw(context, size: size, t: t)
                }
                if showsCaption {
                    UnlockCaption(deviceName: deviceName, base: base)
                        .offset(y: base * 0.16)
                        .opacity(ApertureRenderer.captionAlpha(t))
                        .offset(y: (1 - UnlockMotion.easeOutCubic(UnlockMotion.progress(t, 0.55, 0.85))) * base * 0.015)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

enum ApertureRenderer {
    static let blades = 9

    static func captionAlpha(_ t: Double) -> Double {
        UnlockMotion.progress(t, 0.55, 0.8) * (1 - UnlockMotion.progress(t, 1.05, 1.35))
    }

    static func draw(_ context: GraphicsContext, size: CGSize, t: Double) {
        typealias M = UnlockMotion
        let w = Double(size.width), h = Double(size.height)
        let base = min(w, h)
        let diag = hypot(w, h)
        let c = CGPoint(x: w / 2, y: h / 2)

        let fadeIn = M.easeOutCubic(M.progress(t, 0, 0.16))
        let fadeOut = 1 - M.easeInCubic(M.progress(t, 1.62, 1.95))
        guard fadeIn * fadeOut > 0.001 else { return }

        let openP = M.easeInOutCubic(M.progress(t, 0.70, 1.62))
        // Vertex radius at which the inscribed circle clears the screen corners.
        let fullRadius = diag * 0.5 / cos(Double.pi / Double(blades)) * 1.04
        let radius = fullRadius * openP
        let theta = -Double.pi / 2
            + 0.14 * M.easeOutCubic(M.progress(t, 0, 0.7))
            + 1.25 * openP
        let farLength = diag * 3

        var ctx = context
        ctx.opacity = fadeIn * fadeOut

        // Polygon vertices and side directions (tangent of each chord, defined even at radius 0).
        var vertices: [CGPoint] = []
        var directions: [CGVector] = []
        for k in 0..<blades {
            let a = theta + 2 * Double.pi * Double(k) / Double(blades)
            vertices.append(CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)))
            let d = a + Double.pi / Double(blades) + Double.pi / 2
            directions.append(CGVector(dx: cos(d), dy: sin(d)))
        }

        func point(_ p: CGPoint, _ d: CGVector, _ len: Double) -> CGPoint {
            CGPoint(x: p.x + d.dx * len, y: p.y + d.dy * len)
        }

        // Blades.
        let shadeDepth = base * 0.38
        for k in 0..<blades {
            let v1 = vertices[(k + 1) % blades]
            let v2 = vertices[(k + 2) % blades]
            let d1 = directions[k]
            let d2 = directions[(k + 1) % blades]

            var blade = Path()
            blade.move(to: v1)
            blade.addLine(to: point(v1, d1, farLength))
            blade.addLine(to: point(v2, d2, farLength))
            blade.addLine(to: v2)
            blade.closeSubpath()

            // Light the leading edge, falling off across the blade. The next side turns by
            // +2π/N, so the blade's interior is always +90° from its leading edge.
            let n = CGVector(dx: -d1.dy, dy: d1.dx)

            let lit = v1
            let dark = point(v1, n, shadeDepth)
            ctx.fill(
                blade,
                with: .linearGradient(
                    Gradient(colors: [UnlockPalette.bladeLit.opacity(0.95), UnlockPalette.bladeDark.opacity(0.95)]),
                    startPoint: lit,
                    endPoint: dark
                )
            )

            // Contact shadow on the blade underneath, then a fine specular edge.
            var edge = Path()
            edge.move(to: v1)
            edge.addLine(to: point(v1, d1, farLength))
            var shadowCtx = ctx
            shadowCtx.translateBy(x: -n.dx * 2.0, y: -n.dy * 2.0)
            shadowCtx.stroke(edge, with: .color(.black.opacity(0.45)), lineWidth: 3)

            var spec = Path()
            spec.move(to: v1)
            spec.addLine(to: point(v1, d1, base * 0.75))
            ctx.stroke(
                spec,
                with: .linearGradient(
                    Gradient(colors: [UnlockPalette.cyan.opacity(0.75), UnlockPalette.cyan.opacity(0)]),
                    startPoint: v1,
                    endPoint: point(v1, d1, base * 0.75)
                ),
                lineWidth: 1.2
            )
        }

        // Aperture rim.
        if radius > 0.5 {
            let rimAlpha = 1 - M.progress(openP, 0.55, 0.95)
            var rim = Path()
            rim.addLines(vertices)
            rim.closeSubpath()
            var glowCtx = ctx
            glowCtx.blendMode = .plusLighter
            glowCtx.stroke(rim, with: .color(UnlockPalette.cyan.opacity(0.22 * rimAlpha)), lineWidth: base * 0.018)
            ctx.stroke(
                rim,
                with: .linearGradient(
                    UnlockPalette.auraGradient,
                    startPoint: CGPoint(x: c.x - radius, y: c.y + radius),
                    endPoint: CGPoint(x: c.x + radius, y: c.y - radius)
                ),
                style: StrokeStyle(lineWidth: max(2, base * 0.003), lineJoin: .round)
            )
        }

        // Emblem: a dark disc with the lock, sitting on the closed iris.
        let pop = M.easeOutBack(M.progress(t, 0.08, 0.48), overshoot: 2.0)
        let appear = M.progress(t, 0.08, 0.26)
        let leave = M.easeInCubic(M.progress(openP, 0, 0.42))
        let emblemAlpha = appear * (1 - leave)
        guard emblemAlpha > 0.001 else { return }
        let emblemScale = (0.62 + 0.38 * pop) * (1 + 0.35 * leave)
        let discR = base * 0.085 * emblemScale

        var em = ctx
        em.opacity = ctx.opacity * emblemAlpha
        let disc = Path(ellipseIn: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
        em.fill(
            disc,
            with: .radialGradient(
                Gradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.18), UnlockPalette.midnight]),
                center: CGPoint(x: c.x, y: c.y - discR * 0.4),
                startRadius: 0,
                endRadius: discR * 1.3
            )
        )
        var emGlow = em
        emGlow.blendMode = .plusLighter
        emGlow.stroke(disc, with: .color(UnlockPalette.cyan.opacity(0.25)), lineWidth: base * 0.012)
        em.stroke(
            disc,
            with: .linearGradient(
                UnlockPalette.auraGradient,
                startPoint: CGPoint(x: c.x - discR, y: c.y + discR),
                endPoint: CGPoint(x: c.x + discR, y: c.y - discR)
            ),
            lineWidth: max(2.5, base * 0.0035)
        )

        // Click flash when the shackle releases.
        let flash = M.easeOutCubic(M.progress(t, 0.50, 0.98))
        if flash > 0, flash < 1 {
            let fr = discR * (1 + 0.85 * flash)
            emGlow.stroke(
                Path(ellipseIn: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2)),
                with: .color(UnlockPalette.teal.opacity(0.7 * (1 - flash))),
                lineWidth: max(1.5, base * 0.0025)
            )
        }

        let open = M.easeOutBack(M.progress(t, 0.46, 0.68), overshoot: 2.2)
        UnlockGlyph.drawLock(
            in: em,
            at: CGPoint(x: c.x, y: c.y - discR * 0.06),
            size: CGFloat(base * 0.058 * emblemScale),
            open: open,
            alpha: 1,
            glow: 0.35 + 0.5 * M.progress(t, 0.46, 0.6) * (1 - flash)
        )
    }
}

// MARK: - Stardust

/// Hundreds of motes spiral in from the screen edges and settle into an orbiting ring; the lock
/// opens, and the ring bursts into twinkling sparks behind a shockwave.
struct StardustScene: View {
    let t: Double
    let deviceName: String?
    let showsCaption: Bool

    var body: some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { context, size in
                    StardustRenderer.draw(context, size: size, t: t)
                }
                if showsCaption {
                    UnlockCaption(deviceName: deviceName, base: base)
                        .offset(y: base * 0.17)
                        .opacity(StardustRenderer.captionAlpha(t))
                        .offset(y: (1 - UnlockMotion.easeOutCubic(UnlockMotion.progress(t, 1.18, 1.5))) * base * 0.015)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

enum StardustRenderer {
    struct Mote {
        var phi: Double        // spawn angle
        var spawn: Double      // spawn distance, fraction of half the diagonal
        var spin: Double       // extra radians travelled while spiralling in
        var delay: Double
        var travel: Double
        var jitter: Double     // ring offset, fraction of base
        var burst: Double      // burst distance, fraction of base
        var burstSpin: Double
        var burstTime: Double
        var size: Double
        var color: Int
        var twinkle: Double
        var twinkleSpeed: Double
        var isSparkle: Bool
    }

    static let burstAt = 1.12
    static let orbitSpeed = 0.85

    static let motes: [Mote] = {
        var rng = SplitMix64(seed: 0xA0_5E_45_E0)
        return (0..<440).map { i in
            let roll = rng.unit()
            let color = roll < 0.16 ? 3 : (roll < 0.45 ? 1 : (roll < 0.70 ? 0 : (roll < 0.90 ? 2 : 4)))
            let burstRoll = rng.unit()
            return Mote(
                phi: rng.range(0, 2 * .pi),
                spawn: rng.range(0.55, 1.08),
                spin: rng.range(0.7, 1.7),
                delay: rng.range(0, 0.30),
                travel: rng.range(0.55, 0.78),
                jitter: rng.range(-0.012, 0.012),
                burst: 0.16 + 0.72 * pow(burstRoll, 1.4),
                burstSpin: rng.range(-0.35, 0.35),
                burstTime: rng.range(0.75, 1.15),
                size: rng.range(0.9, 2.6),
                color: color,
                twinkle: rng.range(0, 2 * .pi),
                twinkleSpeed: rng.range(14, 28),
                isSparkle: i % 29 == 0
            )
        }
    }()

    static func color(_ index: Int) -> Color {
        switch index {
        case 0: return UnlockPalette.blue
        case 1: return UnlockPalette.cyan
        case 2: return UnlockPalette.teal
        case 3: return .white
        default: return UnlockPalette.violet
        }
    }

    static func captionAlpha(_ t: Double) -> Double {
        UnlockMotion.progress(t, 1.18, 1.42) * (1 - UnlockMotion.progress(t, 1.95, 2.3))
    }

    /// Polar position and opacity of a mote at time `t`.
    static func state(_ m: Mote, t: Double, ring: Double, base: Double, halfDiag: Double) -> (r: Double, a: Double, alpha: Double, bursting: Bool) {
        typealias M = UnlockMotion
        let ringR = ring + m.jitter * base
        if t < burstAt {
            let u = M.clamp((t - m.delay) / m.travel)
            let r = M.lerp(m.spawn * halfDiag, ringR, M.easeInOutCubic(u))
            let a = m.phi + m.spin * M.easeOutCubic(u) + orbitSpeed * max(0, t - m.delay)
            let alpha = t < m.delay ? 0 : M.smoothstep(u / 0.3)
            return (r, a, alpha, false)
        }
        let a0 = m.phi + m.spin + orbitSpeed * (burstAt - m.delay)
        let q = M.clamp((t - burstAt) / m.burstTime)
        let r = ringR + m.burst * base * M.easeOutExpo(q)
        let a = a0 + m.burstSpin * M.easeOutCubic(q)
        let twinkle = 0.55 + 0.45 * sin(m.twinkleSpeed * t + m.twinkle)
        let alpha = pow(1 - q, 1.6) * M.lerp(1, twinkle, M.progress(q, 0.05, 0.3))
        return (r, a, alpha, true)
    }

    static func draw(_ context: GraphicsContext, size: CGSize, t: Double) {
        typealias M = UnlockMotion
        let w = Double(size.width), h = Double(size.height)
        let base = min(w, h)
        let halfDiag = hypot(w, h) / 2
        let c = CGPoint(x: w / 2, y: h / 2)
        let ring = base * 0.105
        let scale = max(0.55, base / 900)

        // Backdrop: a soft vignette that focuses the eye on the center.
        let veil = M.smoothstep(M.progress(t, 0, 0.35)) * (1 - M.smoothstep(M.progress(t, 1.45, 2.2)))
        if veil > 0.001 {
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [UnlockPalette.midnight.opacity(0.62 * veil), UnlockPalette.midnight.opacity(0)]),
                    center: c,
                    startRadius: 0,
                    endRadius: base * 0.75
                )
            )
        }

        var glow = context
        glow.blendMode = .plusLighter

        // Ring of light while the motes orbit.
        let gather = M.smoothstep(M.progress(t, 0.62, 1.0)) * (1 - M.progress(t, burstAt, burstAt + 0.18))
        if gather > 0.001 {
            let ringPath = Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
            glow.stroke(ringPath, with: .color(UnlockPalette.cyan.opacity(0.16 * gather)), lineWidth: base * 0.035)
            glow.stroke(ringPath, with: .color(UnlockPalette.cyan.opacity(0.55 * gather)), lineWidth: max(1.5, base * 0.003))
        }

        // Core flash and shockwave at the burst.
        let flash = M.easeOutCubic(M.progress(t, burstAt - 0.04, burstAt + 0.5))
        if flash > 0, flash < 1 {
            let fr = base * 0.2 * (0.55 + 0.9 * flash)
            glow.fill(
                Path(ellipseIn: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.75 * (1 - flash)), location: 0),
                        .init(color: UnlockPalette.cyan.opacity(0.35 * (1 - flash)), location: 0.35),
                        .init(color: UnlockPalette.blue.opacity(0), location: 1)
                    ]),
                    center: c,
                    startRadius: 0,
                    endRadius: fr
                )
            )
        }
        for (lag, tint, strength) in [(0.0, UnlockPalette.cyan, 0.75), (0.07, UnlockPalette.teal, 0.4)] {
            let s = M.progress(t, burstAt + lag, burstAt + lag + 0.85)
            guard s > 0, s < 1 else { continue }
            let e = M.easeOutCubic(s)
            let r = ring + base * 0.62 * e
            glow.stroke(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(tint.opacity(strength * pow(1 - s, 1.3))),
                lineWidth: M.lerp(base * 0.007, base * 0.001, e)
            )
        }

        // Motes: a short streak behind each one, then a bright head.
        for m in motes {
            let now = state(m, t: t, ring: ring, base: base, halfDiag: halfDiag)
            guard now.alpha > 0.01 else { continue }
            let before = state(m, t: t - 0.03, ring: ring, base: base, halfDiag: halfDiag)
            let p = CGPoint(x: c.x + now.r * cos(now.a), y: c.y + now.r * sin(now.a))
            var q = CGPoint(x: c.x + before.r * cos(before.a), y: c.y + before.r * sin(before.a))
            let sizeNow = m.size * scale * (now.bursting ? M.lerp(1, 0.6, M.progress(t, burstAt, burstAt + 1)) : 1)
            let tint = color(m.color)

            // Keep streaks short so fast motes read as sparks, not lines, and fade the tail.
            let dx = p.x - q.x, dy = p.y - q.y
            let length = hypot(dx, dy)
            let maxLength = sizeNow * 11
            if length > maxLength {
                q = CGPoint(x: p.x - dx / length * maxLength, y: p.y - dy / length * maxLength)
            }
            if length > 0.5 {
                var streak = Path()
                streak.move(to: q)
                streak.addLine(to: p)
                glow.stroke(
                    streak,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0), tint.opacity(0.7 * now.alpha)]),
                        startPoint: q, endPoint: p
                    ),
                    style: StrokeStyle(lineWidth: sizeNow, lineCap: .round)
                )
            }

            let halo = sizeNow * 2.6
            glow.fill(
                Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.9 * now.alpha), tint.opacity(0)]),
                    center: p, startRadius: 0, endRadius: halo
                )
            )

            // A few four-point sparkles during the burst.
            if m.isSparkle, now.bursting {
                let arm = sizeNow * 5.5 * (0.6 + 0.4 * sin(m.twinkleSpeed * 0.6 * t + m.twinkle))
                var star = Path()
                star.move(to: CGPoint(x: p.x - arm, y: p.y))
                star.addLine(to: CGPoint(x: p.x + arm, y: p.y))
                star.move(to: CGPoint(x: p.x, y: p.y - arm))
                star.addLine(to: CGPoint(x: p.x, y: p.y + arm))
                glow.stroke(star, with: .color(Color.white.opacity(0.85 * now.alpha)),
                            style: StrokeStyle(lineWidth: max(0.8, sizeNow * 0.45), lineCap: .round))
            }
        }

        // The lock at the center of the ring.
        let appear = M.progress(t, 0.68, 0.92)
        let leave = M.smoothstep(M.progress(t, 1.5, 1.95))
        let lockAlpha = appear * (1 - leave)
        if lockAlpha > 0.001 {
            let pop = M.easeOutBack(M.progress(t, 0.68, 1.0), overshoot: 1.8)
            let lockScale = (0.78 + 0.22 * pop) * (1 + 0.08 * leave)
            let drift = -base * 0.025 * M.easeInCubic(M.progress(t, 1.4, 1.95))
            UnlockGlyph.drawLock(
                in: context,
                at: CGPoint(x: c.x, y: c.y + drift),
                size: CGFloat(base * 0.055 * lockScale),
                open: M.easeOutBack(M.progress(t, 0.98, 1.2), overshoot: 2.2),
                alpha: lockAlpha,
                glow: 0.45 + 0.55 * (1 - flash) * M.progress(t, 0.98, 1.1)
            )
        }
    }
}

/// Deterministic random numbers so every frame and every display agree on the motes.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

// MARK: - Eclipse thumbnail

/// Still of the Eclipse style for the picker (the live Eclipse uses `UnlockAnimationView`).
struct EclipseThumbnail: View {
    let t: Double

    var body: some View {
        Canvas { context, size in
            let base = Double(min(size.width, size.height))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var glow = context
            glow.blendMode = .plusLighter
            for i in 0..<3 {
                let r = base * (0.2 + 0.11 * Double(i))
                glow.opacity = 0.55 - 0.15 * Double(i)
                glow.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .linearGradient(UnlockPalette.auraGradient,
                                          startPoint: CGPoint(x: c.x - r, y: c.y + r),
                                          endPoint: CGPoint(x: c.x + r, y: c.y - r)),
                    lineWidth: 1.5
                )
            }
            let r = base * 0.15
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            context.fill(disc, with: .color(UnlockPalette.midnight))
            context.stroke(disc, with: .linearGradient(UnlockPalette.auraGradient,
                                                       startPoint: CGPoint(x: c.x - r, y: c.y + r),
                                                       endPoint: CGPoint(x: c.x + r, y: c.y - r)),
                           lineWidth: 2.5)
            UnlockGlyph.drawLock(in: context, at: c, size: CGFloat(base * 0.1), open: 1, alpha: 1, glow: 0.4)
        }
    }
}
