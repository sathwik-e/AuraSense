import Foundation
import AppKit
import SwiftUI
import OpenDirectory

/// Security-sensitive actions that require the user to type their macOS account password.
public enum ProtectedAction: Equatable {
    case changeTrustedDevice(from: String, to: String)
    case unbindTrustedDevice(name: String)
    case stopAuraSenseCompletely
    case disableBackgroundProtection

    var title: String {
        switch self {
        case .changeTrustedDevice: return "Change Trusted Device"
        case .unbindTrustedDevice: return "Remove Trusted Device"
        case .stopAuraSenseCompletely: return "Stop AuraSense Completely"
        case .disableBackgroundProtection: return "Turn Off Background Protection"
        }
    }

    var explanation: String {
        switch self {
        case .changeTrustedDevice(let from, let to):
            return "Replace “\(from)” with “\(to)” as the device that locks and unlocks this Mac."
        case .unbindTrustedDevice(let name):
            return "Stop using “\(name)” to lock and unlock this Mac."
        case .stopAuraSenseCompletely:
            return "Quit AuraSense fully. Proximity lock and unlock stop until AuraSense is opened again."
        case .disableBackgroundProtection:
            return "AuraSense will no longer keep running after Quit or relaunch itself if it is closed."
        }
    }

    var confirmLabel: String {
        switch self {
        case .changeTrustedDevice: return "Change Device"
        case .unbindTrustedDevice: return "Remove Device"
        case .stopAuraSenseCompletely: return "Stop AuraSense"
        case .disableBackgroundProtection: return "Turn Off"
        }
    }
}

/// Verifies the current user's macOS account password through OpenDirectory.
///
/// The typed password is checked against the system account database, never against the
/// copy AuraSense keeps in the Keychain, and it is never stored.
enum MacAccountPasswordVerifier {
    static func verify(_ password: String, username: String = NSUserName()) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                let session = ODSession.default()
                let node = try ODNode(session: session, type: ODNodeType(kODNodeTypeAuthentication))
                let record = try node.record(withRecordType: kODRecordTypeUsers, name: username, attributes: nil)
                try record.verifyPassword(password)
                return true
            } catch {
                return false
            }
        }.value
    }
}

