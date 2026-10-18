import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import Network

/// Prioritizes the POST `/api/v1/faceid-autofill` webhook and automatically triggers
/// password auto-fill the instant `http://<ip>:8765/api/v1/faceid-autofill` or
/// `http://<ip>:8765/faceid` is opened in the browser.
@MainActor
public final class FaceIdKeychainBridgeService: ObservableObject {
    public static let shared = FaceIdKeychainBridgeService()

    @AppStorage("aurasense.faceid.bridgeEnabled") public var isBridgeEnabled: Bool = true
    @AppStorage("aurasense.faceid.requireDeviceInRangeForPost") public var requireDeviceInRangeForPost: Bool = false
    @AppStorage("aurasense.faceid.onlyWhenExternalMonitor") public var onlyWhenExternalMonitorConnected: Bool = false
    @AppStorage("aurasense.faceid.allowContinuityWake") public var allowContinuityBleFaceIdWake: Bool = true
    @Published public var relayPort: UInt16 = 8765

    @Published public private(set) var onlineDisplayCount: Int = 1
    @Published public private(set) var hasExternalMonitor: Bool = false
    @Published public private(set) var isClamshellClosed: Bool = false
    @Published public private(set) var activePromptProcess: String? = nil
    @Published public private(set) var isSecureTextFieldFocused: Bool = false
    @Published public private(set) var localLanIPAddress: String = "192.168.1.8"
    @Published public private(set) var lastBridgeEvent: String = "Ready — Auto-fills immediately when opened in browser or via POST"
    @Published public private(set) var continuityFaceIdUnlocked: Bool = false

    private var monitorTimer: Timer?
    private var listener: NWListener?
    private var lastAutoFillTime: Date = .distantPast

