# AuraSense Phase 6: macOS Authentication & Proximity Unlock Research

**Date:** 2026-10-08  
**Author:** Lead Software Engineer, AuraSense  
**Status:** Approved Architecture Decision  

---

## Executive Summary

Phase 6 of AuraSense evaluates proximity-based authentication and unlock mechanisms on macOS. The goal is to determine a secure, supported unlock path while strictly adhering to the fundamental constraint: **Do not store or inject a plaintext password**.

This document evaluates macOS authentication paths and rejects third-party simulated password injection (the BLEUnlock model). AuraSense currently has no supported mechanism to unlock the macOS session; Apple Watch Auto Unlock is independent system functionality.

---

## 1. Evaluation of macOS Unlock Mechanisms

### Path 1: Native Apple Continuity Auto Unlock (Apple Watch)
* **Mechanism:** Coordinated between watchOS and macOS using iCloud identity, Bluetooth LE discovery, Continuity pairing keys stored in the Secure Enclave, and **802.11 Time-of-Flight (RTT) distance bounding** to prevent relay attacks.
* **Apple API Availability:** Private framework (`Sharing.framework`, `SFAutoUnlockManager`). Apple does not offer a public third-party API to add arbitrary BLE devices as Auto Unlock tokens.
* **Security Rating:** High. Cryptographically authenticated, hardware-backed, relay-resistant.
* **AuraSense Integration:** Not directly integrated. AuraSense cannot initiate or observe the private Auto Unlock flow; the user may continue using Apple's independently configured feature.

### Path 2: Display Wake & Touch ID / Biometric Prompt Readiness
* **Mechanism:** Upon verified proximity return to `NEAR`, AuraSense requests display wake and issues a safe non-credential wake event (`CGEvent` Space/Shift). This awakens the display and activates the Touch ID / Watch sensor loop.
* **Security Rating:** High. Zero credentials stored; zero synthetic keystrokes injected; preserves full login protections and FileVault guarantees.
* **AuraSense Integration:** Experimental display-wake request only. It cannot guarantee a Touch ID prompt or wake a sleeping Mac/external display, and cannot unlock the session.

### Path 3: LocalAuthentication Framework (`LAContext`)
* **Mechanism:** `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)` allows biometric evaluation and user verification.
* **Limitation:** `LAContext` is strictly an in-application verification API. It operates inside an active user session and **cannot unlock the macOS `loginwindow` or system lock screen** from a background daemon.
* **Security Rating:** High for app authentication; not applicable for OS screen unlock.

### Path 4: Pluggable Authentication Modules (PAM)
* **Mechanism:** Implementing a custom PAM module (e.g. `/usr/local/lib/pam/pam_aurasense.so`) and injecting it into `/etc/pam.d/screensaver` or `/etc/pam.d/authorization`.
* **Drawbacks:**
  1. Requires root privileges and modifying protected system configuration.
  2. Modifying `/etc/pam.d` on modern macOS triggers SIP integrity issues and can render the Mac un-bootable or permanently locked out if a crash occurs.
  3. Since Mac-only BLE advertisements lack cryptographic attestation, a PAM module accepting BLE presence alone would allow anyone with a spoofed peripheral to unlock the Mac.
* **Security Rating:** Rejected. Fragile and unsafe.

### Path 5: Cryptographic SmartCard / PIV Token (`CryptoTokenKit`)
* **Mechanism:** Emulating a Virtual SmartCard via `CryptoTokenKit` (PKINIT / PIV).
* **Limitation:** Requires X.509 certificate enrollment, pairing, and user PIN entry. Does not provide frictionless zero-interaction unlock and requires device-side cryptographic participation (which a Mac-only BLE scanner cannot support).
* **Security Rating:** Strong for enterprise cards; impractical for companion BLE presence.

### Path 6: Keychain Stored Password & Simulated Accessibility Keystrokes (BLEUnlock Model)
* **Mechanism:** The application prompts the user for their macOS login password, stores it in the macOS Keychain, and upon BLE RSSI crossing a threshold, uses Accessibility APIs (`CGEventCreateKeyboardEvent`) to type the password into the lock window followed by Enter.
* **Security Vulnerabilities & Why It Is Rejected:**
  1. **Direct Violation of Core Directive:** The requirement explicitly mandates: *"Do not store or inject a plaintext password."*
  2. **Lowering Security Assurance:** Replaying plaintext credentials via synthetic keystrokes turns an unauthenticated, easily spoofable RF broadcast (public BLE advertisements) into root-equivalent console access.
  3. **Blind Keystroke Hazards:** If focus changes, or if an alert/dialog is open, the password can be typed in plaintext into an active text field, chat app, or terminal window.
  4. **OS Brittleness:** Changes in macOS lock UI or loginwindow architecture easily break synthetic typing, leading to account lockouts.
* **Security Rating:** **Strictly Prohibited & Rejected**.

---

## 2. Decision Matrix

| Mechanism | Supported by Apple? | Stores / Injects Password? | Relay/Spoof Resistant? | Selected for AuraSense? |
|---|---|---|---|---|
| **Display Wake + Biometric Readiness** | Yes (Native IOKit) | **No (Zero credentials)** | Preserves OS security | **YES (Primary)** |
| **Apple Watch Auto Unlock Coordination** | Yes (Built-in) | **No** | Yes (RTT distance bound) | **YES (Native Path)** |
| **Simulated Password Typing (BLEUnlock)** | Fragile (Accessibility) | **Yes (Violates directive)** | No (Easily spoofable) | **NO (Strictly Rejected)** |
| **Custom PAM Module** | No (System modification) | Depends | No | **NO** |
| **LocalAuthentication (`LAContext`)** | Yes (In-app only) | No | Yes | **NO (Cannot unlock OS)** |

---

## 3. Architecture Specification for Phase 6

1. **Strict Credential Boundary:**
   - Any attempt to call `requestCredentialEntry()` or pass plaintext credentials throws `ActionError.actionDisabled("Plaintext password storage and injection are strictly prohibited per security architecture")`.
   - No Keychain item storing account passwords shall ever be created.

2. **Lock Screen State Detection (`LockScreenStateDetector`):**
   - Query `CGSessionCopyCurrentDictionary()` for:
     - `CGSSessionScreenIsLocked` (delineates locked vs unlocked).
     - `kCGSSessionOnConsoleKey` (confirms session is on console).
     - `kCGSessionLoginDoneKey` (confirms active session, distinguishing from pre-boot FileVault).

3. **Secure Arrival Orchestration:**
   - On transition to `.near`:
     - Inspect session state. If locked, trigger `wakeDisplay()` and safe non-credential wake key.
     - macOS natively presents Touch ID and Apple Watch Auto Unlock.
     - The user authenticates natively and securely.