/// Presents a hardened password panel before protected actions run.
///
/// Hardening against AuraSense filling the field itself:
/// * every AuraSense credential-injection path is disabled while the panel is open
///   (`CredentialInjectionGuard`), and the transient clipboard copy is wiped;
/// * key events synthesized by AuraSense (marker or originating PID) are dropped;
/// * paste, drag-and-drop, and any multi-character insertion are rejected, so the
///   password must be typed key by key.
@MainActor
public final class MacPasswordAuthorizer: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = MacPasswordAuthorizer()

    @Published fileprivate var action: ProtectedAction?
    @Published fileprivate var errorText: String?
    @Published fileprivate var isVerifying = false
    @Published fileprivate var lockoutRemaining: Int = 0
    @Published fileprivate var password: String = ""

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var completion: ((Bool) -> Void)?
    private var failedAttempts = 0
    private var lockoutUntil: Date?
    private var lockoutTimer: Timer?
    /// Incremented per prompt so a verification that finishes after its prompt was cancelled
    /// can never approve a different, later prompt.
    private var promptGeneration = 0

    private static let maxAttemptsBeforeLockout = 5
    private static let lockoutSeconds: TimeInterval = 30

    private override init() {
        super.init()
        // A protected prompt left open behind the lock screen would otherwise block
        // proximity unlock; treat locking as Cancel.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.cancel()
            }
        }
    }

    public var isPresenting: Bool { panel != nil }

    /// Asks for the Mac password, then calls `completion(true)` only after it verifies.
    public func authorize(_ action: ProtectedAction, completion: @escaping (Bool) -> Void) {
        if panel != nil {
            // Only one protected prompt at a time; the newer request is declined.
            panel?.makeKeyAndOrderFront(nil)
            completion(false)
            return
        }
        promptGeneration += 1
        self.action = action
        self.completion = completion
        self.errorText = nil
        self.isVerifying = false
        self.password = ""
        refreshLockout()

        CredentialInjectionGuard.shared.beginProtectedPrompt()
        installKeyMonitor()

        let content = MacPasswordPromptView(authorizer: self)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 300)

        let newPanel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = action.title
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = hosting
        newPanel.level = .modalPanel
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newPanel.delegate = self
        newPanel.center()
        panel = newPanel

        NSApplication.shared.activate(ignoringOtherApps: true)
        newPanel.makeKeyAndOrderFront(nil)
    }

    /// Async convenience wrapper.
    public func authorize(_ action: ProtectedAction) async -> Bool {
        await withCheckedContinuation { continuation in
            authorize(action) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func submit() {
        guard !isVerifying else { return }
        refreshLockout()
        guard lockoutRemaining == 0 else { return }
        guard !password.isEmpty else {
            errorText = "Type your Mac login password."
            return
        }
        isVerifying = true
        errorText = nil
        let candidate = password
        let generation = promptGeneration
        Task { @MainActor in
            let ok = await MacAccountPasswordVerifier.verify(candidate)
            guard generation == promptGeneration, panel != nil, completion != nil else { return }
            isVerifying = false
            password = ""
            if ok {
                failedAttempts = 0
                finish(granted: true)
            } else {
                failedAttempts += 1
                if failedAttempts >= Self.maxAttemptsBeforeLockout {
                    failedAttempts = 0
                    lockoutUntil = Date().addingTimeInterval(Self.lockoutSeconds)
                    refreshLockout()
                    errorText = "Too many incorrect attempts. Try again in \(lockoutRemaining)s."
                } else {
                    errorText = "Incorrect password. Try again."
                }
                NSSound.beep()
            }
        }
    }

    fileprivate func cancel() {
        finish(granted: false)
    }

    fileprivate func rejectedInsertion() {
        password = ""
        errorText = "Paste and automatic fill are disabled here. Type your password."
    }

    private func finish(granted: Bool) {
        let callback = completion
        completion = nil
        isVerifying = false
        removeKeyMonitor()
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        action = nil
        password = ""
        CredentialInjectionGuard.shared.endProtectedPrompt()
        callback?(granted)
    }

    private func refreshLockout() {
        guard let until = lockoutUntil else {
            lockoutRemaining = 0
            return
        }
        let remaining = Int(ceil(until.timeIntervalSinceNow))
        if remaining <= 0 {
            lockoutUntil = nil
            lockoutRemaining = 0
            lockoutTimer?.invalidate()
            lockoutTimer = nil
            if errorText?.hasPrefix("Too many") == true { errorText = nil }
        } else {
            lockoutRemaining = remaining
            if lockoutTimer == nil {
                lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshLockout() }
                }
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if CredentialInjectionGuard.isAuraSenseSynthetic(event) {
                return nil
            }
            // Block ⌘V paste into the protected field.
            if event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                Task { @MainActor in self.rejectedInsertion() }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    public func windowWillClose(_ notification: Notification) {
        if completion != nil {
            // Closed via the title bar button: treat as cancel.
            panel = nil
            finish(granted: false)
        }
    }
}

// MARK: - Prompt UI

private struct MacPasswordPromptView: View {
    @ObservedObject var authorizer: MacPasswordAuthorizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AuraTheme.indigoGlow.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AuraTheme.cyanGlow)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(authorizer.action?.title ?? "Authorization Required")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Enter the password for “\(NSUserName())”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Text(authorizer.action?.explanation ?? "")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)

            GuardedSecureField(
                text: $authorizer.password,
                placeholder: "Mac login password",
                isEnabled: !authorizer.isVerifying && authorizer.lockoutRemaining == 0,
                onSubmit: { authorizer.submit() },
                onRejectedInsertion: { authorizer.rejectedInsertion() }
            )
            .frame(height: 24)

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                Text("AuraSense cannot fill this field. Type your password yourself.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            if let error = authorizer.errorText {
                Text(authorizer.lockoutRemaining > 0
                     ? "Too many incorrect attempts. Try again in \(authorizer.lockoutRemaining)s."
                     : error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AuraTheme.crimsonGlow)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { authorizer.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    authorizer.submit()
                } label: {
                    if authorizer.isVerifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(authorizer.action?.confirmLabel ?? "Authorize")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.indigoGlow)
                .disabled(authorizer.password.isEmpty || authorizer.isVerifying || authorizer.lockoutRemaining > 0)
            }
        }
        .padding(22)
        .padding(.top, 8)
        .frame(width: 420, height: 300)
    }
}

/// NSSecureTextField wrapper that only accepts one typed character per edit, rejecting paste,
/// drag-and-drop, services, and bulk injection.
private struct GuardedSecureField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onRejectedInsertion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.unregisterDraggedTypes()
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.lastAcceptedValue = text
        }
        field.isEnabled = isEnabled
        if isEnabled, field.window?.firstResponder == nil {
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GuardedSecureField
        var lastAcceptedValue = ""

        init(_ parent: GuardedSecureField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue
            // A human typing adds at most one character per change; deletions are always fine.
            if newValue.count > lastAcceptedValue.count + 1 {
                field.stringValue = ""
                lastAcceptedValue = ""
                parent.text = ""
                parent.onRejectedInsertion()
                return
            }
            lastAcceptedValue = newValue
            parent.text = newValue
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}
