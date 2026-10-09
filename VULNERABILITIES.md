# AuraSense Vulnerabilities and Correctness Bugs

This document lists the currently identified security, reliability, concurrency,
Bluetooth, lifecycle, and performance defects. Fixes should be incremental and
should preserve the existing architecture. Do not enable live locking until the
critical and high-severity issues are resolved.

## Severity Definitions

- **Critical**: Can cause an incorrect security action, such as locking after the trusted device has returned.
- **High**: Can leave stale trust/proximity state active or cause incorrect lock decisions.
- **Medium**: Can cause incorrect recovery, excessive resource usage, silent failures, or misleading security state.
- **Low**: Maintainability or deadlock risk that should still be corrected before production use.

## 1. Delayed security actions can execute after the state is no longer valid

- **Severity:** Critical
- **Affected files:** `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:187-203`
- **Bug:** Every proximity transition starts an independent unstructured `Task`.
  A lock action decided for `COUNTDOWN -> FAR` may be delayed until after a
  later `FAR` or `COUNTDOWN -> NEAR` transition. The delayed task can then lock
  the Mac even though the trusted device has returned.
- **Why this is unsafe:** The action is no longer authorized by the current
  proximity state. Policy latches prevent duplicate actions but do not verify
  that an already-started action is still current.
- **Smallest safe fix:** Serialize policy actions through one actor or task
  queue. Associate each transition with a generation/token and re-check that
  token and the current proximity state immediately before executing a lock.
  Cancel obsolete pending lock work when entering `NEAR` or `UNKNOWN`.
- **Required test:** Use a blocking mock action provider. Trigger a lock
  transition, then transition back to `NEAR` before releasing the provider.
  Verify that no lock action is executed.

## 2. Removing the candidate does not invalidate proximity monitoring

- **Severity:** High
- **Affected files:** `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:185`,
  `Sources/AuraSense/main.swift:228-231`
- **Bug:** Candidate availability is set only during `DiagnosticsManager`
  initialization. The unregister path updates the trust store and gate but does
  not call `ProximityEngine.updateCandidateAvailability(false)`.
- **Why this is unsafe:** Previously admitted RSSI evidence, dwell timers, and
  countdown state can remain active after the trusted candidate has been
  removed. A later timer tick may still transition to `FAR` and request a lock.
- **Smallest safe fix:** Centralize candidate registration and removal. On
  unregister, immediately mark the proximity engine as having no candidate,
  cancel active countdowns, force `UNKNOWN`, and invalidate pending policy
  actions.
- **Required test:** Establish `NEAR`, unregister the candidate, advance time
  beyond stale and countdown thresholds, and verify the state remains
  `UNKNOWN` with no lock request.

## 3. Stale peripherals remain in identity ambiguity checks forever

- **Severity:** High
- **Affected files:** `Sources/AuraSenseCore/Diagnostics/PeripheralRegistry.swift:109-114`,
  `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:283-287`,
  `Sources/AuraSenseCore/BLE/AdvertisementClassifier.swift`
- **Bug:** `PeripheralRegistry.allPeripherals()` returns every device ever
  discovered. There is no expiration or removal based on `lastSeen`.
- **Why this is unsafe:** A device that disappeared long ago can continue to
  count as a same-name peer and keep the candidate classified as ambiguous.
  Ambiguity forces scanner health to false, but normal rediscovery does not
  explicitly restore health.
- **Smallest safe fix:** Add a registry purge/active filter based on a defined
  liveness timeout. Pass only recently seen peers to identity classification.
  Explicitly restore scanner health after ambiguity clears, provided Bluetooth
  is powered on and authorized.
- **Required tests:**
  1. Discover a candidate and same-name spoof, then let the spoof expire.
     Verify the candidate is no longer ambiguous.
  2. Verify monitoring recovers after an ambiguity condition is cleared.

## 4. One invalid or weak RSSI sample can affect liveness and departure timing

