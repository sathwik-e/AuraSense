# AuraSense Implementation Fix Plan

This status compares findings 1–20 in VULNERABILITIES.md with the current source and tests. Live locking uses an experimental private macOS API; repository tests do not replace physical-device validation.

## Safety constraints

- Preserve UUID-only admission to the proximity path; names, RSSI, and public advertisement data are not identity proof.
- Radio, permission, sleep, reset, ambiguity, and candidate-loss conditions fail closed to UNKNOWN, cancel countdowns, and invalidate pending actions.
- Keep dry-run as the default. Never add credential collection, credential persistence, or simulated keyboard credential entry.
- Do not hold NSLock across await. Do not claim a post-action check can undo an OS side effect.
- Avoid unrelated rewrites. Preserve the current macOS 26+ target and native Swift/CoreBluetooth architecture.

## Finding status from current source

| Finding | Current assessment | Required follow-up |
|---|---|---|
| 1 delayed action after state change | Implemented: generation validation, pre-effect checks, serialized actions, and lifecycle invalidation. | Unit tests pass; physical OS actions remain unverified. |
| 2 candidate removal leaves stale state | Implemented: unregister resets state, filter, policy, and pending dispatch. | NEAR/COUNTDOWN removal tests pass. |
| 3 stale peers block identity | Implemented: ambiguity checks use active peers and periodic cleanup removes stale records. | Ambiguity recovery and registry purge tests pass. |
| 4 invalid/single RSSI affects timing | Implemented: invalid and out-of-order samples are rejected; departure requires dwell and absence policy. | RSSI and absence tests pass. |
| 5 rejected and unsupported actions counted as successful | Implemented: outcome-specific counters and retryable reservation settlement. | Retry and concurrent transition tests pass. |
| 6 duplicate BLE discoveries cause unnecessary work | Implemented for non-candidates; candidate samples preserve RSSI cadence. | Burst test passes; hardware energy is unmeasured. |
| 7 scanner state and recovery ownership | Implemented: authorization checked, denied intent cleared, not-determined scan can initiate consent. | Mock tests pass; real permission flow needs hardware verification. |
| 8 trust-store filesystem and corruption errors | Implemented: load/write/directory errors are recorded and load errors enter diagnostics. | Corrupt-store and write-failure tests pass. |
| 9 credential-vault status can claim import success | Password secrets now use Keychain user-presence access control; only metadata is written to JSON. Password payload mapping is implemented, but source-app handoff/extension packaging and passkeys remain incomplete. | In-memory storage and import-mapping tests pass; real Keychain and system exchange still need macOS app/hardware validation. |
| 10 callbacks execute while proximity lock is held | Implemented: callbacks run outside the proximity lock. | Reentrant callback test passes. |
| 11 background tick timer wakes continuously when idle | Implemented: proximity timer is created only while scanner health and candidate availability allow evaluation; sleep stops it and recovery resumes it. | Readiness-driven scheduling is covered by lifecycle wiring; verify energy use on hardware. |
| 12 executor not serialized | Implemented: actor permit serializes effects and keeps only the newest waiter. | Serialization and bounded-queue tests pass. |
| 13 near transition invalidates its own token | Implemented: transition callback advances generation once, then dispatches using that generation. | Lifecycle and action invalidation tests pass. |
| 14 no validation at OS side effect | Implemented: concrete adapter validates before live effects; completed effects retain executed status. | Pre-effect and post-effect status tests pass. |
| 15 policy latch races | Implemented: lock/wake latches reserve synchronously before awaiting the provider. | Concurrent departure and retry tests pass. |
| 16 duplicate discoveries uncoalesced | Implemented for non-candidates; selected candidate observations retain full cadence. | Burst/coalescing test passes; radio energy is not measured. |
| 17 unauthorized scan leaves requested | Implemented: denied starts clear intent; not-determined authorization may trigger CoreBluetooth consent. | Mock denial test passes; physical permission flow unverified. |
| 18 peripheral registry grows | Implemented: scheduled purge prunes stale peers and tracking maps even without a candidate. | Registry purge test passes. |
| 19 lifecycle races timer | Implemented: sleep, radio failure, candidate loss, and scan errors invalidate pending work. | Lifecycle tests pass; hardware/system timing remains unverified. |
| 20 unstructured task accumulation | Implemented: one dispatch task is tracked and only the newest pending action is retained. | Rapid-flapping and bounded-queue tests pass. |

## Critical action pipeline

The action pipeline now advances generation once per state transition, validates pending work against the live proximity state, serializes execution through an actor permit, and retains only the newest queued transition. Policy latches reserve lock/wake actions before awaiting providers. The macOS adapter validates before side effects. An effect already issued cannot be undone, so its completed result remains `executed` if state changes afterward.

Regression coverage includes concurrent serialization, bounded pending work, stale-action rejection, concurrent lock admission, and lifecycle invalidation. Live session locking remains unsupported and is never treated as a successful effect.

## Lifecycle, signal, and resource fixes

- Candidate removal: retain centralized registerCandidate/unregisterCandidate; verify trust store, classifier, engine, filter, countdown, policy latch, and executor all update together.
- Ambiguity and registry: classify only active peers; recompute ambiguity/health when peers appear and expire; schedule purgeStalePeripherals so long-running registry memory and diagnostics remain bounded.
- RSSI/absence: invalid RSSI must not update liveness or dwell. Keep signal-far dwell separate from silence timeout; one far packet then silence must not cause an early countdown. Use deterministic clock-driven tests.
- Duplicate callbacks: preserve enough selected-peer RSSI cadence for proximity; coalesce unrelated peripherals before registry/classifier/log work. Bound per-peer history and event logs.
- Scanner lifecycle: explicitly stop on non-powered-on; keep one owner for scan intent; require authorization before setting requested state. On resume, require one scan and fresh candidate samples.
- Idle power: stop or suspend tick timer while asleep, Bluetooth unavailable, or no candidate, rather than returning from each 0.5-second callback. Resume once on a valid lifecycle/radio/candidate event.
- Callback discipline: invoke proximity callbacks after releasing locks and preserve ordered event delivery.

