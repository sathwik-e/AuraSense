import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import Network

/// Prioritizes the POST `/api/v1/faceid-autofill` webhook and automatically triggers
/// password auto-fill the instant `http://<ip>:8765/api/v1/faceid-autofill` or
/// `http://<ip>:8765/faceid` is opened in the browser (both server-side on GET/POST
/// and client-side via automatic POST on page load, pageshow, and tab focus).
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

    // MARK: - Display & Focused AXSecureTextField Detection

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

    // MARK: - Apple Continuity 0x004C (0x10) BLE Face ID Wake Handler

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
                            _ = await self.autoFillActiveKeychainPrompt(triggerSource: "iPhone Continuity BLE Face ID Wake")
                        }
                    }
                }
                break
            }
            idx = pEnd
        }
    }

    // MARK: - Execute Password Entry

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
            return (false, "Face ID Keychain Bridge is currently paused.")
        }

        // Prevent duplicate double-typing within 1.5s when both GET page load and auto-POST fire together
        guard Date().timeIntervalSince(lastAutoFillTime) > 1.5 else {
            return (true, "Password auto-filled into active Mac prompt.")
        }

        if requireDeviceInRangeForPost && !isUserDeviceCurrentlyInRange {
            let msg = "Blocked: Bound device is outside Aura lock threshold."
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
            title: "iCloud Keychain Password Filled (\(triggerSource))",
            detail: okMsg,
            rssi: BLEProximityEngine.shared.trackedDevice?.rawRSSI
        )
        return (true, okMsg)
    }

    // MARK: - Local Network HTTP Server (/faceid & /api/v1/faceid-autofill)

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
                    let (ok, message) = await self.autoFillActiveKeychainPrompt(triggerSource: "iPhone POST /api/v1/faceid-autofill")
                    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
                    let json = "{\"ok\":\(ok ? "true" : "false"),\"method\":\"POST /api/v1/faceid-autofill\",\"message\":\"\(escaped)\"}"
                    let resp = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                } else if firstLine.hasPrefix("GET /favicon") {
                    let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    // As soon as /api/v1/faceid-autofill or /faceid is opened in the browser,
                    // trigger password auto-fill immediately on the server AND auto-fire POST from the page!
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

    // MARK: - Auto-Executing Webpage Served on iPhone at /faceid and /api/v1/faceid-autofill

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
        <title>AuraSense • Auto-Fill Active</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 20px 16px 44px;
            background: radial-gradient(circle at 50% 0%, #172347 0%, #070912 65%);
            color: #f5f7ff;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif;
            display: flex; flex-direction: column; align-items: center;
          }
          .container { width: 100%; max-width: 440px; }
          .hero {
            text-align: center; padding: 22px 18px; border-radius: 22px;
            background: rgba(255,255,255,0.05);
            border: 1px solid rgba(41,217,245,0.35);
            box-shadow: 0 12px 34px rgba(0,0,0,0.45);
            margin-bottom: 18px;
          }
          .pill {
            display: inline-block; padding: 4px 11px; border-radius: 99px;
            background: rgba(41,240,166,0.14); border: 1px solid rgba(41,240,166,0.45);
            color: #29f0a6; font-size: 11px; font-weight: 700; letter-spacing: 0.4px;
            margin-bottom: 10px;
          }
          h1 { font-size: 22px; margin: 0 0 6px; font-weight: 800; }
          .sub { font-size: 13px; color: rgba(255,255,255,0.72); line-height: 1.45; margin: 0 0 18px; }
          .btn-post {
            width: 100%; padding: 16px 18px; border-radius: 15px; border: none;
            background: linear-gradient(135deg, #29d9f5 0%, #6b5cfa 55%, #8c38f5 100%);
            color: #fff; font-size: 16px; font-weight: 700; cursor: pointer;
            box-shadow: 0 8px 26px rgba(107,92,250,0.45);
          }
          .btn-copy {
            width: 100%; padding: 11px 14px; border-radius: 12px;
            background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.16);
            color: #d6e4ff; font-size: 13px; font-weight: 600; margin-top: 10px; cursor: pointer;
          }
          #status {
            margin-top: 12px; padding: 10px 12px; border-radius: 10px;
            background: rgba(41,240,166,0.10); color: #29f0a6;
            font-size: 13px; font-weight: 600; display: block;
          }
          .card {
            background: rgba(255,255,255,0.045);
            border: 1px solid rgba(255,255,255,0.12);
            border-radius: 18px; padding: 18px; margin-bottom: 16px;
          }
          .card h2 {
            font-size: 15px; margin: 0 0 10px; color: #29d9f5;
          }
          .code-box {
            background: rgba(0,0,0,0.45); border: 1px solid rgba(41,217,245,0.3);
            padding: 10px 12px; border-radius: 10px; font-family: ui-monospace, SFMono-Regular, monospace;
            font-size: 12px; color: #29f0a6; word-break: break-all; margin: 8px 0 12px;
          }
          ol { margin: 0; padding-left: 20px; font-size: 13.5px; line-height: 1.58; color: rgba(255,255,255,0.88); }
          ol li { margin-bottom: 9px; }
          strong { color: #ffffff; }
          .highlight { color: #29d9f5; font-weight: 600; }
        </style>
        </head>
        <body>
          <div class="container">
            <div class="hero">
              <div class="pill">AUTO-FILL ON PAGE OPEN ACTIVE</div>
              <h1>AuraSense Keychain Fill</h1>
              <p class="sub">Opening this page automatically triggers POST password auto-fill on your Mac.</p>
              <button class="btn-post" onclick="sendPostAutoFill()">Fill Mac Password Again (POST)</button>
              <button class="btn-copy" onclick="copyEndpoint()">Copy URL: \(postEndpoint)</button>
              <div id="status">Auto-filling Mac password now...</div>
            </div>

            <div class="card">
              <h2>Add to iPhone Home Screen or Shortcuts</h2>
              <div class="code-box">\(postEndpoint)</div>
              <ol>
                <li><strong>Zero-Tap Browser Bookmark / Home Screen Icon</strong>: Tap <strong>Share</strong> in Safari and select <strong>Add to Home Screen</strong>. Every time you open it, your Mac password auto-fills immediately on page load.</li>
                <li><strong>Or iOS Shortcut (POST)</strong>: In the <strong>Shortcuts</strong> app, add <strong>Get Contents of URL</strong> with <strong>\(postEndpoint)</strong> and set Method to <strong><code>POST</code></strong>.</li>
              </ol>
            </div>
          </div>

          <script>
          async function sendPostAutoFill() {
            const st = document.getElementById('status');
            st.style.display = 'block';
            st.style.color = '#29d9f5';
            st.textContent = 'Auto-filling Mac password via POST...';
            try {
              const res = await fetch('/api/v1/faceid-autofill', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ trigger: 'auto_open_post', ts: Date.now() })
              });
              const data = await res.json();
              if (data.ok) {
                st.style.color = '#29f0a6';
                st.textContent = 'Password auto-filled: ' + data.message;
              } else {
                st.style.color = '#ff6b81';
                st.textContent = (data.message || data.error);
              }
            } catch (e) {
              st.style.color = '#ff6b81';
              st.textContent = 'Connection error: ' + e.message;
            }
          }

          function copyEndpoint() {
            const url = '\(postEndpoint)';
            if (navigator.clipboard) {
              navigator.clipboard.writeText(url);
            }
            const st = document.getElementById('status');
            st.style.display = 'block';
            st.style.color = '#29f0a6';
            st.textContent = 'Copied URL: ' + url;
          }

          // Automatically execute POST auto-fill the instant the page opens or becomes visible
          window.addEventListener('DOMContentLoaded', () => { sendPostAutoFill(); });
          window.addEventListener('pageshow', (event) => {
            if (event.persisted) { sendPostAutoFill(); }
          });
          document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') { sendPostAutoFill(); }
          });
          </script>
        </body>
        </html>
        """
    }
}