- **Severity:** High
- **Affected files:** `Sources/AuraSenseCore/Proximity/ProximityEngine.swift:80-82`,
  `Sources/AuraSenseCore/Proximity/ProximityEngine.swift:177-207`
- **Bug:** `lastAdmittedSampleTime` is updated before `RSSIFilter` validates the
  RSSI. An invalid value such as `-121` can appear to keep the candidate
  alive. Also, one far RSSI sample starts the far dwell; if packets then stop,
  the countdown may begin from the dwell timer before the configured stale
  timeout.
- **Why this is unsafe:** A single noisy or invalid observation can influence a
  security transition, contrary to the requirement that proximity must not be
  determined by one RSSI value.
- **Smallest safe fix:** Validate RSSI before updating liveness. Require
  multiple valid far observations, or use the configured absence timeout before
  starting departure. Keep signal filtering and absence handling separate.
- **Required tests:**
  1. Submit invalid RSSI and verify that stale detection still occurs.
  2. Submit one far sample followed by silence and verify no countdown begins
     before the intended absence threshold.

## 5. Rejected and unsupported actions are counted as successful

- **Severity:** High
- **Affected files:** `Sources/AuraSenseCore/Actions/PolicyEngine.swift:103-119`
- **Bug:** `recordLockSuccess()` and `recordWakeSuccess()` are called for every
  non-throwing `ActionResult`, including `.rejected` and `.unsupported`.
- **Why this is wrong:** Metrics report actions as executed when they did not
  execute. The policy latch may also suppress future retries after a throttled
  or unsupported action.
- **Smallest safe fix:** Increment executed counters only for
  `.executed`. Treat `.rejected` and `.unsupported` as failed attempts and
  define whether the corresponding latch should remain retryable.
- **Required test:** Return `.rejected` and `.unsupported` from a mock provider.
  Verify executed counters remain zero and a later valid transition can retry.

## 6. Duplicate BLE discoveries cause unnecessary processing and battery usage

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/BLE/CoreBluetoothScanner.swift:87-93`,
  `Sources/AuraSenseCore/BLE/CoreBluetoothScanner.swift:154-174`
- **Bug:** Scanning enables
  `CBCentralManagerScanOptionAllowDuplicatesKey`, and every advertisement is
  sent through registry updates, identity classification, diagnostics logging,
  and proximity processing.
- **Why this is wrong:** Continuous duplicate processing increases CPU use,
  memory churn, log volume, and main/security state-machine work. It is
  especially expensive when scanning all nearby devices rather than only the
  candidate's service UUIDs.
- **Smallest safe fix:** Disable duplicate advertisements unless continuous
  RSSI is required. If duplicates are required, coalesce or rate-limit samples
  per peripheral before classification and policy processing. Scan candidate
  service UUIDs where available.
- **Required test:** Simulate a high-rate duplicate burst and verify bounded
  history growth, bounded processing/logging, and no repeated security actions.

## 7. Scanner state and recovery ownership are inconsistent

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/BLE/CoreBluetoothScanner.swift:142-151`,
  `Sources/AuraSenseCore/Diagnostics/BluetoothRecoveryCoordinator.swift`
- **Bug:** When Bluetooth becomes unavailable, `_isScanning` is set to `false`
  without calling `central.stopScan()`. Restart behavior is split between
  `CoreBluetoothScanner` auto-start and `BluetoothRecoveryCoordinator`.
- **Why this is wrong:** Internal state can disagree with CoreBluetooth state,
  and sleep/wake or radio-reset sequences can produce duplicate or missing
  scan sessions.
- **Smallest safe fix:** Explicitly stop the CoreBluetooth scan whenever the
  state leaves `.poweredOn`. Keep one “monitoring requested” flag and restart
  only after `.poweredOn` and authorized state are both confirmed.
- **Required test:** Simulate `.poweredOn -> .poweredOff -> .resetting ->
  .poweredOn` and sleep/wake. Verify exactly one scan is active after recovery
  and proximity remains `UNKNOWN` until fresh evidence arrives.

