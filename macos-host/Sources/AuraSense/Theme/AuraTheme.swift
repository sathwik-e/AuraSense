import SwiftUI
import AppKit

/// Drop-in DynamicProperty state wrapper backed by StateObject so AuraSense compiles cleanly
/// under both Xcode and standalone macOS CommandLineTools.
@MainActor
public final class AuraStateBox<Value>: ObservableObject {
    @Published public var value: Value
    public init(_ value: Value) {
        self.value = value
    }
}

@MainActor
@propertyWrapper
public struct AuraState<Value>: DynamicProperty {
    @StateObject private var box: AuraStateBox<Value>

    public init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: AuraStateBox(wrappedValue))
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
    }
}

/// Defines AuraSense v1.0's Neon Orbit & Eclipse design language:
/// deep obsidian void, electric blue to ice-cyan orbit gradients, crescent eclipse corona,
/// and wide-tracked geometric typography (`Λ U R Λ S E N S E`).
public enum AuraTheme {
    public static let cyanGlow = Color(red: 0.22, green: 0.86, blue: 1.00)
    public static let indigoGlow = Color(red: 0.14, green: 0.44, blue: 0.98)
    public static let emeraldGlow = Color(red: 0.18, green: 0.92, blue: 0.76)
    public static let amberGlow = Color(red: 1.0, green: 0.72, blue: 0.22)
    public static let crimsonGlow = Color(red: 0.98, green: 0.34, blue: 0.46)
    public static let deepMidnight = Color(red: 0.02, green: 0.04, blue: 0.09)

