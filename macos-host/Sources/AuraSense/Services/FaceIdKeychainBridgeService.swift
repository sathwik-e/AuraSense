import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import Network
import Security

/// iPhone → Mac password auto-fill bridge.
///
/// A small HTTP listener on the LAN (port 8765) lets the paired iPhone ask AuraSense to fill the
/// Mac password, either from a Safari Home Screen bookmark or an iOS Shortcut. Every request that
/// can trigger a fill must carry the per-install pairing token (header `X-AuraSense-Token` or
/// query parameter `t=`), and fills only happen on POST — a GET merely serves the page, and only
/// to a request that already presented the valid token.
@MainActor
public final class FaceIdKeychainBridgeService: ObservableObject {
    public static let shared = FaceIdKeychainBridgeService()

    private enum Keys {
        static let bridgeEnabled = "aurasense.faceid.bridgeEnabled"
    }

    private static let tokenKeychainService = "com.aurasense.mac.bridge-token"
    private static let tokenKeychainAccount = "pairingToken"
    private static let tokenHeaderName = "x-aurasense-token"
    private static let maxRequestBytes = 16 * 1024
    private static let requestTimeoutSeconds: TimeInterval = 5
    private static let fillThrottleSeconds: TimeInterval = 1.5

    /// Starting/stopping the HTTP listener follows this setting.
    @Published public var isBridgeEnabled: Bool {
        didSet {
            guard oldValue != isBridgeEnabled else { return }
            UserDefaults.standard.set(isBridgeEnabled, forKey: Keys.bridgeEnabled)
            updateListenerForEnabledState()
            if !isBridgeEnabled {
                setIfChanged(\.activePromptProcess, nil)
                setIfChanged(\.isSecureTextFieldFocused, false)
            }
        }
    }
    @AppStorage("aurasense.faceid.requireDeviceInRangeForPost") public var requireDeviceInRangeForPost: Bool = true
    @AppStorage("aurasense.faceid.onlyWhenExternalMonitor") public var onlyWhenExternalMonitorConnected: Bool = false
    @AppStorage("aurasense.faceid.allowContinuityWake") public var allowContinuityBleFaceIdWake: Bool = true
    @Published public var relayPort: UInt16 = 8765

    @Published public private(set) var onlineDisplayCount: Int = 1
    @Published public private(set) var hasExternalMonitor: Bool = false
    @Published public private(set) var isClamshellClosed: Bool = false
    @Published public private(set) var activePromptProcess: String? = nil
    @Published public private(set) var isSecureTextFieldFocused: Bool = false
    @Published public private(set) var localLanIPAddress: String = "192.168.1.8"
    @Published public private(set) var lastBridgeEvent: String = "Ready — waiting for a tokenized request from your iPhone"
    /// Continuity "unlocked" state of the bound device only.
    @Published public private(set) var continuityFaceIdUnlocked: Bool = false
    /// Per-install secret every fill request must present (base64url, 32 random bytes).
    @Published public private(set) var pairingToken: String
    @Published public private(set) var isRelayListening: Bool = false
    @Published public private(set) var relayListenerStatus: String = "Stopped"

    private var monitorTimer: Timer?
    private var listener: NWListener?
    private var listenerRetryWorkItem: DispatchWorkItem?
    private var listenerRetryAttempt = 0
    private var lastAutoFillTime: Date = .distantPast
    private var continuityUnlockedByPeripheral: [UUID: Bool] = [:]