## 8. Trust-store filesystem and corruption errors are silently ignored

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/Security/CandidateTrustStore.swift:69-79`,
  `Sources/AuraSenseCore/Security/CandidateTrustStore.swift:128-136`
- **Bug:** Application Support URL handling force-unwraps a filesystem result.
  Directory creation failures and malformed stored candidate data are silently
  converted into “no candidate.”
- **Why this is wrong:** The app can fail to persist or load trust state without
  notifying the user or diagnostics system. A corrupted file is not
  distinguishable from an intentionally empty trust store.
- **Smallest safe fix:** Replace the force unwrap with explicit error handling.
  Report directory, read, and decode failures. Keep corrupted data fail-closed,
  but expose the reason and provide a controlled recovery path.
- **Required test:** Inject an unavailable storage path and malformed JSON.
  Verify initialization/reporting is explicit and no device is admitted.

## 9. Credential-vault status can claim import success without importing anything

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/Security/CredentialVault.swift:103-124`,
  `Sources/AuraSenseCore/Security/CredentialVault.swift:149-174`
- **Bug:** Selecting `.importExistingCredentials` immediately sets the vault
  status to `.imported`, although the system-mediated import is only a
  placeholder. Metadata writes and reset failures are swallowed.
- **Why this is unsafe:** UI or diagnostics can report an active imported vault
  when no credentials were imported, and persistence failures are invisible.
- **Smallest safe fix:** Use a pending/importing state or leave the vault
  uninitialized until the system import succeeds. Make metadata persistence
  throwing and surface failures. Continue storing only non-secret metadata
  unless a real Keychain-backed secret implementation is added.
- **Required tests:** Simulate import cancellation and metadata write failure.
  Verify the status is not `.imported` and the error is observable.

## 10. State callbacks execute while the proximity lock is held

- **Severity:** Low
- **Affected files:** `Sources/AuraSenseCore/Proximity/ProximityEngine.swift:269-285`
- **Bug:** `onStateTransition`, `onEvaluation`, and countdown callbacks are
  invoked from code paths that hold the engine's `NSLock`.
- **Why this is dangerous:** A callback that synchronously queries or mutates
  the engine can deadlock. Callback work can also block BLE/state processing.
- **Smallest safe fix:** Capture transition and evaluation events while holding
  the lock, release the lock, then invoke callbacks. Avoid doing external work
  inside locked sections.
- **Required test:** Install a callback that synchronously reads the engine and
  verify it completes without deadlock.

## 11. Background tick timers run continuously when no work is possible

- **Severity:** Medium
- **Affected files:** `Sources/AuraSense/main.swift:363-365`,
  `Sources/AuraSense/main.swift:398-400`
- **Bug:** Menu-bar and agent modes run a 0.5-second timer continuously,
  including while Bluetooth is unavailable, the system is asleep, or no
  candidate is registered.
- **Why this is wrong:** It creates unnecessary wakeups and CPU usage and can
  compete with lifecycle recovery.
- **Smallest safe fix:** Pause or invalidate the tick timer while asleep,
  Bluetooth is unavailable, or no candidate exists. Resume only on a valid
  wake/radio/candidate event. Keep a single timer owner per mode.
- **Required test:** Simulate sleep, Bluetooth-off, and no-candidate states.
  Verify no proximity ticks are processed, then verify ticking resumes after
  recovery.

## Security invariants that must remain true

1. Only the registered peripheral UUID may enter the proximity/security path.
2. A matching device name must never be sufficient for admission.
3. One RSSI reading must never directly authorize locking or waking.
4. Bluetooth disabled, unauthorized, resetting, sleeping, or ambiguous identity
   must fail closed to `UNKNOWN`.
5. Credentials and plaintext secrets must never be logged, serialized to the
   candidate store, or injected through simulated keyboard input.
6. A lock or wake action must be serialized, current-state-valid, and
   idempotent.

## Follow-up Findings From the Mitigation Review

The following issues remain unresolved in the current mitigation pass. They
must be fixed before live locking is considered safe.