    public static var auraLinearGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.36, blue: 0.98),
                Color(red: 0.22, green: 0.78, blue: 1.00),
                Color(red: 0.26, green: 0.95, blue: 0.92)
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    public static func stateAccentColor(for state: ProximityState) -> Color {
        switch state {
        case .unlockedInRange:
            return cyanGlow
        case .gracePeriodCountdown:
            return amberGlow
        case .lockedOutOfRange:
            return crimsonGlow
        case .paused:
            return .orange
        case .unconfigured:
            return cyanGlow
        }
    }

    /// Custom Eclipse + Proximity Orbit macOS Menu Bar template icon.
    /// Combines the outer BLE proximity orbit ring and orbiting signal node with an inner
    /// solar/lunar eclipse crescent that reflects the live lock/unlock state.
    public static func menuBarEclipseIcon(
        state: ProximityState,
        isCalibrating: Bool,
        isPaused: Bool
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR: CGFloat = 7.4

            // 1. Outer Proximity Orbit Ring
            let orbitPath = NSBezierPath()
            if isCalibrating {
                orbitPath.appendArc(withCenter: center, radius: outerR, startAngle: 0, endAngle: 360)
                let dash: [CGFloat] = [2.2, 1.8]
                orbitPath.setLineDash(dash, count: 2, phase: 0)
            } else if case .gracePeriodCountdown = state {
                orbitPath.appendArc(withCenter: center, radius: outerR, startAngle: 0, endAngle: 360)
                let dash: [CGFloat] = [3.5, 2.0]
                orbitPath.setLineDash(dash, count: 2, phase: 0)
            } else {
                // Leave a subtle gap around the orbiting BLE node at 45 degrees
                orbitPath.appendArc(withCenter: center, radius: outerR, startAngle: 62, endAngle: 28, clockwise: false)
            }
            orbitPath.lineWidth = 1.35
            orbitPath.lineCapStyle = .round
            NSColor.black.withAlphaComponent(isPaused ? 0.45 : 0.92).setStroke()
            orbitPath.stroke()

            let isLocked: Bool = {
                if case .lockedOutOfRange = state { return true }
                return false
            }()

            // 2. Orbiting BLE Proximity Node on the top-right of the orbit ring (45 deg)
            let nodeAngle: CGFloat = .pi * 0.25
            let nodePt = CGPoint(
                x: center.x + cos(nodeAngle) * outerR,
                y: center.y + sin(nodeAngle) * outerR
            )
            let nodeR: CGFloat = (isLocked || isPaused) ? 1.2 : 1.65
            let nodeRect = CGRect(x: nodePt.x - nodeR, y: nodePt.y - nodeR, width: nodeR * 2, height: nodeR * 2)
            NSColor.black.withAlphaComponent(isPaused ? 0.45 : 1.0).setFill()
            NSBezierPath(ovalIn: nodeRect).fill()

            // 3. Inner Eclipse Crescent (Sun disc + offset Moon cutout via Even-Odd fill)
            let sunR: CGFloat = 4.55
            let moonR: CGFloat = 4.05
            // Offset the occulting disc toward the bottom-left so the bright eclipse corona
            // shines toward the top-right (matching the AuraSense Neon Orbit Eclipse logo)
            let moonCenter = CGPoint(x: center.x - 1.15, y: center.y - 1.05)

            let crescent = NSBezierPath()
            crescent.windingRule = .evenOdd
            crescent.appendOval(in: CGRect(x: center.x - sunR, y: center.y - sunR, width: sunR * 2, height: sunR * 2))
            crescent.appendOval(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
            NSColor.black.withAlphaComponent(isPaused ? 0.50 : 1.0).setFill()
            crescent.fill()

            // 4. State indicator inside the dark eclipse shadow:
            //    - Locked: subtle lock dot/keyhole at the center
            //    - Calibrating: inner radar wave arc
            if isLocked {
                let lockDotR: CGFloat = 1.15
                let dotCenter = CGPoint(x: center.x - 0.8, y: center.y - 0.8)
                NSBezierPath(ovalIn: CGRect(
                    x: dotCenter.x - lockDotR,
                    y: dotCenter.y - lockDotR,
                    width: lockDotR * 2,
                    height: lockDotR * 2
                )).fill()
            } else if isCalibrating {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: center, radius: 2.2, startAngle: 20, endAngle: 110)
                wave.lineWidth = 1.1
                wave.lineCapStyle = .round
                NSColor.black.setStroke()
                wave.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Brand Typography Wordmark (`Λ U R Λ S E N S E`)

/// Matches the uploaded geometric typography where 'A' is rendered as a crossbar-less 'Λ',
/// 'Λ U R Λ' is pure white, and 'S E N S E' transitions from electric blue to neon cyan.
public struct AuraBrandWordmarkView: View {
    public let size: CGFloat
    public let tracking: CGFloat

    public init(size: CGFloat = 15, tracking: CGFloat = 3.2) {
        self.size = size
        self.tracking = tracking
    }

    public var body: some View {
        HStack(spacing: tracking * 0.45) {
            Text("ΛURΛ")
                .font(.system(size: size, weight: .light, design: .default))
                .tracking(tracking)
                .foregroundStyle(.white)
            Text("SENSE")
                .font(.system(size: size, weight: .light, design: .default))
                .tracking(tracking)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.28, green: 0.64, blue: 1.0),
                            Color(red: 0.24, green: 0.90, blue: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - Brand Neon Orbit Eclipse Emblem View

/// Renders the signature Neon Orbit + Crescent Eclipse icon in SwiftUI.
public struct AuraEclipseLogoView: View {
    public let size: CGFloat
    public let showWordmarkInside: Bool

    public init(size: CGFloat = 44, showWordmarkInside: Bool = false) {
        self.size = size
        self.showWordmarkInside = showWordmarkInside
    }

    public var body: some View {
        ZStack {
            // Deep black squircle / circle base
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.01, green: 0.02, blue: 0.05),
                            Color(red: 0.02, green: 0.05, blue: 0.12),
                            Color(red: 0.01, green: 0.01, blue: 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: AuraTheme.cyanGlow.opacity(0.32), radius: size * 0.16)

            // Outer Neon Orbit Circle
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.35, blue: 0.98),
                            Color(red: 0.24, green: 0.82, blue: 1.00),
                            Color(red: 0.22, green: 0.96, blue: 0.90)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    lineWidth: max(size * 0.038, 1.4)
                )
                .frame(width: size * 0.80, height: size * 0.80)
                .shadow(color: AuraTheme.cyanGlow.opacity(0.55), radius: size * 0.08)

            // Inner Crescent Eclipse Arc
            Canvas { context, canvasSize in
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height * (showWordmarkInside ? 0.44 : 0.50))
                let sunR = canvasSize.width * (showWordmarkInside ? 0.21 : 0.24)
                let moonR = sunR * 0.94
                let moonCenter = CGPoint(x: c.x - sunR * 0.14, y: c.y + sunR * 0.18)

                var path = Path()
                path.addEllipse(in: CGRect(x: c.x - sunR, y: c.y - sunR, width: sunR * 2, height: sunR * 2))
                path.addEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))

                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.14, green: 0.46, blue: 1.0),
                            Color(red: 0.55, green: 0.94, blue: 1.0),
                            Color.white
                        ]),
                        startPoint: CGPoint(x: c.x - sunR, y: c.y + sunR * 0.3),
                        endPoint: CGPoint(x: c.x + sunR * 0.7, y: c.y - sunR * 0.8)
                    ),
                    style: FillStyle(eoFill: true)
                )
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Reusable Apple HIG Glass Card

public struct AuraGlassCard<Content: View>: View {
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let borderColor: Color
    private let content: Content

    public init(
        padding: CGFloat = 18,
        cornerRadius: CGFloat = 16,
        borderColor: Color = Color.primary.opacity(0.10),
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.borderColor = borderColor
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

// MARK: - Signal Strength Bars View

public struct SignalBarsView: View {
    public let bars: Int // 1...4
    public let tint: Color

    public init(bars: Int, tint: Color = AuraTheme.cyanGlow) {
        self.bars = min(max(bars, 1), 4)
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index <= bars ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Status Pill Badge

public struct AuraStatusPill: View {
    public let title: String
    public let symbol: String
    public let color: Color

    public init(title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.15))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}
