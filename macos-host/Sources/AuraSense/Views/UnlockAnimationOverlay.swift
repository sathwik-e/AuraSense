import SwiftUI
import AppKit

/// Coordinates the unlock "celebration" (sound + animation) so it plays once per real unlock.
///
/// AuraSense used to play its chime right after typing the password, before macOS confirmed
/// the unlock (so a wrong password still chimed). The celebration now waits for
/// `com.apple.screenIsUnlocked`, with a lock-state poll as a fallback.
@MainActor
public final class UnlockCelebrationCoordinator: ObservableObject {
    public static let shared = UnlockCelebrationCoordinator()

    @AppStorage("aurasense.showUnlockAnimation") public var showUnlockAnimation: Bool = true
    @AppStorage("aurasense.celebrateManualUnlocks") public var celebrateManualUnlocks: Bool = false

    private var pendingAuraUnlockDeadline: Date?
    private var pendingDeviceName: String?
    private var fallbackPoll: Timer?
    private var lastCelebration: Date = .distantPast

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemUnlocked() }
        }
    }

    /// Call right after AuraSense submits the password on the lock screen.
    public func expectAuraUnlock(deviceName: String?) {
        pendingAuraUnlockDeadline = Date().addingTimeInterval(15)
        pendingDeviceName = deviceName
        fallbackPoll?.invalidate()
        var polls = 0
        fallbackPoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                polls += 1
                if self.pendingAuraUnlockDeadline == nil || polls > 30 {
                    timer.invalidate()
                    if polls > 30 { self.pendingAuraUnlockDeadline = nil }
                    return
                }
                // Give the notification a moment to arrive before relying on the poll.
                if polls >= 3, !MacLockUnlockController.shared.refreshScreenLockState() {
                    timer.invalidate()
                    self.handleSystemUnlocked()
                }
            }
        }
    }

    /// Shortens the pending expectation after an unconfirmed attempt: a late confirmation of the
    /// typed password still celebrates, a later manual unlock does not.
    public func limitExpectedAuraUnlock(toSeconds seconds: TimeInterval) {
        guard let deadline = pendingAuraUnlockDeadline else { return }
        pendingAuraUnlockDeadline = min(deadline, Date().addingTimeInterval(seconds))
    }

    /// Called when AuraSense's unlock attempt failed, so a later manual unlock isn't credited to it.
    public func cancelExpectedAuraUnlock() {
        pendingAuraUnlockDeadline = nil
        pendingDeviceName = nil
        fallbackPoll?.invalidate()
        fallbackPoll = nil
    }

    private func handleSystemUnlocked() {
        let isAuraUnlock: Bool
        if let deadline = pendingAuraUnlockDeadline, Date() <= deadline {
            isAuraUnlock = true
        } else {
            isAuraUnlock = false
        }
        pendingAuraUnlockDeadline = nil
        fallbackPoll?.invalidate()
        fallbackPoll = nil

        guard isAuraUnlock || celebrateManualUnlocks else { return }
        // Notification + poll can both land; celebrate once.
        guard Date().timeIntervalSince(lastCelebration) > 3 else { return }
        lastCelebration = Date()

        let name = isAuraUnlock ? pendingDeviceName : nil
        pendingDeviceName = nil
        celebrate(deviceName: name)
    }

    /// Plays the configured unlock sound and (if enabled) the animation.
    public func celebrate(deviceName: String?, forcePreview: Bool = false) {
        if BLEProximityEngine.shared.playSoundEffects || forcePreview {
            UnlockSoundLibrary.shared.playUnlockSound()
        }
        if showUnlockAnimation || forcePreview {
            // Let the lock screen finish dismissing first.
            DispatchQueue.main.asyncAfter(deadline: .now() + (forcePreview ? 0 : 0.25)) {
                UnlockAnimationPresenter.shared.present(deviceName: deviceName)
            }
        }
    }

    public func previewAnimationOnly() {
        UnlockAnimationPresenter.shared.present(deviceName: BLEProximityEngine.shared.selectedDeviceName)
    }
}

/// Shows a transparent, click-through overlay on every display for ~2 seconds.
@MainActor
public final class UnlockAnimationPresenter {
    public static let shared = UnlockAnimationPresenter()

    private var windows: [NSWindow] = []
    private var dismissWorkItem: DispatchWorkItem?
    private static let totalDuration: TimeInterval = 2.1

    private init() {}

    public func present(deviceName: String?) {
        dismiss()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mainScreen = NSScreen.main

        for screen in NSScreen.screens {
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = UnlockAnimationView(
                deviceName: deviceName,
                showsCaption: screen == mainScreen,
                reduceMotion: reduceMotion,
                duration: Self.totalDuration
            )
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            windows.append(window)
        }

        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.totalDuration + 0.1, execute: item)
    }

    public func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}

/// Eclipse "bloom": the AuraSense ring expands from the center, a lock opens, ripples
/// radiate outward, and the whole overlay fades away.
struct UnlockAnimationView: View {
    let deviceName: String?
    let showsCaption: Bool
    let reduceMotion: Bool
    let duration: TimeInterval

    @AuraState private var appeared = false
    @AuraState private var unlocked = false
    @AuraState private var ripple = false
    @AuraState private var fadingOut = false

    var body: some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            ZStack {
                RadialGradient(
                    colors: [AuraTheme.deepMidnight.opacity(0.55), AuraTheme.deepMidnight.opacity(0.0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: base * 0.6
                )
                .opacity(appeared ? 1 : 0)

                if !reduceMotion {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(AuraTheme.auraLinearGradient, lineWidth: 2.5)
                            .frame(width: base * 0.22, height: base * 0.22)
                            .scaleEffect(ripple ? 2.6 + CGFloat(i) * 0.9 : 0.8)
                            .opacity(ripple ? 0 : 0.75)
                            .animation(.easeOut(duration: 1.3).delay(0.35 + Double(i) * 0.16), value: ripple)
                    }
                }

                ZStack {
                    Circle()
                        .fill(AuraTheme.deepMidnight.opacity(0.82))
                        .frame(width: base * 0.2, height: base * 0.2)
                    Circle()
                        .stroke(AuraTheme.auraLinearGradient, lineWidth: 5)
                        .frame(width: base * 0.2, height: base * 0.2)
                        .shadow(color: AuraTheme.cyanGlow.opacity(0.8), radius: 22)
                    Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: base * 0.07, weight: .semibold))
                        .foregroundStyle(unlocked ? AuraTheme.emeraldGlow : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .offset(x: unlocked ? base * 0.006 : 0)
                }
                .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.55))
                .opacity(appeared ? 1 : 0)

                if showsCaption {
                    VStack(spacing: 6) {
                        Text("Welcome back")
                            .font(.system(size: max(22, base * 0.032), weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        if let name = deviceName, !name.isEmpty {
                            Text("Unlocked by \(name)")
                                .font(.system(size: max(13, base * 0.016), weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .offset(y: base * 0.17)
                    .opacity(unlocked ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(fadingOut ? 0 : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear(perform: run)
    }

    private func run() {
        withAnimation(reduceMotion ? .easeIn(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) {
            appeared = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.3)) { unlocked = true }
            ripple = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, duration - 0.6)) {
            withAnimation(.easeIn(duration: 0.55)) { fadingOut = true }
        }
    }
}