## 12. Action executor does not actually serialize actions

- **Severity:** Critical
- **Affected file:** `Sources/AuraSenseCore/Actions/ActionExecutor.swift:11,45-75`
- **Bug:** `executionLock` is declared but never acquired. Multiple
  `executeSerialized(.requestLock, ...)` calls can therefore pass validation
  concurrently and invoke the action provider more than once.
- **Why this is unsafe:** Two simultaneous departure transitions can issue
  repeated lock commands before either request updates the policy latch.
- **Smallest safe fix:** Implement real serialization around action admission
  and execution. Prefer an actor or async mutex; do not hold an `NSLock`
  across `await`. Reserve the action before suspension so concurrent requests
  cannot both dispatch.
- **Required test:** Start two concurrent serialized lock executions with a
  blocking provider and assert that the provider is invoked only once.

## 13. Generation token is invalidated immediately for every near transition

- **Severity:** Critical
- **Affected file:** `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:204-211`
- **Bug:** The transition handler calls `advanceGeneration`, then calls
  `invalidate` again for `NEAR` and `UNKNOWN`. The wake task receives the
  first token, which has already been invalidated by the second increment.
- **Why this is wrong:** Valid auto-wake transitions are rejected before the
  wake action can execute.
- **Smallest safe fix:** Invalidate older work before creating the current
  transition token, or make `advanceGeneration` perform the invalidation and
  do not increment again for the same transition.
- **Required test:** Establish a valid `NEAR` transition with auto-wake
  enabled and assert exactly one wake action executes.

## 14. Production action adapter does not perform in-flight validation

- **Severity:** High
- **Affected files:** `Sources/AuraSenseCore/Actions/ActionProviderProtocol.swift:36-51`,
  `Sources/AuraSenseCore/Actions/MacOSActionAdapter.swift:58-95`
- **Bug:** The default validation overload checks state before calling the
  legacy action method. `MacOSActionAdapter` does not override the overload,
  so state can change after validation and before the irreversible OS side
  effect.
- **Why this is unsafe:** A lock or wake can execute after the trusted device
  has returned or Bluetooth health has been lost. A post-action generation
  check cannot undo an already executed side effect.
- **Smallest safe fix:** Implement the validation hook in the concrete adapter
  immediately before each irreversible OS call. Keep post-action invalidation
  as telemetry only; it is not cancellation.
- **Required test:** Block immediately before the mock OS side effect,
  invalidate the generation, release the block, and assert the side effect
  is not called.

## 15. Policy lock latch is not reserved before asynchronous execution

- **Severity:** High
- **Affected file:** `Sources/AuraSenseCore/Actions/PolicyEngine.swift:129-168`
- **Bug:** `hasLockedForCurrentDeparture` is set only after an action returns
  `.executed`. Concurrent requests can both observe it as false and both
  dispatch lock operations.
- **Why this is unsafe:** Repeated lock commands can be sent for one departure,
  even though the policy claims to enforce idempotency.
- **Smallest safe fix:** Reserve an in-flight lock/wake operation while holding
  the policy lock, or make the serialized action executor the sole owner of
  action admission. Clear the reservation only on rejection/failure; retain
  it after success.
- **Required test:** Run concurrent FAR transitions and assert one attempt,
  one execution, and one suppressed request.

## 16. Duplicate CoreBluetooth discoveries remain uncoalesced

- **Severity:** High
- **Affected file:** `Sources/AuraSenseCore/BLE/CoreBluetoothScanner.swift:83-93`
- **Bug:** `CBCentralManagerScanOptionAllowDuplicatesKey` remains enabled and
  every advertisement reaches registry mutation, identity classification,
  diagnostics logging, and proximity processing.
- **Why this is wrong:** High-rate advertisements increase CPU usage, memory
  churn, logging, and security-state processing. This is unnecessary when
  scanning all nearby peripherals.
- **Smallest safe fix:** Disable duplicates unless continuous RSSI is required.
  If duplicates are required, coalesce or rate-limit observations per
  peripheral before diagnostics and policy processing.
