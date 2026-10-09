# AuraSense Implementation Fix Plan

This plan re-evaluates the current VULNERABILITIES.md (findings 1–20) against the working tree. Some original mitigations are now present, but should be considered unverified until their regression tests pass. Focus first on unresolved action-execution races. Keep live locking disabled until the release gates pass.

## Safety constraints

- Preserve UUID-only admission to the proximity path; names, RSSI, and public advertisement data are not identity proof.
- Radio, permission, sleep, reset, ambiguity, and candidate-loss conditions fail closed to UNKNOWN, cancel countdowns, and invalidate pending actions.
- Keep dry-run as the default. Never add credential collection, credential persistence, or simulated keyboard credential entry.
- Do not hold NSLock across await. Do not claim a post-action check can undo an OS side effect.
- Avoid unrelated rewrites. Preserve the current macOS 26+ target and native Swift/CoreBluetooth architecture.

## Finding status from current source

| Finding | Current assessment | Required follow-up |
|---|---|---|
| 1 delayed action after state change | Partially mitigated: generation validation and ActionExecutor exist; serialization and side-effect boundary are still flawed (see 12–15). | Complete action executor/policy fixes and test in-flight races. |
| 2 candidate removal leaves stale state | Appears addressed by DiagnosticsManager.unregisterCandidate; CLI path now calls it. | Keep regression test covering NEAR and COUNTDOWN removal. |
| 3 stale peers block identity | Active-only classification and health recomputation appear added. | Stale records still need scheduled purge (18); test ambiguity recovery. |
| 4 invalid/single RSSI affects timing | RSSI validity and far-observation tracking appear added. | Verify invalid, one-sample, silence, and timeout boundaries with tests. |
| 5 rejected actions counted as success | Outcome-specific telemetry appears added. | In-flight reservation is still missing (15); verify retry and counters. |
| 6 duplicate BLE processing | Blocked-device logging is rate-limited, but duplicates remain enabled and selected-peer samples still fan through the pipeline. | Coalesce noncandidate work while preserving required RSSI cadence (16). |
| 7 scan/recovery ownership | Explicit stopScan() and monitoring intent appear added. | Unauthorized start can leave intent set (17); keep one scan owner and test recovery. |
| 8 candidate-store errors | Force unwrap and silent decode behavior appear replaced with explicit load errors. | Verify initialization errors reach UI/diagnostics and fail closed. |
| 9 vault reports false import | Pending-import and throwing save/reset paths appear added. | loadMetadata() still silently ignores read/decode errors; report/recover explicitly. Vault stores metadata only; do not claim secret import/encryption is implemented. |
| 10 callbacks under proximity lock | Callbacks appear captured and invoked after unlock. | Verify callback ordering/reentrancy tests pass. |
| 11 idle tick work | Tick callback now skips engine work when unavailable. | The repeating 0.5-second timer still wakes continuously; pause it or replace with event/timer scheduling. |
| 12 executor not serialized | OPEN, Critical. executionLock is declared but not used. | Implement true async serialization/reservation; never lock across await. |
| 13 near transition invalidates its own token | OPEN, Critical. Transition code advances generation then separately invalidates on NEAR/UNKNOWN. | Invalidate old actions once, then issue the current transition token; NEAR wake must remain valid. |
| 14 no validation at OS side effect | OPEN, High. Protocol default checks before calling legacy method; MacOSActionAdapter does not override it. | Validate inside the concrete adapter immediately before irreversible calls; no post-check-as-cancellation. |
| 15 policy latch races | OPEN, High. Lock/wake latch is recorded after async result, allowing concurrent admission. | Reserve in-flight action before suspension; settle reservation on result; use one admission owner. |
| 16 duplicate discoveries uncoalesced | OPEN, High. Duplicates enabled and candidate observations still process each callback. | Per-peer coalescing/rate limits and bounded diagnostics; preserve candidate RSSI timing. |
| 17 unauthorized scan leaves requested | OPEN, Medium. startScanning sets monitoring intent before authorization and may throw. | Validate authorization/state first; clear request on every failure. Do not auto-start after denied attempt. |
| 18 peripheral registry grows | OPEN, Medium. purgeStalePeripherals exists but no scheduled caller was found. | Invoke from one bounded maintenance path; retain only data needed for candidate/UI diagnostics. |
| 19 lifecycle races timer | OPEN, Medium. Timer and lifecycle callbacks can overlap; invalidate/cancel before ticking or dispatching actions. | Order lifecycle invalidation first, force UNKNOWN/cancel countdown, require fresh evidence after recovery. |
| 20 unstructured task accumulation | OPEN, Low. Each transition still creates a Task. | Keep a bounded actor-owned task/queue; cancel or supersede obsolete pending work. |

