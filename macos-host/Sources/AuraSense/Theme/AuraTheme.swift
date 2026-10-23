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

/// Defines AuraSense v1's Neon Orbit & Eclipse design language:
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

    /// Returns the bundled menu bar template image name (`AuraEclipseTemplate`, etc.)
    /// located in `Contents/Resources/`. Because the names end in `Template`, macOS AppKit
    /// automatically renders them as crisp adaptive Menu Bar template icons.
    public static func menuBarTemplateImageName(
        state: ProximityState,
        isCalibrating: Bool,
        isPaused: Bool
    ) -> String {
        if isCalibrating {
            return "AuraEclipseScanTemplate"
        }
        if isPaused {
            return "AuraEclipsePausedTemplate"
        }
        switch state {
        case .lockedOutOfRange:
            return "AuraEclipseLockedTemplate"
        case .gracePeriodCountdown:
            return "AuraEclipseScanTemplate"
        case .paused:
            return "AuraEclipsePausedTemplate"
        case .unlockedInRange, .unconfigured:
            return "AuraEclipseTemplate"
        }
    }
}

// MARK: - Brand Typography Wordmark (`Λ U R Λ S E N S E`)

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

/// Renders the signature Neon Orbit + Crescent Eclipse icon in SwiftUI using
/// `.destinationOut` subtraction so ONLY the single upper-right eclipse crescent is drawn.
public struct AuraEclipseLogoView: View {
    public let size: CGFloat
    public let showWordmarkInside: Bool

    public init(size: CGFloat = 44, showWordmarkInside: Bool = false) {
        self.size = size
        self.showWordmarkInside = showWordmarkInside
    }

    public var body: some View {
        ZStack {
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

            Canvas { context, canvasSize in
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height * (showWordmarkInside ? 0.44 : 0.50))
                let sunR = canvasSize.width * (showWordmarkInside ? 0.21 : 0.24)
                let moonR = sunR * 0.95
                let moonCenter = CGPoint(x: c.x - sunR * 0.085, y: c.y + sunR * 0.115)

                context.drawLayer { layer in
                    let sunPath = Path(ellipseIn: CGRect(x: c.x - sunR, y: c.y - sunR, width: sunR * 2, height: sunR * 2))
                    layer.fill(
                        sunPath,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.14, green: 0.46, blue: 1.0),
                                Color(red: 0.55, green: 0.94, blue: 1.0),
                                Color.white
                            ]),
                            startPoint: CGPoint(x: c.x - sunR, y: c.y + sunR * 0.3),
                            endPoint: CGPoint(x: c.x + sunR * 0.7, y: c.y - sunR * 0.8)
                        )
                    )
                    let moonPath = Path(ellipseIn: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
                    layer.blendMode = .destinationOut
                    layer.fill(moonPath, with: .color(.black))
                }
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