Required tests: candidate removal in NEAR/COUNTDOWN; same-name ambiguity resolving after expiry; registry size after transient peripherals; invalid RSSI and one-far-then-silence; duplicate bursts; unauthorized start followed by radio recovery; power-off/reset/sleep/wake yields exactly one scan and no stale action; no idle ticks while work is impossible; reentrant callback completes without deadlock.

## Persistence and vault status

- Candidate trust-store read/decode/directory errors are distinguishable from an empty store; initialization errors fail closed and are recorded in diagnostics.
- LocalCredentialVault may report imported only after a real system-mediated import completes. Cancellation/failure remains pending or returns to uninitialized.
- `LocalCredentialVault` stores password secrets in Keychain with device-only, user-presence protection and keeps only metadata in JSON. The Apple exchange payload mapper handles basic password items; passkeys are skipped. The credential-provider extension/activity handoff is missing from the current app bundle, so end-to-end import is not wired.
- Password import mapping and secret/metadata separation have regression tests using an in-memory secret-store fake. Actual Keychain prompt behavior and app-to-app credential exchange require macOS UI/hardware testing.

## Additional security blocker: lock implementation

Screen locking now dynamically resolves `SACLockScreenImmediate` from private `login.framework` and verifies the session state afterward. On the current M4/macOS 27.0.1 host the symbol resolved, returned success, and the session detector observed the locked state. The API is undocumented and unsupported by Apple; this does not establish future compatibility. Automated tests inject a fake to avoid locking the test host. No proximity-driven physical-iPhone end-to-end test has been performed.

## UI polish and existing icon

The working tree already has a compact, icon-first menu and a drawn radio-wave template. Review/refine that work rather than rebuilding it. The root asset is Icon.png (case-sensitive in source control), 1254×1254 RGBA, with dark rounded-square blue/cyan artwork.

- Use Icon.png as source for app/DMG identity. Keep full-color artwork for app identity; do not use the opaque PNG as a tiny template glyph.
- Derive the menu-bar glyph from the icon's radio-wave motif as a transparent monochrome/template asset. Ensure native contrast in light/dark appearances. Use labels/tooltips/VoiceOver so status is not conveyed by color alone.
- Keep the status item compact. Put NEAR/FAR/UNKNOWN, selected candidate's unverified status, health reason, toggles, and diagnostics in the native menu/popover. Make the five-second countdown and “I'm here” cancellation obvious.
- Surface persistence, Bluetooth, permission, and action errors; do not swallow UI setting failures with try?.
- Keep UI native AppKit/SwiftUI, with no webview or third-party UI runtime. Preserve accessible labels and keyboard navigation.

UI tests: state/accessibility labels; countdown/cancel visibility; no misleading verified wording; preference persistence and failure display; layout in light and dark appearances.

## Build and release alignment

Package.swift and the generated app bundle target macOS 26. The package builds without third-party runtime dependencies. No signing, notarization, entitlements file, or Xcode project is present; `scripts/build_dmg.sh` currently uses ad-hoc signing and is not a release-ready notarized distribution.

## Remaining work

- Validate CoreBluetooth permission flow, RSSI thresholds, clamshell operation, and display-wake behavior on the target Mac and iPhone.
- Keep unlock and password injection disabled; no supported public general-purpose proximity-unlock API is available.
- Treat private screen lock as experimental and revalidate after OS updates; symbol availability is not a stable platform contract.
- Add signing and notarization only when release distribution is in scope.

## Follow-up review: proximity and lifecycle findings

- Countdown entry is now guarded by `NEAR`, an enrolled candidate, and healthy scanning. Existing `ActionExecutor` generation validation rejects queued actions made stale by later state or lifecycle transitions.
- Candidate removal already forced `UNKNOWN`, cancelled countdowns, reset the signal filter and cleared dwell/sample timestamps; follow-up regression coverage remains in `CandidateLifecycleTests`.
- RSSI accepts weak values to preserve long-range departure sensing; an arbitrary `-80 dBm` floor would suppress legitimate far observations. Invalid sentinel/out-of-range values are rejected, and the median/EWMA plus multi-sample dwell prevents a lone weak sample from causing a lock. Departure dwell now resets on dead-band observations so its evidence must be continuous.
- CoreBluetooth authorization loss now clears scan intent and stops any active scan in the radio-state callback. The denied-start path already cleared intent. Mock tests verify no automatic restart after authorization loss; native permission revocation still needs hardware/UI validation.
- Credential exchange returns a completed `ASExportedCredentialData` payload before `importPasswords` runs. That synchronous method reports imported count only after all secrets are written and metadata is atomically persisted; failures roll back metadata and remove newly written secrets. It is not an asynchronous exchange launcher.
- Proximity callbacks are already accumulated under lock and invoked only after unlocking; regression tests re-enter engine getters from all callback types.
- `tick` already gates work on healthy scanning and candidate presence. It now also clears timers/filter/evidence and transitions to `UNKNOWN` if called after availability has gone stale.