    /// Reused system-wide AX element with a short messaging timeout so a hung frontmost app
    /// cannot stall the main actor for the default ~6 s per call.
    private let systemWideElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    private init() {
        isBridgeEnabled = (UserDefaults.standard.object(forKey: Keys.bridgeEnabled) as? Bool) ?? true
        let (token, tokenError) = Self.loadOrCreatePairingToken()
        pairingToken = token
        if let tokenError {
            lastBridgeEvent = tokenError
        }

        resolveLocalIPAddress()
        refreshDisplayAndPromptState()
        updateListenerForEnabledState()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplayAndPromptState()
            }
        }
    }

    // MARK: - URLs

    private var relayBaseURL: String {
        "http://\(localLanIPAddress):\(relayPort)"
    }

    /// Tokenized page URL for the iPhone Safari Home Screen bookmark.
    public var passkeyRelayURL: String {
        "\(relayBaseURL)/faceid?t=\(pairingToken)"
    }

    /// Tokenized POST endpoint for an iOS Shortcut ("Get Contents of URL", Method POST).
    public var shortcutWebhookURL: String {
        "\(relayBaseURL)/api/v1/faceid-autofill?t=\(pairingToken)"
    }

    /// POST endpoint without the token, for Shortcuts that send the `X-AuraSense-Token` header.
    public var shortcutWebhookBaseURL: String {
        "\(relayBaseURL)/api/v1/faceid-autofill"
    }

    public var pairingTokenHeaderName: String { "X-AuraSense-Token" }

    // MARK: - Pairing Token

    /// Replaces the pairing token. Existing iPhone bookmarks and Shortcuts stop working until re-added.
    public func regeneratePairingToken() {
        let fresh = Self.generateToken()
        if let error = Self.storeToken(fresh) {
            lastBridgeEvent = "New pairing token is active for this session only (Keychain save failed: \(error))."
        } else {
            lastBridgeEvent = "Pairing token regenerated. Re-add the iPhone bookmark / Shortcut."
        }
        pairingToken = fresh
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isWellFormedToken(_ token: String) -> Bool {
        token.count >= 43 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func tokenBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenKeychainService,
            kSecAttrAccount as String: tokenKeychainAccount
        ]
    }

    private static func loadOrCreatePairingToken() -> (String, String?) {
        var query = tokenBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8),
           isWellFormedToken(token) {
            return (token, nil)
        }
        let fresh = generateToken()
        if let error = storeToken(fresh) {
            return (fresh, "Pairing token could not be saved to the Keychain (\(error)); it will change on next launch.")
        }
        return (fresh, nil)
    }

    /// Returns nil on success, or an error description.
    private static func storeToken(_ token: String) -> String? {
        SecItemDelete(tokenBaseQuery() as CFDictionary)
        var add = tokenBaseQuery()
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "AuraSense iPhone Bridge Pairing Token"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
        }
        return nil
    }

    private func isValidToken(_ presented: String?) -> Bool {
        guard let presented, !presented.isEmpty else { return false }
        let expected = Array(pairingToken.utf8)
        let given = Array(presented.utf8)
        var diff: UInt8 = given.count == expected.count ? 0 : 1
        for i in 0..<expected.count {
            let g = i < given.count ? given[i] : 0
            diff |= g ^ expected[i]
        }
        return diff == 0
    }

    // MARK: - Display & Prompt State

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<FaceIdKeychainBridgeService, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    public func refreshDisplayAndPromptState() {
        var displayCount: UInt32 = 0
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &activeIDs, &displayCount) == .success {
            let ids = Array(activeIDs.prefix(Int(displayCount)))
            let hasBuiltin = ids.contains { CGDisplayIsBuiltin($0) != 0 }
            let external = displayCount > 1 || (displayCount == 1 && !hasBuiltin)
            setIfChanged(\.onlineDisplayCount, Int(displayCount))
            setIfChanged(\.hasExternalMonitor, external)
            setIfChanged(\.isClamshellClosed, external && !hasBuiltin)
        }

        // Focused-field tracking is informational only; skip the AX round-trips while paused.
        guard isBridgeEnabled, MacLockUnlockController.shared.isAccessibilityTrusted else {
            setIfChanged(\.activePromptProcess, nil)
            setIfChanged(\.isSecureTextFieldFocused, false)
            return
        }

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let elem = focusedRef, CFGetTypeID(elem) == AXUIElementGetTypeID() else {
            setIfChanged(\.activePromptProcess, nil)
            setIfChanged(\.isSecureTextFieldFocused, false)
            return
        }

        let axElem = elem as! AXUIElement
        var isSecure = (copyStringAttr(axElem, kAXSubroleAttribute) == "AXSecureTextField")
        if !isSecure, copyStringAttr(axElem, kAXRoleAttribute) == "AXTextField" {
            isSecure = (copyStringAttr(axElem, kAXDescriptionAttribute) ?? "").lowercased().contains("password")
        }

        setIfChanged(\.isSecureTextFieldFocused, isSecure)
        let process: String? = isSecure
            ? (NSWorkspace.shared.frontmostApplication?.localizedName ?? "CoreAuthUI / Keychain")
            : nil
        setIfChanged(\.activePromptProcess, process)
    }

    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &val) == .success,
           let str = val as? String {
            return str
        }
        return nil
    }

    // MARK: - Continuity BLE Wake

    /// Called for every Apple (0x004C) advertisement. Acts only on the bound device, keeps the
    /// Nearby-Info unlock state per peripheral, and fills only the Mac lock screen.
    public func handleContinuityManufacturerData(_ mfgData: Data, rssi: Int, peripheralID: UUID) {
        let engine = BLEProximityEngine.shared
        guard !engine.selectedDeviceID.isEmpty,
              peripheralID.uuidString.caseInsensitiveCompare(engine.selectedDeviceID) == .orderedSame else {
            return
        }
        guard mfgData.count >= 6 else { return }
        let companyID = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
        guard companyID == 0x004C else { return }

        var idx = 2
        while idx + 2 <= mfgData.count {
            let fType = mfgData[idx]
            let fLen = Int(mfgData[idx + 1])
            let pStart = idx + 2
            let pEnd = pStart + fLen
            if pEnd > mfgData.count { break }

            if fType == 0x10 && fLen >= 2 {
                let activity = mfgData[pStart] & 0x0F
                let flags = mfgData[pStart + 1]
                let wasUnlocked = continuityUnlockedByPeripheral[peripheralID] ?? false
                let nowUnlocked = ((flags & 0x08) != 0) || (activity >= 0x07)
                continuityUnlockedByPeripheral[peripheralID] = nowUnlocked
                setIfChanged(\.continuityFaceIdUnlocked, nowUnlocked)

                if isBridgeEnabled && allowContinuityBleFaceIdWake && !wasUnlocked && nowUnlocked
                    && rssi >= Int(engine.unlockThresholdRSSI)
                    && MacLockUnlockController.shared.refreshScreenLockState() {
                    Task { @MainActor in
                        _ = await self.autoFillActiveKeychainPrompt(triggerSource: "iPhone Continuity BLE Wake")
                    }
                }
                break
            }
            idx = pEnd
        }
    }

    /// Fails closed: false when nothing is bound, the bound device was never seen, its signal
    /// is stale, or it is below the lock threshold.
    public var isUserDeviceCurrentlyInRange: Bool {
        BLEProximityEngine.shared.isBoundDevicePresent
    }

    // MARK: - Fill

    private enum FillStatus {
        case filled
        case throttled
        case blocked
    }

    private struct FillOutcome {
        let status: FillStatus
        let message: String
    }

    @discardableResult
    public func autoFillActiveKeychainPrompt(triggerSource: String) async -> (Bool, String) {
        let outcome = await performFill(triggerSource: triggerSource)
        return (outcome.status == .filled, outcome.message)
    }

    private func blocked(_ msg: String) -> FillOutcome {
        lastBridgeEvent = msg
        return FillOutcome(status: .blocked, message: msg)
    }

    private func performFill(triggerSource: String) async -> FillOutcome {
        guard CredentialInjectionGuard.shared.mayInjectCredentials() else {
            return blocked("Blocked: a protected AuraSense prompt requires the password to be typed by hand.")
        }
        guard isBridgeEnabled else {
            return FillOutcome(status: .blocked, message: "Auto-Fill Bridge is paused.")
        }

        guard Date().timeIntervalSince(lastAutoFillTime) > Self.fillThrottleSeconds else {
            return FillOutcome(status: .throttled, message: "Throttled – try again in a moment.")
        }

        if requireDeviceInRangeForPost && !isUserDeviceCurrentlyInRange {
            return blocked("Blocked: bound BLE device is not in range (or no device is bound).")
        }

        let controller = MacLockUnlockController.shared
        guard controller.refreshAccessibilityStatus(prompt: false) else {
            return blocked("Blocked: Grant Accessibility permission to AuraSense in System Settings.")
        }

        guard KeychainManager.shared.hasStoredPassword() else {
            return blocked("Blocked: Save your macOS password in AuraSense Security & Keychain settings first.")
        }

        lastAutoFillTime = Date()
        let okMsg: String

        if controller.refreshScreenLockState() {
            // Screen is locked: type into the lock screen; unlockMac verifies the unlock
            // and drives the unlock sound/animation itself.
            let result = await controller.unlockMac(playChime: BLEProximityEngine.shared.playSoundEffects)
            switch result {
            case .unlockedSuccessfully:
                okMsg = "Unlocked Mac lock screen via \(triggerSource)"
            case .alreadyUnlocked:
                return blocked("Mac was already unlocked — nothing filled.")
            case .missingAccessibilityPermission:
                return blocked("Blocked: Grant Accessibility permission to AuraSense in System Settings.")
            case .missingKeychainPassword:
                return blocked("Blocked: Save your macOS password in AuraSense Security & Keychain settings first.")
            case .skipped(let reason):
                return blocked("Unlock skipped: \(reason)")
            case .failed(let reason):
                return blocked("Unlock failed: \(reason)")
            }
        } else {
            let decision = CredentialInjectionGuard.shared.focusedFieldInjectionDecision(requireSecureField: true)
            guard decision.allowed else {
                return blocked("Blocked: \(decision.reason)")
            }
            guard let password = KeychainManager.shared.retrievePassword(), !password.isEmpty else {
                return blocked("Blocked: Save your macOS password in AuraSense Security & Keychain settings first.")
            }
            let targetName = activePromptProcess ?? "Active macOS Password Prompt"
            controller.wakeDisplayAndSendMonitorInput()
            guard await controller.typeCredential(password, submitWithReturn: true) else {
                return blocked("Blocked: password entry was aborted (protected prompt, focus change, or another fill in progress).")
            }
            if BLEProximityEngine.shared.playSoundEffects {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            okMsg = "Auto-filled Mac password into \(targetName) via \(triggerSource)"
        }

        lastBridgeEvent = okMsg
        BLEProximityEngine.shared.appendLog(
            kind: .unlocked,
            title: "Password Filled (\(triggerSource))",
            detail: okMsg,
            rssi: BLEProximityEngine.shared.trackedDevice?.rawRSSI
        )
        return FillOutcome(status: .filled, message: okMsg)
    }

    // MARK: - HTTP Listener Lifecycle

    private func updateListenerForEnabledState() {
        if isBridgeEnabled {
            listenerRetryAttempt = 0
            startHttpPasskeyRelayServer()
        } else {
            stopHttpPasskeyRelayServer()
        }
    }

    private func stopHttpPasskeyRelayServer() {
        listenerRetryWorkItem?.cancel()
        listenerRetryWorkItem = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isRelayListening = false
        relayListenerStatus = "Stopped"
        lastBridgeEvent = "Auto-Fill Bridge paused — relay port \(relayPort) closed."
    }

    private func startHttpPasskeyRelayServer() {
        guard isBridgeEnabled, listener == nil else { return }
        listenerRetryWorkItem?.cancel()
        listenerRetryWorkItem = nil
        guard let port = NWEndpoint.Port(rawValue: relayPort) else {
            relayListenerStatus = "Invalid port \(relayPort)"
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let nwListener = try NWListener(using: params, on: port)
            nwListener.stateUpdateHandler = { [weak self, weak nwListener] state in
                Task { @MainActor in
                    guard let self, let nwListener else { return }
                    self.handleListenerState(state, for: nwListener)
                }
            }
            nwListener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    guard let self, self.isBridgeEnabled else {
                        conn.cancel()
                        return
                    }
                    self.acceptConnection(conn)
                }
            }
            listener = nwListener
            relayListenerStatus = "Starting on port \(relayPort)…"
            nwListener.start(queue: .main)
        } catch {
            listener = nil
            isRelayListening = false
            relayListenerStatus = "Failed: \(error.localizedDescription)"
            lastBridgeEvent = "Relay port \(relayPort) failed to start: \(error.localizedDescription)"
            scheduleListenerRetry()
        }
    }

    private func handleListenerState(_ state: NWListener.State, for nwListener: NWListener) {
        guard nwListener === listener else { return }
        switch state {
        case .ready:
            listenerRetryAttempt = 0
            isRelayListening = true
            relayListenerStatus = "Listening on port \(relayPort)"
        case .failed(let error):
            isRelayListening = false
            nwListener.stateUpdateHandler = nil
            nwListener.newConnectionHandler = nil
            nwListener.cancel()
            listener = nil
            relayListenerStatus = "Failed: \(error.localizedDescription)"
            lastBridgeEvent = "Relay port \(relayPort) failed: \(error.localizedDescription) — retrying."
            scheduleListenerRetry()
        case .waiting(let error):
            isRelayListening = false
            relayListenerStatus = "Waiting: \(error.localizedDescription)"
        case .cancelled:
            isRelayListening = false
        default:
            break
        }
    }

    private func scheduleListenerRetry() {
        guard isBridgeEnabled else { return }
        listenerRetryWorkItem?.cancel()
        let delay = min(2.0 * pow(2.0, Double(min(listenerRetryAttempt, 4))), 30.0)
        listenerRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.listenerRetryWorkItem = nil
                self?.startHttpPasskeyRelayServer()
            }
        }
        listenerRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - HTTP Request Handling

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private enum ParseResult {
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: String)
    }

    private static func parseRequest(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxRequestBytes ? .invalid(status: "431 Request Header Fields Too Large") : .incomplete
        }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(status: "400 Bad Request") }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .invalid(status: "400 Bad Request")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard let comps = URLComponents(string: "http://localhost" + target) else {
            return .invalid(status: "400 Bad Request")
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: "400 Bad Request") }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, ["host", "origin", "content-length", tokenHeaderName].contains(name) {
                return .invalid(status: "400 Bad Request")
            }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: "411 Length Required")
        }
        var bodyLength = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid(status: "400 Bad Request") }
            bodyLength = n
        }
        let bodyStart = headerEnd.upperBound
        if bodyStart - buffer.startIndex + bodyLength > maxRequestBytes {
            return .invalid(status: "413 Payload Too Large")
        }
        if buffer.endIndex - bodyStart < bodyLength {
            return .incomplete
        }
        return .complete(HTTPRequest(method: method, path: comps.path, query: query, headers: headers))
    }

    private func acceptConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        // Close connections that do not deliver a complete request within the deadline.
        let timeout = Task { @MainActor in
            guard (try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeoutSeconds * 1_000_000_000))) != nil else { return }
            conn.cancel()
        }
        receiveRequest(conn, buffer: Data(), timeout: timeout)
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data, timeout: Task<Void, Never>) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    timeout.cancel()
                    conn.cancel()
                    return
                }
                var buf = buffer
                if let data { buf.append(data) }
                switch Self.parseRequest(buf) {
                case .complete(let request):
                    timeout.cancel()
                    await self.route(request, on: conn)
                case .invalid(let status):
                    timeout.cancel()
                    self.sendText(conn, status: status, body: status)
                case .incomplete:
                    if error != nil || isComplete {
                        timeout.cancel()
                        conn.cancel()
                    } else {
                        self.receiveRequest(conn, buffer: buf, timeout: timeout)
                    }
                }
            }
        }
    }

    private func route(_ request: HTTPRequest, on conn: NWConnection) async {
        let fillPaths: Set<String> = ["/api/v1/faceid-autofill", "/api/v1/passkey-assert", "/faceid"]
        let pagePaths: Set<String> = ["/", "/faceid", "/api/v1/faceid-autofill"]

        switch request.method {
        case "GET":
            if request.path == "/favicon.ico" {
                send(conn, status: "204 No Content", contentType: nil, body: Data())
                return
            }
            guard pagePaths.contains(request.path) else {
                sendText(conn, status: "404 Not Found", body: "Not found")
                return
            }
            // GET never fills. Only a request that already holds the token gets the page.
            guard isValidToken(request.query["t"]) else {
                sendHTML(conn, status: "401 Unauthorized", html: renderUnauthorizedHTML())
                return
            }
            sendHTML(conn, status: "200 OK", html: renderInstructionsAndTriggerHTML())

        case "POST":
            guard fillPaths.contains(request.path) else {
                sendText(conn, status: "404 Not Found", body: "Not found")
                return
            }
            if let origin = request.headers["origin"] {
                let host = request.headers["host"] ?? ""
                guard !host.isEmpty, origin.lowercased() == "http://\(host.lowercased())" else {
                    sendJSON(conn, status: "403 Forbidden", ok: false, message: "Cross-origin requests are not allowed.")
                    return
                }
            }
            let presented = request.headers[Self.tokenHeaderName] ?? request.query["t"]
            guard isValidToken(presented) else {
                sendJSON(conn, status: "401 Unauthorized", ok: false, message: "Missing or invalid AuraSense pairing token. Re-add the bookmark or Shortcut from AuraSense on your Mac.")
                return
            }
            let outcome = await performFill(triggerSource: "iPhone Bridge (POST \(request.path))")
            let status: String
            switch outcome.status {
            case .filled: status = "200 OK"
            case .throttled: status = "429 Too Many Requests"
            case .blocked: status = "409 Conflict"
            }
            sendJSON(conn, status: status, ok: outcome.status == .filled, message: outcome.message)

        default:
            send(conn, status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8",
                 body: Data("Method not allowed".utf8), extraHeaders: ["Allow: GET, POST"])
        }
    }

    private func sendJSON(_ conn: NWConnection, status: String, ok: Bool, message: String) {
        let payload: [String: Any] = ["ok": ok, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        send(conn, status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private func sendHTML(_ conn: NWConnection, status: String, html: String) {
        send(conn, status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8), extraHeaders: [
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        ])
    }

    private func sendText(_ conn: NWConnection, status: String, body: String) {
        send(conn, status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func send(_ conn: NWConnection, status: String, contentType: String?, body: Data, extraHeaders: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for h in extraHeaders { head += "\(h)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func resolveLocalIPAddress() {
        var address = "192.168.1.8"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                let addr = ptr.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                   addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let candidate = String(cString: hostname)
                        if !candidate.hasPrefix("169.254") {
                            address = candidate
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        localLanIPAddress = address
    }

    // MARK: - Pages

    /// Served to any GET without a valid token. Contains no token or endpoint secrets.
    private func renderUnauthorizedHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1"/>
        <title>AuraSense</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; padding: 32px 16px; background: #02040a; color: #f5f9ff;
                 font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; }
          p { max-width: 380px; margin: 12px auto; font-size: 14px; color: rgba(255,255,255,0.78); line-height: 1.5; }
        </style></head>
        <body>
          <h1 style="font-size:18px;">Pairing token required</h1>
          <p>This link is missing a valid AuraSense pairing token. On your Mac, open AuraSense → Face ID Bridge and re-add the bookmark or Shortcut from there.</p>
        </body></html>
        """
    }

    /// Served only to a GET that already presented the valid token; the page embeds that token
    /// so its single automatic fill (and the manual button) can POST with the header.
    public func renderInstructionsAndTriggerHTML() -> String {
        let token = pairingToken
        let postEndpoint = shortcutWebhookBaseURL

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
        <meta name="referrer" content="no-referrer"/>
        <title>AuraSense v1.1</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 24px 16px 40px;
            background: #02040a;
            color: #f5f9ff;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
            display: flex; flex-direction: column; align-items: center;
          }
          .container { width: 100%; max-width: 420px; }
          .hero {
            text-align: center; padding: 26px 18px 22px; border-radius: 24px;
            background: radial-gradient(circle at 50% 35%, #071936 0%, #03060e 75%);
            border: 1px solid rgba(56, 214, 255, 0.35);
            box-shadow: 0 0 36px rgba(34, 150, 255, 0.18);
            margin-bottom: 16px;
          }
          .orbit-wrap {
            width: 112px; height: 112px; margin: 0 auto 14px;
            position: relative; display: flex; align-items: center; justify-content: center;
          }
          .wordmark {
            font-size: 18px; font-weight: 300; letter-spacing: 5px; margin: 0 0 8px;
          }
          .wordmark .sense { color: #38d6ff; }
          .sub { font-size: 13px; color: rgba(255,255,255,0.72); margin: 0 0 16px; }
          .btn-post {
            width: 100%; padding: 15px 18px; border-radius: 14px; border: none;
            background: linear-gradient(135deg, #1f5eff 0%, #29c4ff 60%, #38f2ee 100%);
            color: #020610; font-size: 15px; font-weight: 700; cursor: pointer;
          }
          .btn-post:disabled { opacity: 0.55; }
          #status {
            margin-top: 12px; padding: 9px 12px; border-radius: 10px;
            background: rgba(56, 214, 255, 0.10); color: #38f2ee;
            font-size: 13px; font-weight: 600;
          }
          .card {
            background: rgba(255,255,255,0.03);
            border: 1px solid rgba(255,255,255,0.10);
            border-radius: 18px; padding: 16px;
          }
          .card h2 { font-size: 14px; margin: 0 0 10px; color: #38d6ff; letter-spacing: 0.5px; }
          .code-box {
            background: #000; border: 1px solid rgba(56,214,255,0.28);
            padding: 9px 11px; border-radius: 9px; font-family: ui-monospace, SFMono-Regular, monospace;
            font-size: 12px; color: #38f2ee; word-break: break-all; margin-bottom: 12px;
          }
          ol { margin: 0; padding-left: 18px; font-size: 13px; line-height: 1.55; color: rgba(255,255,255,0.85); }
          ol li { margin-bottom: 7px; }
        </style>
        </head>
        <body>
          <div class="container">
            <div class="hero">
              <div class="orbit-wrap">
                <svg viewBox="0 0 120 120" width="112" height="112">
                  <defs>
                    <linearGradient id="orbitGrad" x1="0%" y1="100%" x2="100%" y2="0%">
                      <stop offset="0%" stop-color="#1f5eff"/>
                      <stop offset="55%" stop-color="#38d6ff"/>
                      <stop offset="100%" stop-color="#38f2ee"/>
                    </linearGradient>
                  </defs>
                  <circle cx="60" cy="60" r="52" fill="none" stroke="url(#orbitGrad)" stroke-width="2.5"/>
                  <path d="M 34 62 A 28 28 0 1 1 86 62 A 26.5 26.5 0 1 0 34 62 Z" fill="url(#orbitGrad)"/>
                </svg>
              </div>
              <div class="wordmark"><span>ΛURΛ</span><span class="sense">SENSE</span></div>
              <p class="sub">Opening this page fills your Mac password once — into the lock screen or a focused macOS password prompt.</p>
              <button id="fillBtn" class="btn-post" onclick="sendPostAutoFill('manual_button')">Fill Mac Password Again</button>
              <div id="status">Filling Mac password...</div>
            </div>

            <div class="card">
              <h2>Quick Setup</h2>
              <div class="code-box">\(postEndpoint)</div>
              <ol>
                <li><strong>Home Screen Web Icon</strong>: Tap <strong>Share &gt; Add to Home Screen</strong> on this page. Opening the icon fills your Mac password once.</li>
                <li><strong>iOS Shortcut (POST)</strong>: Add <strong>Get Contents of URL</strong> with the URL above, Method <strong>POST</strong>, and a header <strong>X-AuraSense-Token</strong> set to the pairing token shown in AuraSense on your Mac.</li>
                <li>If you update AuraSense or regenerate the token, re-add the icon and Shortcut.</li>
              </ol>
            </div>
          </div>

          <script>
          const AURA_TOKEN = "\(token)";
          let fillInFlight = false;
          async function sendPostAutoFill(trigger) {
            if (fillInFlight) return;
            fillInFlight = true;
            const st = document.getElementById('status');
            const btn = document.getElementById('fillBtn');
            btn.disabled = true;
            st.style.color = '#38f2ee';
            st.textContent = 'Filling Mac password...';
            try {
              const res = await fetch('/api/v1/faceid-autofill', {
                method: 'POST',
                cache: 'no-store',
                headers: { 'Content-Type': 'application/json', 'X-AuraSense-Token': AURA_TOKEN },
                body: JSON.stringify({ trigger: trigger, ts: Date.now() })
              });
              const data = await res.json();
              st.style.color = data.ok ? '#38f2ee' : '#ff6b81';
              st.textContent = data.ok ? 'Mac password filled.' : (data.message || 'Request refused.');
            } catch (e) {
              st.style.color = '#ff6b81';
              st.textContent = 'Connection error: ' + e.message;
            } finally {
              fillInFlight = false;
              btn.disabled = false;
            }
          }
          // Exactly one automatic fill per page open; further fills need the button.
          let autoFillDone = false;
          function autoFillOnce() {
            if (autoFillDone) return;
            autoFillDone = true;
            sendPostAutoFill('auto_open');
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', autoFillOnce, { once: true });
          } else {
            autoFillOnce();
          }
          </script>
        </body>
        </html>
        """
    }
}