    private init() {
        resolveLocalIPAddress()
        refreshDisplayAndPromptState()
        startHttpPasskeyRelayServer()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplayAndPromptState()
            }
        }
    }

    public var passkeyRelayURL: String {
        "http://\(localLanIPAddress):\(relayPort)/faceid"
    }

    public var shortcutWebhookURL: String {
        "http://\(localLanIPAddress):\(relayPort)/api/v1/faceid-autofill"
    }

    public func refreshDisplayAndPromptState() {
        var displayCount: UInt32 = 0
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &activeIDs, &displayCount) == .success {
            onlineDisplayCount = Int(displayCount)
            let ids = Array(activeIDs.prefix(Int(displayCount)))
            let hasBuiltin = ids.contains { CGDisplayIsBuiltin($0) != 0 }
            hasExternalMonitor = displayCount > 1 || (displayCount == 1 && !hasBuiltin)
            isClamshellClosed = hasExternalMonitor && !hasBuiltin
        }

        guard MacLockUnlockController.shared.isAccessibilityTrusted else {
            activePromptProcess = nil
            isSecureTextFieldFocused = false
            return
        }

        let sysWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let elem = focusedRef else {
            activePromptProcess = nil
            isSecureTextFieldFocused = false
            return
        }

        let axElem = elem as! AXUIElement
        let role = copyStringAttr(axElem, kAXRoleAttribute) ?? ""
        let subrole = copyStringAttr(axElem, kAXSubroleAttribute) ?? ""
        let desc = copyStringAttr(axElem, kAXDescriptionAttribute) ?? ""

        let isSecure = (subrole == "AXSecureTextField") ||
            (role == "AXTextField" && desc.lowercased().contains("password"))

        isSecureTextFieldFocused = isSecure
        if isSecure {
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "CoreAuthUI / Keychain"
            activePromptProcess = frontApp
        } else {
            activePromptProcess = nil
        }
    }

    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &val) == .success,
           let str = val as? String {
            return str
        }
        return nil
    }

    public func handleContinuityManufacturerData(_ mfgData: Data, rssi: Int) {
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
                let wasUnlocked = continuityFaceIdUnlocked
                let nowUnlocked = ((flags & 0x08) != 0) || (activity >= 0x07)
                continuityFaceIdUnlocked = nowUnlocked

                if isBridgeEnabled && allowContinuityBleFaceIdWake && !wasUnlocked && nowUnlocked {
                    if isSecureTextFieldFocused && rssi >= Int(BLEProximityEngine.shared.unlockThresholdRSSI) {
                        Task { @MainActor in
                            _ = await self.autoFillActiveKeychainPrompt(triggerSource: "iPhone Continuity BLE Wake")
                        }
                    }
                }
                break
            }
            idx = pEnd
        }
    }

    public var isUserDeviceCurrentlyInRange: Bool {
        let engine = BLEProximityEngine.shared
        if engine.selectedDeviceID.isEmpty {
            return true
        }
        if let dev = engine.trackedDevice {
            return dev.smoothedRSSI >= engine.lockThresholdRSSI
        }
        return true
    }

    @discardableResult
    public func autoFillActiveKeychainPrompt(triggerSource: String) async -> (Bool, String) {
        guard isBridgeEnabled else {
            return (false, "Auto-Fill Bridge is paused.")
        }

        guard Date().timeIntervalSince(lastAutoFillTime) > 1.5 else {
            return (true, "Password auto-filled into active Mac prompt.")
        }

        if requireDeviceInRangeForPost && !isUserDeviceCurrentlyInRange {
            let msg = "Blocked: Bound device is outside lock threshold."
            lastBridgeEvent = msg
            return (false, msg)
        }

        guard MacLockUnlockController.shared.refreshAccessibilityStatus(prompt: false) else {
            let msg = "Blocked: Grant Accessibility permission to AuraSense in System Settings."
            lastBridgeEvent = msg
            return (false, msg)
        }

        guard let password = KeychainManager.shared.retrievePassword(), !password.isEmpty else {
            let msg = "Blocked: Save your macOS password in AuraSense Security & Keychain settings first."
            lastBridgeEvent = msg
            return (false, msg)
        }

        lastAutoFillTime = Date()
        let targetName = activePromptProcess ?? "Active macOS Password Prompt"

        MacLockUnlockController.shared.wakeDisplayAndSendMonitorInput()

        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in password.utf16 {
            var ch = scalar
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 14_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        if let retDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
           let retUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            retDown.post(tap: .cghidEventTap)
            retUp.post(tap: .cghidEventTap)
        }

        if BLEProximityEngine.shared.playSoundEffects {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        let okMsg = "Auto-filled Mac password into \(targetName) via \(triggerSource)"
        lastBridgeEvent = okMsg
        BLEProximityEngine.shared.appendLog(
            kind: .unlocked,
            title: "Password Filled (\(triggerSource))",
            detail: okMsg,
            rssi: BLEProximityEngine.shared.trackedDevice?.rawRSSI
        )
        return (true, okMsg)
    }

    private func startHttpPasskeyRelayServer() {
        do {
            let params = NWParameters.tcp
            guard let port = NWEndpoint.Port(rawValue: relayPort) else { return }
            let nwListener = try NWListener(using: params, on: port)
            nwListener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in
                    self?.receiveHttpConnection(conn)
                }
            }
            nwListener.start(queue: .main)
            self.listener = nwListener
        } catch {
            lastBridgeEvent = "Relay port \(relayPort) active"
        }
    }

    private func receiveHttpConnection(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            Task { @MainActor in
                if firstLine.hasPrefix("POST /api/v1/faceid-autofill") || firstLine.hasPrefix("POST /api/v1/passkey-assert") || firstLine.hasPrefix("POST /faceid") {
                    let (ok, message) = await self.autoFillActiveKeychainPrompt(triggerSource: "POST /api/v1/faceid-autofill")
                    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
                    let json = "{\"ok\":\(ok ? "true" : "false"),\"method\":\"POST /api/v1/faceid-autofill\",\"message\":\"\(escaped)\"}"
                    let resp = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                } else if firstLine.hasPrefix("GET /favicon") {
                    let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    Task { @MainActor in
                        _ = await self.autoFillActiveKeychainPrompt(triggerSource: "Browser Open (/api/v1/faceid-autofill)")
                    }
                    let html = self.renderInstructionsAndTriggerHTML()
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store, no-cache, must-revalidate\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
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

    // MARK: - Neon Orbit Eclipse Webpage Served at /faceid and /api/v1/faceid-autofill

    public func renderInstructionsAndTriggerHTML() -> String {
        let ip = localLanIPAddress
        let port = relayPort
        let postEndpoint = "http://\(ip):\(port)/api/v1/faceid-autofill"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
        <title>AuraSense v1.0</title>
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
              <p class="sub">Mac password auto-fills as soon as this page opens.</p>
              <button class="btn-post" onclick="sendPostAutoFill()">Fill Mac Password Again</button>
              <div id="status">Auto-filling Mac password...</div>
            </div>

            <div class="card">
              <h2>Quick Setup</h2>
              <div class="code-box">\(postEndpoint)</div>
              <ol>
                <li><strong>Home Screen Web Icon</strong>: Tap <strong>Share &gt; Add to Home Screen</strong> in Safari. Opening it fills your Mac password automatically.</li>
                <li><strong>iOS Shortcut (POST)</strong>: In <strong>Shortcuts</strong>, add <strong>Get Contents of URL</strong> with the URL above and set Method to <strong>POST</strong>.</li>
              </ol>
            </div>
          </div>

          <script>
          async function sendPostAutoFill() {
            const st = document.getElementById('status');
            st.textContent = 'Filling Mac password...';
            try {
              const res = await fetch('/api/v1/faceid-autofill', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ trigger: 'auto_open_post', ts: Date.now() })
              });
              const data = await res.json();
              st.style.color = data.ok ? '#38f2ee' : '#ff6b81';
              st.textContent = data.ok ? 'Mac password filled.' : (data.message || data.error);
            } catch (e) {
              st.style.color = '#ff6b81';
              st.textContent = 'Connection error: ' + e.message;
            }
          }
          window.addEventListener('DOMContentLoaded', () => { sendPostAutoFill(); });
          window.addEventListener('pageshow', (e) => { if (e.persisted) sendPostAutoFill(); });
          document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') sendPostAutoFill();
          });
          </script>
        </body>
        </html>
        """
    }
}
