import SwiftUI

/// Drop-in DynamicProperty state wrapper backed by StateObject so AuraSense compiles cleanly
/// under both Xcode and standalone macOS CommandLineTools (where SwiftUIMacros plugin is omitted).
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

/// Defines AuraSense's signature Apple Design Language aesthetic:
/// layered vibrancy, concentric aura gradients, SF Pro Rounded metrics, and glassmorphic surfaces.
public enum AuraTheme {
    public static let cyanGlow = Color(red: 0.16, green: 0.85, blue: 0.96)
    public static let indigoGlow = Color(red: 0.42, green: 0.36, blue: 0.98)
    public static let emeraldGlow = Color(red: 0.16, green: 0.88, blue: 0.65)
    public static let amberGlow = Color(red: 1.0, green: 0.70, blue: 0.20)
    public static let crimsonGlow = Color(red: 0.98, green: 0.32, blue: 0.44)
    public static let deepMidnight = Color(red: 0.05, green: 0.06, blue: 0.11)

    public static var auraLinearGradient: LinearGradient {
        LinearGradient(
            colors: [cyanGlow, indigoGlow, Color(red: 0.68, green: 0.32, blue: 0.96)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static func stateAccentColor(for state: ProximityState) -> Color {
        switch state {
        case .unlockedInRange:
            return emeraldGlow
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