## Critical action pipeline

1. Replace the unused executionLock approach with a real async actor/queue or equivalent permit that reserves an action before suspension and guarantees at most one lock/wake admission at a time.
2. For each transition, invalidate prior generation once, then create the token for that transition. Do not invalidate the token being used for a valid NEAR wake.
3. Make policy admission atomic: reserve lock/wake state before awaiting the provider. Commit only on executed; clear or retain reservation according to explicit rejected/unsupported/error retry policy.
4. Revalidate generation, current state, candidate availability, radio/authorization health, and user policy immediately before the concrete adapter performs an irreversible OS call. The concrete adapter must implement the validating overload; a protocol extension that checks then awaits a legacy method is insufficient.
5. Keep pending work bounded/cancellable. State change, candidate removal, radio failure, sleep, or ambiguity invalidates queued work. Document that an OS side effect already issued cannot be undone.

Required tests: two simultaneous FAR requests call the provider once; valid NEAR causes one wake; the NEAR token is not self-invalidated; generation/state change while queued prevents dispatch; invalidation at the concrete adapter's pre-side-effect gate prevents the side effect; rapid state flapping does not grow pending tasks.

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

- Candidate trust-store read/decode/directory errors must remain distinguishable from a genuinely empty store; fail closed and surface a recoverable diagnostic.
- LocalCredentialVault may report imported only after a real system-mediated import completes. Cancellation/failure remains pending or returns to uninitialized.
- Surface loadMetadata() corruption and read failures. Keep all secret material out of JSON metadata, logs, diagnostics, and candidate persistence. Do not claim the current metadata-only vault securely imports/stores passwords or passkeys.
- Test inaccessible paths, corrupt files, write/reset failures, import cancellation, and false-success prevention.

## Additional security blocker: lock implementation

Current MacOSActionAdapter dynamically loads private SACLockScreenImmediate and has a display-sleep fallback. Private framework symbols are unsupported and can break or fail distribution review; display sleep is not equivalent to locking the session. Before live lock mode, replace this with a validated public/documented macOS mechanism. If none is suitable for the distribution model, report lock as unsupported and keep live lock disabled. Distinguish session locked from display asleep; never count sleep as a successful lock.

## UI polish and existing icon

The working tree already has a compact, icon-first menu and a drawn radio-wave template. Review/refine that work rather than rebuilding it. The root asset is Icon.png (case-sensitive in source control), 1254×1254 RGBA, with dark rounded-square blue/cyan artwork.

- Use Icon.png as source for app/DMG identity. Keep full-color artwork for app identity; do not use the opaque PNG as a tiny template glyph.
- Derive the menu-bar glyph from the icon's radio-wave motif as a transparent monochrome/template asset. Ensure native contrast in light/dark appearances. Use labels/tooltips/VoiceOver so status is not conveyed by color alone.
- Keep the status item compact. Put NEAR/FAR/UNKNOWN, selected candidate's unverified status, health reason, toggles, and diagnostics in the native menu/popover. Make the five-second countdown and “I'm here” cancellation obvious.
- Surface persistence, Bluetooth, permission, and action errors; do not swallow UI setting failures with try?.
- Keep UI native AppKit/SwiftUI, with no webview or third-party UI runtime. Preserve accessible labels and keyboard navigation.

UI tests: state/accessibility labels; countdown/cancel visibility; no misleading verified wording; preference persistence and failure display; layout in light and dark appearances.

## Build and release alignment

Package.swift now declares macOS 26, resolving the earlier v14 mismatch. Verify scripts/build_app.sh, app bundle metadata, and final DMG use the same minimum, include app icon and template glyph, and require no runtime package-manager install. Keep Bluetooth/Accessibility permissions explicit and dry-run/live behavior clearly separated.

## Release gates

1. Add/update focused regression tests for every Critical and High finding; run focused and full existing suites and report exact results.
2. Keep live locking disabled until serialization, generation semantics, concrete pre-side-effect validation, lifecycle tests, and a public lock mechanism are reviewed.
3. Verify all 20 findings have a passing test or documented non-applicability; code presence alone is not completion.
4. Confirm no credential/password injection, private credential handling, or secret logging was introduced.
5. Report changed files, test results, platform-validation limits, and remaining risks.