- **Required test:** Simulate hundreds of discoveries in a short interval and
  assert bounded history, logging, processing, and security actions.

## 17. Unauthorized start leaves monitoring requested

- **Severity:** Medium
- **Affected file:** `Sources/AuraSenseCore/BLE/CoreBluetoothScanner.swift:61-78`
- **Bug:** `_isMonitoringRequested` is set to `true` before authorization is
  checked. A denied start can therefore leave the scanner logically requested
  even though it threw an authorization error.
- **Why this is wrong:** A later radio or authorization callback may start
  scanning unexpectedly without a new successful user request.
- **Smallest safe fix:** Set the monitoring flag only after state and
  authorization checks pass, or clear it on every throwing path.
- **Required test:** Call `startScanning` while unauthorized, then simulate
  authorization and radio changes. Assert scanning does not start until an
  explicit successful request.

## 18. Stale peripheral records are never purged

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/Diagnostics/PeripheralRegistry.swift:118-137`,
  `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:313-340`
- **Bug:** Active-peer filtering exists, but stale records remain in the
  registry and diagnostics snapshots indefinitely unless `purgeStalePeripherals`
  is explicitly called. Long-running sessions can grow without a bound.
- **Why this is wrong:** Memory and diagnostic output grow over time, and old
  records can obscure the current device set.
- **Smallest safe fix:** Purge records periodically from the existing tick or
  heartbeat path using a bounded retention policy. Preserve intentional
  candidate diagnostics if required by the UI.
- **Required test:** Add many transient peripherals, advance the reference
  time, purge, and assert registry size remains bounded while active/stale/lost
  reporting is correct.

## 19. Lifecycle transitions can race with timer-driven security evaluation

- **Severity:** Medium
- **Affected files:** `Sources/AuraSenseCore/Proximity/ProximityEngine.swift:137-177`,
  `Sources/AuraSense/main.swift`
- **Bug:** A timer tick may run while sleep, Bluetooth reset, authorization
  loss, or scanner recovery is being processed. If action invalidation and
  health updates are not ordered first, a stale countdown can still reach
  `FAR` and dispatch a lock.
- **Why this is unsafe:** Sleep/wake and Bluetooth-off transitions must fail
  closed and must never produce a lock or wake based on stale evidence.
- **Smallest safe fix:** Invalidate action generations before processing
  lifecycle state. Cancel countdowns and force `UNKNOWN` on sleep, radio
  reset, unauthorized state, and scanner errors. Require fresh candidate
  evidence after recovery.
- **Required tests:** Simulate sleep and radio reset during countdown. Assert
  countdown cancellation, `UNKNOWN`, no lock, and no wake until a new valid
  RSSI sequence arrives.

## 20. Obsolete policy tasks can accumulate

- **Severity:** Low
- **Affected file:** `Sources/AuraSenseCore/Diagnostics/DiagnosticsManager.swift:213-219`
- **Bug:** Each transition creates an unstructured `Task`. Rapid alternating
  transitions can accumulate obsolete tasks even when generation checks later
  reject their actions.
- **Why this is wrong:** It increases scheduling overhead and retains captured
  state longer than necessary.
- **Smallest safe fix:** Keep one cancellable policy task per action type, or
  use an actor-owned task slot and cancel older work when a newer generation
  supersedes it.
- **Required test:** Generate rapid alternating transitions and assert pending
  work remains bounded and no cancelled action executes.

## Updated release gate

Before enabling `--live-lock`, all Critical and High findings in this document
must have a passing regression test. In particular, verify all of the
following together:

1. Only the registered UUID can reach the policy layer.
2. Concurrent transitions cannot issue duplicate lock commands.
3. A valid wake transition is not invalidated by its own generation handling.
4. State changes immediately before an OS side effect prevent that side effect.
5. Sleep, Bluetooth-off, unauthorized, reset, ambiguity, candidate removal, and
   temporary disappearance fail closed to `UNKNOWN`.
