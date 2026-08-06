# Keep awake with lid closed — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a menu-bar toggle that keeps a MacBook awake with the lid closed so Claude Code sessions survive, and that restores normal sleep automatically and reliably.

**Architecture:** A root LaunchDaemon registered via `SMAppService` is the only thing that can flip the undocumented `pmset disablesleep` setting. It exposes one XPC operation guarded by a code-signing requirement, and it holds a renewable *lease*: the app renews every 15s, so a crashed or force-quit app lets the lease lapse and the daemon restores sleep on its own. All decision logic (when to give up the lease) lives as pure functions in Swift packages and is unit-tested; the privileged binary makes no decisions.

**Tech Stack:** Swift 5.9, SwiftUI, SPM (`ClaudeUsageCore`, new `SleepLease`), XcodeGen, `ServiceManagement.SMAppService`, `NSXPCConnection`, IOKit power management, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-06-keep-awake-lid-closed-design.md`

**Branch:** `feat/keep-awake-lid-closed`

---

## File structure

**New SPM target `SleepLease`** (zero dependencies, linked by both the app and the root daemon — this is why it is separate from `ClaudeUsageCore`, which must never be linked into a privileged binary):

| File | Responsibility |
| --- | --- |
| `ClaudeUsageCore/Sources/SleepLease/Lease.swift` | Lease expiry arithmetic |
| `ClaudeUsageCore/Sources/SleepLease/LeaseMarker.swift` | On-disk ownership marker + boot-restore decision |
| `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseTests.swift` | Tests |
| `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseMarkerTests.swift` | Tests |

**`ClaudeUsageCore`** (app-side only, pure logic + IOKit readers):

| File | Responsibility |
| --- | --- |
| `Sources/ClaudeUsageCore/SleepPolicy.swift` | `decideSleep(SleepWorld) -> SleepDecision` |
| `Sources/ClaudeUsageCore/WakeAssertions.swift` | Protocol + IOKit reader for wake-assertion holders |
| `Sources/ClaudeUsageCore/PowerSource.swift` | Protocol + IOKit reader for battery/AC |
| `Sources/ClaudeUsageCore/KeepAwakeText.swift` | Pure UI/notification string builders |
| `Tests/ClaudeUsageCoreTests/SleepPolicyTests.swift` | Tests |
| `Tests/ClaudeUsageCoreTests/WakeAssertionsTests.swift` | Tests (fake reader) |
| `Tests/ClaudeUsageCoreTests/KeepAwakeTextTests.swift` | Tests |

**Shared between app and daemon:**

| File | Responsibility |
| --- | --- |
| `ClaudeUsage/Shared/SleeperProtocol.swift` | `@objc` XPC protocol + service name + signing requirement |

**Daemon target `claude-usage-sleeperd`:**

| File | Responsibility |
| --- | --- |
| `ClaudeUsage/Sleeperd/main.swift` | Entry point, boot self-heal, run loop |
| `ClaudeUsage/Sleeperd/SleepSetting.swift` | `pmset` write + IOKit read-back |
| `ClaudeUsage/Sleeperd/MarkerStore.swift` | Marker file IO |
| `ClaudeUsage/Sleeperd/Clamshell.swift` | Lid state + explicit system sleep |
| `ClaudeUsage/Sleeperd/SleeperService.swift` | XPC listener, delegate, lease timer |
| `ClaudeUsage/LaunchDaemons/com.sven.claude-usage.sleeperd.plist` | Daemon plist |

**App:**

| File | Responsibility |
| --- | --- |
| `ClaudeUsage/ClaudeUsage/PrivilegedClient.swift` | `SMAppService` registration + XPC client |
| `ClaudeUsage/ClaudeUsage/SleepGuard.swift` | `ObservableObject`: 15s tick, policy, renewal |
| `ClaudeUsage/ClaudeUsage/KeepAwakeRow.swift` | Dropdown toggle + first-run sheet |
| `ClaudeUsage/ClaudeUsage/MenuBarView.swift` | Modified: insert the row |
| `ClaudeUsage/ClaudeUsage/ClaudeUsageApp.swift` | Modified: own `SleepGuard`, moon glyph |
| `ClaudeUsage/ClaudeUsage/SettingsView.swift` | Modified: Sleep tab |
| `ClaudeUsage/ClaudeUsage/ResetNotifier.swift` | Modified: sleep-restored notification |
| `ClaudeUsage/project.yml` | Modified: daemon target, embedding, plist copy |

---

## Task 1: SleepLease target and lease arithmetic

**Files:**
- Modify: `ClaudeUsageCore/Package.swift`
- Create: `ClaudeUsageCore/Sources/SleepLease/Lease.swift`
- Test: `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseTests.swift`

- [ ] **Step 1: Add the target to Package.swift**

Replace the whole file with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        // Deliberately separate from ClaudeUsageCore: the root daemon links this and
        // nothing else, so the usage client, networking and keychain code never end
        // up inside a privileged binary.
        .library(name: "SleepLease", targets: ["SleepLease"]),
    ],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "SleepLease"),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SleepLeaseTests", dependencies: ["SleepLease"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseTests.swift`:

```swift
import XCTest
@testable import SleepLease

final class LeaseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_startingSetsExpiryAtNowPlusTTL() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertEqual(lease.expiresAt, t0.addingTimeInterval(90))
    }

    func test_notExpiredBeforeDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertFalse(lease.isExpired(at: t0.addingTimeInterval(89)))
    }

    func test_expiredExactlyAtDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertTrue(lease.isExpired(at: t0.addingTimeInterval(90)))
    }

    func test_renewalExtendsTheDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        let renewed = lease.renewed(at: t0.addingTimeInterval(15), ttl: 90)
        XCTAssertEqual(renewed.expiresAt, t0.addingTimeInterval(105))
        XCTAssertFalse(renewed.isExpired(at: t0.addingTimeInterval(100)))
    }

    // Renewal always recomputes from `now`, so a clock that jumps backwards
    // shortens the lease rather than extending it indefinitely. Failing safe
    // (sleep comes back sooner) is the correct direction for this feature.
    func test_renewalAfterBackwardsClockJumpShortensRatherThanExtends() {
        let lease = Lease.starting(at: t0, ttl: 90)
        let renewed = lease.renewed(at: t0.addingTimeInterval(-3600), ttl: 90)
        XCTAssertLessThan(renewed.expiresAt, lease.expiresAt)
    }

    func test_secondsRemainingCountsDownAndFloorsAtZero() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertEqual(lease.secondsRemaining(at: t0.addingTimeInterval(30)), 60)
        XCTAssertEqual(lease.secondsRemaining(at: t0.addingTimeInterval(500)), 0)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter LeaseTests
```

Expected: compile error, `cannot find 'Lease' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ClaudeUsageCore/Sources/SleepLease/Lease.swift`:

```swift
import Foundation

/// A time-limited grant to keep the system awake.
///
/// The app renews the lease on a timer while its toggle is on. If the app stops
/// renewing for any reason — crash, force-quit, logout, kernel panic — the lease
/// lapses and the daemon restores normal sleep. Crash safety is therefore a
/// structural property rather than a cleanup path someone has to remember.
public struct Lease: Equatable, Sendable {
    public let expiresAt: Date

    public init(expiresAt: Date) { self.expiresAt = expiresAt }

    public static func starting(at now: Date, ttl: TimeInterval) -> Lease {
        Lease(expiresAt: now.addingTimeInterval(ttl))
    }

    public func renewed(at now: Date, ttl: TimeInterval) -> Lease {
        Lease(expiresAt: now.addingTimeInterval(ttl))
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    public func secondsRemaining(at now: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.down)))
    }
}

/// How long a single grant lasts. The app renews every `leaseRenewInterval`, so
/// this tolerates five consecutive missed renewals before sleep comes back.
public let leaseTTL: TimeInterval = 90

/// The app's tick: evaluates policy and renews the lease in the same pass.
public let leaseRenewInterval: TimeInterval = 15
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter LeaseTests
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsageCore/Package.swift ClaudeUsageCore/Sources/SleepLease ClaudeUsageCore/Tests/SleepLeaseTests
git commit -m "feat(core): add SleepLease target with lease expiry arithmetic"
```

---

## Task 2: Lease marker and boot-restore decision

The marker is a root-owned file recording that *we* disabled sleep. On daemon start it is how the daemon knows to clean up after a crashed app, and how it avoids stomping a `disablesleep` value the user set themselves.

**Files:**
- Create: `ClaudeUsageCore/Sources/SleepLease/LeaseMarker.swift`
- Test: `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseMarkerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeUsageCore/Tests/SleepLeaseTests/LeaseMarkerTests.swift`:

```swift
import XCTest
@testable import SleepLease

final class LeaseMarkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_noMarkerMeansNothingToRestore() {
        XCTAssertFalse(shouldRestoreOnBoot(marker: nil))
    }

    func test_ourMarkerMeansRestore() {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: false, setAt: t0)
        XCTAssertTrue(shouldRestoreOnBoot(marker: m))
    }

    // The user ran `sudo pmset -a disablesleep 1` themselves before ever using
    // the toggle. We recorded that we found it already on, and we must not undo it.
    func test_userSettingIsNeverUndone() {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: true, setAt: t0)
        XCTAssertFalse(shouldRestoreOnBoot(marker: m))
    }

    // Nothing writes a marker with ownedByUs false today, but the reader must not
    // depend on the writer's discipline: a marker that is not ours is not ours to act on.
    func test_markerNotOwnedByUsIsNeverActedOn() {
        let m = LeaseMarker(ownedByUs: false, sleepWasAlreadyDisabled: false, setAt: t0)
        XCTAssertFalse(shouldRestoreOnBoot(marker: m))
    }

    func test_roundTripsThroughJSON() throws {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: false, setAt: t0)
        let data = try m.encoded()
        XCTAssertEqual(try LeaseMarker.decoded(from: data), m)
    }

    func test_decodingGarbageThrows() {
        XCTAssertThrowsError(try LeaseMarker.decoded(from: Data("not json".utf8)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter LeaseMarkerTests
```

Expected: compile error, `cannot find 'LeaseMarker' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeUsageCore/Sources/SleepLease/LeaseMarker.swift`:

```swift
import Foundation

/// Written by the daemon (root-owned, mode 0600) before it disables sleep, and
/// removed once sleep is restored. Its presence at daemon start means the app
/// died without giving the lease back.
public struct LeaseMarker: Codable, Equatable, Sendable {
    /// We are the ones who set SleepDisabled.
    public let ownedByUs: Bool
    /// SleepDisabled was already 1 when we first looked, i.e. the user set it
    /// themselves. We must never restore it to 0 in that case.
    public let sleepWasAlreadyDisabled: Bool
    public let setAt: Date

    public init(ownedByUs: Bool, sleepWasAlreadyDisabled: Bool, setAt: Date) {
        self.ownedByUs = ownedByUs
        self.sleepWasAlreadyDisabled = sleepWasAlreadyDisabled
        self.setAt = setAt
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decoded(from data: Data) throws -> LeaseMarker {
        try JSONDecoder().decode(LeaseMarker.self, from: data)
    }
}

/// Absolute path of the marker. Root-owned, outside the app bundle so it
/// survives an app that was deleted mid-lease.
public let leaseMarkerPath = "/Library/Application Support/com.sven.claude-usage/lease.json"

/// On daemon start: restore sleep only if we set it and it was not the user's
/// own pre-existing setting.
public func shouldRestoreOnBoot(marker: LeaseMarker?) -> Bool {
    guard let marker else { return false }
    return marker.ownedByUs && !marker.sleepWasAlreadyDisabled
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter LeaseMarkerTests
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsageCore/Sources/SleepLease/LeaseMarker.swift ClaudeUsageCore/Tests/SleepLeaseTests/LeaseMarkerTests.swift
git commit -m "feat(core): add lease ownership marker and boot-restore decision"
```

---

## Task 3: Sleep policy

The four guardrails, as one pure function.

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/SleepPolicy.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/SleepPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/SleepPolicyTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageCore

final class SleepPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Defaults describe a healthy world: on AC, full battery, just enabled,
    /// work actively running. Each test perturbs one axis.
    private func world(elapsed: TimeInterval = 0,
                       cap: TimeInterval = 4 * 3600,
                       sinceAssertion: TimeInterval = 0,
                       battery: Int = 100,
                       onAC: Bool = true) -> SleepWorld {
        let now = t0.addingTimeInterval(elapsed)
        return SleepWorld(now: now,
                          enabledAt: t0,
                          cap: cap,
                          lastAssertionAt: now.addingTimeInterval(-sinceAssertion),
                          batteryPercent: battery,
                          onACPower: onAC)
    }

    func test_healthyWorldKeepsAwake() {
        XCTAssertEqual(decideSleep(world()), .keepAwake)
    }

    func test_lowBatteryOnBatteryRestores() {
        XCTAssertEqual(decideSleep(world(battery: 19, onAC: false)), .restore(.lowBattery))
    }

    func test_batteryFloorIsInclusive() {
        XCTAssertEqual(decideSleep(world(battery: 20, onAC: false)), .restore(.lowBattery))
        XCTAssertEqual(decideSleep(world(battery: 21, onAC: false)), .keepAwake)
    }

    func test_lowBatteryIgnoredOnAC() {
        XCTAssertEqual(decideSleep(world(battery: 5, onAC: true)), .keepAwake)
    }

    func test_capReachedRestores() {
        XCTAssertEqual(decideSleep(world(elapsed: 4 * 3600)), .restore(.capReached))
    }

    func test_justUnderCapKeepsAwake() {
        XCTAssertEqual(decideSleep(world(elapsed: 4 * 3600 - 1)), .keepAwake)
    }

    func test_noActiveWorkRestoresAfterGrace() {
        XCTAssertEqual(decideSleep(world(sinceAssertion: 120)), .restore(.noActiveWork))
    }

    func test_withinGraceKeepsAwake() {
        XCTAssertEqual(decideSleep(world(sinceAssertion: 119)), .keepAwake)
    }

    // lastAssertionAt is seeded to enabledAt, so a machine enabled while Claude
    // is between turns must not restore immediately.
    func test_seededAtEnableDoesNotRestoreImmediately() {
        let w = SleepWorld(now: t0, enabledAt: t0, cap: 4 * 3600,
                           lastAssertionAt: t0, batteryPercent: 100, onACPower: false)
        XCTAssertEqual(decideSleep(w), .keepAwake)
    }

    func test_batteryOutranksCap() {
        XCTAssertEqual(decideSleep(world(elapsed: 5 * 3600, battery: 10, onAC: false)),
                       .restore(.lowBattery))
    }

    func test_capOutranksNoActiveWork() {
        XCTAssertEqual(decideSleep(world(elapsed: 5 * 3600, sinceAssertion: 600)),
                       .restore(.capReached))
    }

    func test_oneHourCapIsHonoured() {
        XCTAssertEqual(decideSleep(world(elapsed: 3600, cap: 3600)), .restore(.capReached))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter SleepPolicyTests
```

Expected: compile error, `cannot find 'SleepWorld' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeUsageCore/Sources/ClaudeUsageCore/SleepPolicy.swift`:

```swift
import Foundation

public enum SleepRestoreReason: String, Sendable, Equatable, Codable {
    case lowBattery, capReached, noActiveWork
}

public enum SleepDecision: Sendable, Equatable {
    case keepAwake
    case restore(SleepRestoreReason)
}

/// Everything the policy needs, captured at one instant so the decision is pure.
public struct SleepWorld: Sendable, Equatable {
    public let now: Date
    public let enabledAt: Date
    public let cap: TimeInterval
    /// Last time anything held a wake assertion. Seeded to `enabledAt` on enable
    /// so the grace clock never fires just because Claude is between turns.
    public let lastAssertionAt: Date
    public let batteryPercent: Int
    public let onACPower: Bool

    public init(now: Date, enabledAt: Date, cap: TimeInterval,
                lastAssertionAt: Date, batteryPercent: Int, onACPower: Bool) {
        self.now = now
        self.enabledAt = enabledAt
        self.cap = cap
        self.lastAssertionAt = lastAssertionAt
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

/// How long nothing may hold a wake assertion before we give the lease back.
/// Absorbs the gaps between Claude Code turns.
public let sleepGracePeriod: TimeInterval = 120

/// Below this, on battery, sleep comes back regardless of anything else.
public let sleepBatteryFloor = 20

public let sleepCapDefault: TimeInterval = 4 * 3600

/// Whether to keep the machine awake. Checked most-serious-first so the
/// notification can name the real cause.
public func decideSleep(_ w: SleepWorld) -> SleepDecision {
    if !w.onACPower && w.batteryPercent <= sleepBatteryFloor { return .restore(.lowBattery) }
    if w.now.timeIntervalSince(w.enabledAt) >= w.cap { return .restore(.capReached) }
    if w.now.timeIntervalSince(w.lastAssertionAt) >= sleepGracePeriod { return .restore(.noActiveWork) }
    return .keepAwake
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter SleepPolicyTests
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsageCore/Sources/ClaudeUsageCore/SleepPolicy.swift ClaudeUsageCore/Tests/ClaudeUsageCoreTests/SleepPolicyTests.swift
git commit -m "feat(core): add sleep policy with battery, cap and idle guardrails"
```

---

## Task 4: Wake assertion and power source readers

Both are protocols so the policy can be driven by fakes in tests; the IOKit conformers are verified by hand in Task 14.

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/WakeAssertions.swift`
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/PowerSource.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/WakeAssertionsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/WakeAssertionsTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageCore

private struct FakeAssertions: WakeAssertionReading {
    let snap: WakeAssertionSnapshot
    func snapshot() -> WakeAssertionSnapshot { snap }
}

final class WakeAssertionsTests: XCTestCase {
    func test_noHoldersMeansNothingIsKeepingTheMacAwake() {
        let s = WakeAssertionSnapshot(holderCount: 0, processNames: [])
        XCTAssertFalse(s.isAnythingHoldingWake)
    }

    func test_holdersMeanSomethingIsKeepingTheMacAwake() {
        let s = WakeAssertionSnapshot(holderCount: 2, processNames: ["claude", "caffeinate"])
        XCTAssertTrue(s.isAnythingHoldingWake)
    }

    func test_protocolCanBeFaked() {
        let fake = FakeAssertions(snap: WakeAssertionSnapshot(holderCount: 1, processNames: ["claude"]))
        XCTAssertEqual(fake.snapshot().processNames, ["claude"])
    }

    func test_holderSummaryListsNamesInOrder() {
        XCTAssertEqual(holderSummary(["claude", "caffeinate"]), "claude, caffeinate")
    }

    func test_holderSummaryTruncatesLongLists() {
        XCTAssertEqual(holderSummary(["a", "b", "c", "d"]), "a, b and 2 more")
    }

    func test_holderSummaryOfNothing() {
        XCTAssertEqual(holderSummary([]), "nothing")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter WakeAssertionsTests
```

Expected: compile error, `cannot find type 'WakeAssertionReading' in scope`.

- [ ] **Step 3: Write WakeAssertions.swift**

Create `ClaudeUsageCore/Sources/ClaudeUsageCore/WakeAssertions.swift`:

```swift
import Foundation
import IOKit.pwr_mgt

/// Who is currently holding the system awake.
public struct WakeAssertionSnapshot: Sendable, Equatable {
    public let holderCount: Int
    /// Unique, sorted process names, for showing the user why the Mac is awake.
    public let processNames: [String]

    public init(holderCount: Int, processNames: [String]) {
        self.holderCount = holderCount
        self.processNames = processNames
    }

    public var isAnythingHoldingWake: Bool { holderCount > 0 }
}

public protocol WakeAssertionReading: Sendable {
    func snapshot() -> WakeAssertionSnapshot
}

/// Human-readable holder list for the dropdown subtitle.
public func holderSummary(_ names: [String]) -> String {
    if names.isEmpty { return "nothing" }
    if names.count <= 3 { return names.joined(separator: ", ") }
    return "\(names[0]), \(names[1]) and \(names.count - 2) more"
}

/// Reads live assertions from IOKit. Unprivileged — no daemon round-trip needed.
public struct IOKitWakeAssertions: WakeAssertionReading {
    public init() {}

    public func snapshot() -> WakeAssertionSnapshot {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return WakeAssertionSnapshot(holderCount: 0, processNames: [])
        }

        let wanted: Set<String> = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionTypeNoIdleSleep as String,
        ]

        var names: [String] = []
        for (_, assertions) in byProcess {
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      wanted.contains(type) else { continue }
                let name = assertion["Process Name"] as? String ?? "unknown"
                names.append(name)
            }
        }
        return WakeAssertionSnapshot(holderCount: names.count,
                                     processNames: Array(Set(names)).sorted())
    }
}
```

- [ ] **Step 4: Write PowerSource.swift**

Create `ClaudeUsageCore/Sources/ClaudeUsageCore/PowerSource.swift`:

```swift
import Foundation
import IOKit.ps

public struct PowerSnapshot: Sendable, Equatable {
    public let batteryPercent: Int
    public let onACPower: Bool

    public init(batteryPercent: Int, onACPower: Bool) {
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

public protocol PowerSourceReading: Sendable {
    func snapshot() -> PowerSnapshot
}

/// Reads battery level and power source from IOKit. Unprivileged.
public struct IOKitPowerSource: PowerSourceReading {
    public init() {}

    public func snapshot() -> PowerSnapshot {
        // A desktop Mac has no battery: report as if on mains at full charge so
        // the battery guardrail can never fire there.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
                as? [String: Any]
        else {
            return PowerSnapshot(batteryPercent: 100, onACPower: true)
        }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 100
        let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return PowerSnapshot(batteryPercent: percent, onACPower: onAC)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter WakeAssertionsTests
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Sanity-check the IOKit readers against reality**

The fakes prove the shape, not the IOKit calls. Add a temporary test that prints
what the real readers see, run it, compare against the system tools, then delete it.

Append to `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/WakeAssertionsTests.swift`:

```swift
    func test_TEMPORARY_printLiveReadings() {
        let a = IOKitWakeAssertions().snapshot()
        print("holders=\(a.holderCount) names=\(a.processNames)")
        let p = IOKitPowerSource().snapshot()
        print("battery=\(p.batteryPercent)% onAC=\(p.onACPower)")
    }
```

Run it alongside the system tools:

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore
swift test --filter test_TEMPORARY_printLiveReadings 2>&1 | grep -E "holders=|battery="
pmset -g assertions | grep -E "PreventUserIdleSystemSleep|NoIdleSleep"
pmset -g batt
```

Expected: the printed process names match the processes `pmset -g assertions`
lists, and the battery percent matches `pmset -g batt` within 1%. If the reader
returns zero holders while `pmset` lists some, the assertion-type constants are
wrong — print the raw `assertion` dictionaries and correct the `wanted` set.

Delete `test_TEMPORARY_printLiveReadings` before committing: it asserts nothing
and its output depends on whatever happens to be running.

- [ ] **Step 7: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsageCore/Sources/ClaudeUsageCore/WakeAssertions.swift ClaudeUsageCore/Sources/ClaudeUsageCore/PowerSource.swift ClaudeUsageCore/Tests/ClaudeUsageCoreTests/WakeAssertionsTests.swift
git commit -m "feat(core): add IOKit wake-assertion and power-source readers"
```

---

## Task 5: User-facing strings

Pure builders, so the wording is testable and the views stay dumb.

**Files:**
- Create: `ClaudeUsageCore/Sources/ClaudeUsageCore/KeepAwakeText.swift`
- Test: `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/KeepAwakeTextTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeUsageCore/Tests/ClaudeUsageCoreTests/KeepAwakeTextTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageCore

final class KeepAwakeTextTests: XCTestCase {
    func test_offSubtitle() {
        XCTAssertEqual(keepAwakeSubtitle(.off),
                       "Your Mac sleeps normally when you close the lid.")
    }

    func test_needsSetupSubtitle() {
        XCTAssertEqual(keepAwakeSubtitle(.needsSetup), "Needs a one-time admin approval.")
    }

    func test_activeSubtitleListsHoldersTimeAndBattery() {
        let s = keepAwakeSubtitle(.active(holders: ["claude", "caffeinate"],
                                          secondsLeft: 11_520, batteryPercent: 64, onAC: false))
        XCTAssertEqual(s, "Awake for claude, caffeinate · 3h12m left · 64%")
    }

    func test_activeSubtitleOmitsBatteryOnAC() {
        let s = keepAwakeSubtitle(.active(holders: ["claude"],
                                          secondsLeft: 3600, batteryPercent: 64, onAC: true))
        XCTAssertEqual(s, "Awake for claude · 1h0m left")
    }

    func test_graceSubtitleCountsDown() {
        XCTAssertEqual(keepAwakeSubtitle(.grace(secondsUntilSleep: 100)),
                       "Nothing running, sleeping in 1m 40s")
    }

    func test_graceSubtitleUnderAMinute() {
        XCTAssertEqual(keepAwakeSubtitle(.grace(secondsUntilSleep: 40)),
                       "Nothing running, sleeping in 40s")
    }

    func test_failedSubtitleSurfacesTheProblem() {
        XCTAssertEqual(keepAwakeSubtitle(.failed("Helper not approved")),
                       "Helper not approved")
    }

    func test_shortCountdownFormatting() {
        XCTAssertEqual(formatShortCountdown(seconds: 0), "0s")
        XCTAssertEqual(formatShortCountdown(seconds: 59), "59s")
        XCTAssertEqual(formatShortCountdown(seconds: 60), "1m 0s")
        XCTAssertEqual(formatShortCountdown(seconds: 125), "2m 5s")
        XCTAssertEqual(formatShortCountdown(seconds: -5), "0s")
    }

    func test_restoreNotificationBodies() {
        XCTAssertEqual(sleepRestoredMessage(for: .noActiveWork, capHours: 4),
                       "No active sessions, so your Mac can sleep again.")
        XCTAssertEqual(sleepRestoredMessage(for: .capReached, capHours: 4),
                       "The 4 hour limit was reached, so your Mac can sleep again.")
        XCTAssertEqual(sleepRestoredMessage(for: .lowBattery, capHours: 4),
                       "Battery dropped below 20%, so your Mac can sleep again.")
    }

    func test_capReachedBodyUsesTheConfiguredCap() {
        XCTAssertEqual(sleepRestoredMessage(for: .capReached, capHours: 1),
                       "The 1 hour limit was reached, so your Mac can sleep again.")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter KeepAwakeTextTests
```

Expected: compile error, `cannot find 'keepAwakeSubtitle' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ClaudeUsageCore/Sources/ClaudeUsageCore/KeepAwakeText.swift`:

```swift
import Foundation

/// What the dropdown row is showing. Derived by SleepGuard, rendered by KeepAwakeRow.
public enum KeepAwakeUIState: Sendable, Equatable {
    case off
    case needsSetup
    case active(holders: [String], secondsLeft: Int, batteryPercent: Int, onAC: Bool)
    case grace(secondsUntilSleep: Int)
    case failed(String)
}

/// "2m 5s" / "40s". Used for the short grace countdown, where formatResetLong's
/// minute resolution would sit at "1m" for a whole minute.
public func formatShortCountdown(seconds: Int) -> String {
    let s = max(0, seconds)
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
}

public func keepAwakeSubtitle(_ state: KeepAwakeUIState) -> String {
    switch state {
    case .off:
        return "Your Mac sleeps normally when you close the lid."
    case .needsSetup:
        return "Needs a one-time admin approval."
    case let .active(holders, secondsLeft, batteryPercent, onAC):
        var parts = ["Awake for \(holderSummary(holders))",
                     "\(formatResetLong(seconds: secondsLeft)) left"]
        if !onAC { parts.append("\(batteryPercent)%") }
        return parts.joined(separator: " · ")
    case let .grace(secondsUntilSleep):
        return "Nothing running, sleeping in \(formatShortCountdown(seconds: secondsUntilSleep))"
    case let .failed(message):
        return message
    }
}

public func sleepRestoredMessage(for reason: SleepRestoreReason, capHours: Int) -> String {
    switch reason {
    case .noActiveWork:
        return "No active sessions, so your Mac can sleep again."
    case .capReached:
        return "The \(capHours) hour limit was reached, so your Mac can sleep again."
    case .lowBattery:
        return "Battery dropped below \(sleepBatteryFloor)%, so your Mac can sleep again."
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test --filter KeepAwakeTextTests
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Run the whole suite to check nothing regressed**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test
```

Expected: all tests pass, including the pre-existing ones.

- [ ] **Step 6: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsageCore/Sources/ClaudeUsageCore/KeepAwakeText.swift ClaudeUsageCore/Tests/ClaudeUsageCoreTests/KeepAwakeTextTests.swift
git commit -m "feat(core): add keep-awake subtitle and notification copy"
```

---

## Task 6: Shared XPC contract

One file compiled into both the app and the daemon. It must stay byte-identical between them, which is why it lives outside both source directories.

**Files:**
- Create: `ClaudeUsage/Shared/SleeperProtocol.swift`

- [ ] **Step 1: Write the file**

Create `ClaudeUsage/Shared/SleeperProtocol.swift`:

```swift
import Foundation

/// Mach service the daemon listens on. Must match the plist's MachServices key
/// and the daemon's Label.
public let sleeperMachServiceName = "com.sven.claude-usage.sleeperd"

/// Only the shipped, correctly-signed app may drive the daemon. Without this any
/// local process could disable sleep. Applied with
/// NSXPCConnection.setCodeSigningRequirement(_:) — public API since macOS 13,
/// which matches the deployment target.
public let sleeperClientRequirement =
    "anchor apple generic and identifier \"com.sven.claude-usage\" "
    + "and certificate leaf[subject.OU] = \"H9PBNT2Q88\""

/// The entire privileged surface: one setter and one getter.
@objc public protocol SleeperProtocol {
    /// Disable or restore system sleep. When disabling, `ttl` seconds is a lease:
    /// the daemon restores sleep by itself once it lapses unless the app renews.
    /// Reply is (ok, errorMessage).
    func setSleepDisabled(_ disabled: Bool,
                          ttl: Int,
                          reply: @escaping (Bool, String?) -> Void)

    /// Current state. Reply is (sleepIsDisabled, secondsRemainingOnLease).
    func status(reply: @escaping (Bool, Int) -> Void)
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/Shared/SleeperProtocol.swift
git commit -m "feat(app): add shared XPC contract for the sleep helper"
```

---

## Task 7: Daemon building blocks

Three small units the daemon composes: the `pmset` write with read-back, the marker file, and lid state. Each is written before the service that uses them.

**Files:**
- Create: `ClaudeUsage/Sleeperd/SleepSetting.swift`
- Create: `ClaudeUsage/Sleeperd/MarkerStore.swift`
- Create: `ClaudeUsage/Sleeperd/Clamshell.swift`

- [ ] **Step 1: Write SleepSetting.swift**

```swift
import Foundation
import IOKit.pwr_mgt

/// Reads and writes the undocumented `SleepDisabled` power setting.
///
/// Writing needs root, so this only ever runs inside the daemon. Every write is
/// read back: the setting is undocumented and could change behaviour in a future
/// macOS, and silently believing we disabled sleep would be worse than failing.
enum SleepSetting {
    /// Current value, read via IOKit rather than by parsing `pmset -g` text.
    static func isDisabled() -> Bool {
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue()
                as? [String: Any] else { return false }
        if let n = settings["SleepDisabled"] as? NSNumber { return n.boolValue }
        return false
    }

    /// Sets the value and verifies it took. Returns nil on success, else a message.
    static func set(disabled: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return "Could not run pmset: \(error.localizedDescription)"
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "pmset exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")"
        }

        guard isDisabled() == disabled else {
            return "pmset reported success but SleepDisabled is still \(isDisabled() ? 1 : 0)"
        }
        return nil
    }
}
```

- [ ] **Step 2: Write MarkerStore.swift**

```swift
import Foundation
import SleepLease

/// Root-owned record of the fact that we disabled sleep, so a daemon started
/// after a crash or reboot knows to clean up.
enum MarkerStore {
    private static var url: URL { URL(fileURLWithPath: leaseMarkerPath) }

    static func read() -> LeaseMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LeaseMarker.decoded(from: data)
    }

    static func write(_ marker: LeaseMarker) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? marker.encoded() else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 3: Write Clamshell.swift**

```swift
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Lid state, and the ability to sleep the machine on purpose.
///
/// Restoring `SleepDisabled` to 0 while the lid is already shut may not sleep the
/// Mac on its own — the behaviour is undocumented and could wait for the next lid
/// event, which would make every guardrail useless in exactly the case they exist
/// for. So a guardrail restore with the lid shut sleeps the machine explicitly.
enum Clamshell {
    /// True when the lid is closed.
    static func isClosed() -> Bool {
        let root = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }

        guard let value = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return false }
        return value
    }

    /// Ask the system to sleep now. Root only.
    static func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return }
        defer { IOServiceClose(port) }
        IOPMSleepSystem(port)
    }
}
```

- [ ] **Step 4: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/Sleeperd
git commit -m "feat(daemon): add sleep setting, marker store and clamshell helpers"
```

---

## Task 8: Daemon service and entry point

**Files:**
- Create: `ClaudeUsage/Sleeperd/SleeperService.swift`
- Create: `ClaudeUsage/Sleeperd/main.swift`
- Create: `ClaudeUsage/LaunchDaemons/com.sven.claude-usage.sleeperd.plist`

- [ ] **Step 1: Write SleeperService.swift**

```swift
import Foundation
import SleepLease

/// Implements the XPC contract. Every decision about *whether* to stay awake is
/// made by the app; this only holds the lease and flips the setting.
final class SleeperService: NSObject, SleeperProtocol {
    private let queue = DispatchQueue(label: "com.sven.claude-usage.sleeperd.state")
    private var lease: Lease?
    private var timer: DispatchSourceTimer?
    /// SleepDisabled was already 1 before we ever touched it, i.e. the user's own
    /// setting. Recorded once, and it makes every restore a no-op.
    private var sleepWasAlreadyDisabled = false

    func setSleepDisabled(_ disabled: Bool, ttl: Int,
                          reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            if disabled {
                if self.lease == nil {
                    self.sleepWasAlreadyDisabled = SleepSetting.isDisabled()
                    if let error = SleepSetting.set(disabled: true) {
                        reply(false, error); return
                    }
                    MarkerStore.write(LeaseMarker(ownedByUs: true,
                                                  sleepWasAlreadyDisabled: self.sleepWasAlreadyDisabled,
                                                  setAt: Date()))
                }
                self.lease = Lease.starting(at: Date(), ttl: TimeInterval(ttl))
                self.scheduleExpiry()
                reply(true, nil)
            } else {
                // Explicit toggle-off: restore, but never force sleep on a Mac
                // whose owner is sitting in front of it.
                let error = self.restore(forceSleepIfLidClosed: false)
                reply(error == nil, error)
            }
        }
    }

    func status(reply: @escaping (Bool, Int) -> Void) {
        queue.async {
            let remaining = self.lease?.secondsRemaining(at: Date()) ?? 0
            reply(SleepSetting.isDisabled(), remaining)
        }
    }

    /// Called at daemon start. A marker here means the app died mid-lease.
    func restoreIfOrphaned() {
        queue.async {
            let marker = MarkerStore.read()
            guard shouldRestoreOnBoot(marker: marker) else {
                // Either nothing to do, or the value is the user's own — in which
                // case drop our stale marker but leave the setting alone.
                if marker != nil { MarkerStore.clear() }
                return
            }
            _ = SleepSetting.set(disabled: false)
            MarkerStore.clear()
        }
    }

    // MARK: Private

    /// Must be called on `queue`.
    private func scheduleExpiry() {
        timer?.cancel()
        guard let lease else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + lease.secondsRemaining(at: Date()) + 1)
        t.setEventHandler { [weak self] in
            guard let self, let lease = self.lease else { return }
            guard lease.isExpired(at: Date()) else { self.scheduleExpiry(); return }
            // The app stopped renewing: crash, force-quit, logout, or a guardrail
            // it could not report. Sleep the Mac if the lid is already shut.
            _ = self.restore(forceSleepIfLidClosed: true)
        }
        t.resume()
        timer = t
    }

    /// Must be called on `queue`. Returns nil on success, else a message.
    @discardableResult
    private func restore(forceSleepIfLidClosed: Bool) -> String? {
        timer?.cancel()
        timer = nil
        lease = nil

        guard !sleepWasAlreadyDisabled else {
            // The user set SleepDisabled themselves before we arrived. Give up our
            // claim without changing their setting.
            MarkerStore.clear()
            return nil
        }

        if let error = SleepSetting.set(disabled: false) { return error }
        MarkerStore.clear()

        if forceSleepIfLidClosed && Clamshell.isClosed() { Clamshell.sleepNow() }
        return nil
    }
}

/// Accepts only connections from the correctly-signed app.
final class SleeperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: SleeperService
    init(service: SleeperService) { self.service = service }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try connection.setCodeSigningRequirement(sleeperClientRequirement)
        } catch {
            NSLog("claude-usage-sleeperd: rejected connection: \(error)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: SleeperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
```

- [ ] **Step 2: Write main.swift**

```swift
import Foundation

// RunAtLoad brings us up at boot. If a marker is on disk the app died while
// holding a lease, so restore normal sleep before doing anything else.
let service = SleeperService()
service.restoreIfOrphaned()

let delegate = SleeperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: sleeperMachServiceName)
listener.delegate = delegate
listener.resume()

// Stay resident rather than exiting when idle: a sleeping run loop costs
// nothing, and exiting races in-flight XPC connections for no real benefit.
RunLoop.main.run()
```

- [ ] **Step 3: Write the daemon plist**

Create `ClaudeUsage/LaunchDaemons/com.sven.claude-usage.sleeperd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sven.claude-usage.sleeperd</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/claude-usage-sleeperd</string>
    <key>MachServices</key>
    <dict>
        <key>com.sven.claude-usage.sleeperd</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.sven.claude-usage</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/Sleeperd ClaudeUsage/LaunchDaemons
git commit -m "feat(daemon): add XPC service, lease expiry and boot self-heal"
```

---

## Task 9: Wire the daemon into the build

**Files:**
- Modify: `ClaudeUsage/project.yml`

- [ ] **Step 1: Rewrite project.yml**

```yaml
name: ClaudeUsage
options:
  bundleIdPrefix: com.sven
  deploymentTarget:
    macOS: "13.0"
packages:
  ClaudeUsageCore:
    path: ../ClaudeUsageCore
targets:
  ClaudeUsage:
    type: application
    platform: macOS
    sources:
      - path: ClaudeUsage
      - path: Shared
      - path: LaunchDaemons/com.sven.claude-usage.sleeperd.plist
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchDaemons
    info:
      path: ClaudeUsage/Info.plist
      properties:
        LSUIElement: true
        CFBundleName: Claude Usage
        CFBundleDisplayName: Claude Usage
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.sven.claude-usage
        PRODUCT_NAME: "Claude Usage"
        MARKETING_VERSION: "0.8.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "5.0"
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_IDENTITY: "Developer ID Application"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: H9PBNT2Q88
        ENABLE_HARDENED_RUNTIME: YES
        OTHER_CODE_SIGN_FLAGS: "--timestamp"
    dependencies:
      - package: ClaudeUsageCore
        product: ClaudeUsageCore
      - package: ClaudeUsageCore
        product: SleepLease
      - target: claude-usage-sleeperd
        embed: true
        codeSign: true
        copy:
          destination: executables

  claude-usage-sleeperd:
    type: tool
    platform: macOS
    sources:
      - path: Sleeperd
      - path: Shared
    settings:
      base:
        PRODUCT_NAME: claude-usage-sleeperd
        PRODUCT_BUNDLE_IDENTIFIER: com.sven.claude-usage.sleeperd
        SWIFT_VERSION: "5.0"
        CODE_SIGN_IDENTITY: "Developer ID Application"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: H9PBNT2Q88
        ENABLE_HARDENED_RUNTIME: YES
        OTHER_CODE_SIGN_FLAGS: "--timestamp"
        CREATE_INFOPLIST_SECTION_IN_BINARY: YES
        SKIP_INSTALL: YES
    dependencies:
      - package: ClaudeUsageCore
        product: SleepLease
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage && xcodegen generate && \
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

If XcodeGen rejects the `copyFiles` or `copy` keys, its schema differs in the installed version. Check with `xcodegen --version` and consult `xcodegen dump --help`; the equivalent fallback is to declare the copy phase in `postBuildScripts`:

```yaml
    postBuildScripts:
      - name: Embed LaunchDaemon plist
        script: |
          mkdir -p "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons"
          cp "$SRCROOT/LaunchDaemons/com.sven.claude-usage.sleeperd.plist" \
             "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons/"
```

- [ ] **Step 3: Verify the bundle layout**

This is the step that catches a silently mis-embedded helper, which would fail only at registration time on a user's Mac.

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage
APP=$(xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
find "$APP/Claude Usage.app/Contents/MacOS" "$APP/Claude Usage.app/Contents/Library" -type f
```

Expected exactly:

```
.../Contents/MacOS/Claude Usage
.../Contents/MacOS/claude-usage-sleeperd
.../Contents/Library/LaunchDaemons/com.sven.claude-usage.sleeperd.plist
```

- [ ] **Step 4: Verify both binaries are signed with the same team**

```bash
codesign -dv --verbose=4 "$APP/Claude Usage.app" 2>&1 | grep -E "TeamIdentifier|Identifier"
codesign -dv --verbose=4 "$APP/Claude Usage.app/Contents/MacOS/claude-usage-sleeperd" 2>&1 | grep -E "TeamIdentifier|Identifier"
```

Expected: `TeamIdentifier=H9PBNT2Q88` on both. If the helper is unsigned or ad-hoc signed, `SMAppService.register()` fails with `Operation not permitted`.

- [ ] **Step 5: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/project.yml
git commit -m "build: add sleeperd target, embed helper and LaunchDaemon plist"
```

---

## Task 10: Privileged client

**Files:**
- Create: `ClaudeUsage/ClaudeUsage/PrivilegedClient.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import ServiceManagement

/// Registers the LaunchDaemon and talks to it. All of this is best-effort: every
/// failure path ends with the toggle off and a message the user can act on.
@MainActor
final class PrivilegedClient {
    enum Registration: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case failed(String)
    }

    private static let plistName = "com.sven.claude-usage.sleeperd.plist"
    private var connection: NSXPCConnection?

    private var service: SMAppService { .daemon(plistName: Self.plistName) }

    var registration: Registration {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .failed("Helper missing from the app bundle.")
        @unknown default: return .failed("Unknown helper status.")
        }
    }

    /// Prompts for admin approval the first time. Safe to call when already registered.
    func register() -> Registration {
        guard service.status != .enabled else { return .enabled }
        do {
            try service.register()
        } catch {
            // Already-registered is reported as an error by SMAppService; treat the
            // live status as the truth rather than surfacing a spurious failure.
            if service.status == .enabled { return .enabled }
            return .failed(error.localizedDescription)
        }
        return registration
    }

    func unregister() async {
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    private func proxy() -> SleeperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: sleeperMachServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: SleeperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("claude-usage: XPC error: \(error.localizedDescription)")
        } as? SleeperProtocol
    }

    /// Returns nil on success, else a message to show the user.
    func setSleepDisabled(_ disabled: Bool, ttl: Int) async -> String? {
        guard let proxy = proxy() else { return "Could not reach the sleep helper." }
        return await withCheckedContinuation { continuation in
            var resumed = false
            proxy.setSleepDisabled(disabled, ttl: ttl) { ok, error in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ok ? nil : (error ?? "Unknown helper error."))
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage && xcodegen generate && \
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/ClaudeUsage/PrivilegedClient.swift
git commit -m "feat(app): add SMAppService registration and XPC client"
```

---

## Task 11: SleepGuard

The app-side owner: one 15s tick that evaluates the policy and renews the lease in the same pass.

**Files:**
- Create: `ClaudeUsage/ClaudeUsage/SleepGuard.swift`
- Modify: `ClaudeUsage/ClaudeUsage/ResetNotifier.swift`

- [ ] **Step 1: Add the notification to ResetNotifier.swift**

Insert after `notifyThreshold`:

```swift
    static func notifySleepRestored(_ reason: SleepRestoreReason, capHours: Int) {
        notify(title: "Sleep re-enabled",
               body: sleepRestoredMessage(for: reason, capHours: capHours),
               identifier: "claude-usage-sleep-restored")
    }
```

- [ ] **Step 2: Write SleepGuard.swift**

```swift
import Foundation
import Combine
import ClaudeUsageCore
import SleepLease

/// Owns the keep-awake feature: holds the lease while the policy says to, and
/// gives it back the moment a guardrail trips.
@MainActor
final class SleepGuard: ObservableObject {
    @Published private(set) var uiState: KeepAwakeUIState = .off
    @Published private(set) var isOn = false

    private let client = PrivilegedClient()
    private let assertions: WakeAssertionReading
    private let power: PowerSourceReading

    private var timer: Timer?
    private var enabledAt: Date?
    private var lastAssertionAt: Date?
    private var lease: Lease?

    init(assertions: WakeAssertionReading = IOKitWakeAssertions(),
         power: PowerSourceReading = IOKitPowerSource()) {
        self.assertions = assertions
        self.power = power
        refreshIdleState()
    }

    var cap: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "keepAwakeCapSeconds")
        return stored == 0 ? sleepCapDefault : stored
    }
    var capHours: Int { Int(cap / 3600) }

    var needsSetup: Bool { client.registration != .enabled }

    func openLoginItemsSettings() { client.openLoginItemsSettings() }

    /// First-run path: register the daemon, then turn on if that worked.
    func setUpAndEnable() async {
        switch client.register() {
        case .enabled:
            await enable()
        case .requiresApproval:
            uiState = .failed("Approve Claude Usage in Login Items, then try again.")
            client.openLoginItemsSettings()
        case .notRegistered:
            uiState = .failed("The sleep helper did not install.")
        case let .failed(message):
            uiState = .failed(message)
        }
    }

    func toggle(_ on: Bool) async {
        if on {
            if needsSetup { await setUpAndEnable() } else { await enable() }
        } else {
            await disable(notifying: nil)
        }
    }

    // MARK: Private

    private func enable() async {
        let now = Date()
        enabledAt = now
        lastAssertionAt = now          // seeded: never restore immediately
        if let error = await client.setSleepDisabled(true, ttl: Int(leaseTTL)) {
            enabledAt = nil
            isOn = false
            uiState = .failed(error)
            return
        }
        lease = Lease.starting(at: now, ttl: leaseTTL)
        isOn = true
        startTimer()
        refreshUIState(now: now)
    }

    private func disable(notifying reason: SleepRestoreReason?) async {
        timer?.invalidate()
        timer = nil
        let error = await client.setSleepDisabled(false, ttl: 0)
        enabledAt = nil
        lease = nil
        isOn = false
        if let error {
            uiState = .failed(error)
        } else {
            if let reason { ResetNotifier.notifySleepRestored(reason, capHours: capHours) }
            refreshIdleState()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: leaseRenewInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// One pass: sample the world, decide, then either renew the lease or give it back.
    private func tick() async {
        guard isOn, let enabledAt else { return }
        let now = Date()
        let assertion = assertions.snapshot()
        if assertion.isAnythingHoldingWake { lastAssertionAt = now }

        let powerSnapshot = power.snapshot()
        let world = SleepWorld(now: now,
                               enabledAt: enabledAt,
                               cap: cap,
                               lastAssertionAt: lastAssertionAt ?? enabledAt,
                               batteryPercent: powerSnapshot.batteryPercent,
                               onACPower: powerSnapshot.onACPower)

        switch decideSleep(world) {
        case .keepAwake:
            if let error = await client.setSleepDisabled(true, ttl: Int(leaseTTL)) {
                uiState = .failed(error)
                return
            }
            lease = lease?.renewed(at: now, ttl: leaseTTL) ?? Lease.starting(at: now, ttl: leaseTTL)
            refreshUIState(now: now)
        case let .restore(reason):
            await disable(notifying: reason)
        }
    }

    private func refreshUIState(now: Date) {
        guard isOn, let enabledAt else { refreshIdleState(); return }
        let assertion = assertions.snapshot()
        let powerSnapshot = power.snapshot()

        if !assertion.isAnythingHoldingWake, let lastAssertionAt {
            let idleFor = now.timeIntervalSince(lastAssertionAt)
            uiState = .grace(secondsUntilSleep: Int((sleepGracePeriod - idleFor).rounded(.down)))
            return
        }
        let left = Int(cap - now.timeIntervalSince(enabledAt))
        uiState = .active(holders: assertion.processNames,
                          secondsLeft: max(0, left),
                          batteryPercent: powerSnapshot.batteryPercent,
                          onAC: powerSnapshot.onACPower)
    }

    private func refreshIdleState() {
        uiState = needsSetup ? .needsSetup : .off
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage && xcodegen generate && \
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/ClaudeUsage/SleepGuard.swift ClaudeUsage/ClaudeUsage/ResetNotifier.swift
git commit -m "feat(app): add SleepGuard with policy evaluation and lease renewal"
```

---

## Task 12: Dropdown row, first-run sheet and moon glyph

**Files:**
- Create: `ClaudeUsage/ClaudeUsage/KeepAwakeRow.swift`
- Modify: `ClaudeUsage/ClaudeUsage/MenuBarView.swift:35-44` (`signedInContainer`)
- Modify: `ClaudeUsage/ClaudeUsage/ClaudeUsageApp.swift`

- [ ] **Step 1: Write KeepAwakeRow.swift**

```swift
import SwiftUI
import ClaudeUsageCore

/// The dropdown toggle. All wording comes from keepAwakeSubtitle so it stays testable.
struct KeepAwakeRow: View {
    @ObservedObject var guard_: SleepGuard
    @State private var showingExplainer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Keep awake with lid closed").font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { guard_.isOn },
                    set: { on in
                        // First run explains what this changes before macOS asks
                        // for an admin password out of nowhere.
                        if on && guard_.needsSetup { showingExplainer = true }
                        else { Task { await guard_.toggle(on) } }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(keepAwakeSubtitle(guard_.uiState))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingExplainer) {
            KeepAwakeExplainer(
                onCancel: { showingExplainer = false },
                onContinue: {
                    showingExplainer = false
                    Task { await guard_.setUpAndEnable() }
                })
        }
    }
}

/// Shown once, before the first admin prompt.
struct KeepAwakeExplainer: View {
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep awake with lid closed").font(.headline)
            Text("""
                 Your Mac normally sleeps the moment you close the lid, which ends \
                 any running Claude Code session. This turns that off while you need it.
                 """)
                .font(.callout)
            Text("macOS will ask you to approve a background helper. That happens once.")
                .font(.callout)

            GroupBox("Sleep comes back automatically when") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Nothing has been running for 2 minutes", systemImage: "moon")
                    Label("The time limit is reached (4 hours by default)", systemImage: "timer")
                    Label("Battery drops below 20%", systemImage: "battery.25")
                    Label("Claude Usage quits or crashes", systemImage: "xmark.circle")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Text("A Mac left awake in a bag will keep using battery and getting warm. \
                 Turn this off when you are done.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Insert the row into MenuBarView**

In `ClaudeUsage/ClaudeUsage/MenuBarView.swift`, add the property after line 8:

```swift
    @ObservedObject var sleepGuard: SleepGuard
```

Then replace `signedInContainer` (currently lines 35-44) with:

```swift
    private func signedInContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            workspaceMenu
            content()
            Divider()
            KeepAwakeRow(guard_: sleepGuard)
            Divider()
            footer
        }
        .padding(12)
    }
```

- [ ] **Step 3: Own the guard in the app and add the moon glyph**

In `ClaudeUsage/ClaudeUsage/ClaudeUsageApp.swift`, add after the `model` property:

```swift
    @StateObject private var sleepGuard = SleepGuard()
```

Pass it to both views:

```swift
        MenuBarExtra {
            MenuBarView(model: model, sleepGuard: sleepGuard)
        } label: {
            MenuBarLabel(model: model, sleepGuard: sleepGuard)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Usage Settings", id: "settings") {
            SettingsView(model: model, sleepGuard: sleepGuard)
        }
```

Then in `MenuBarLabel`, add the property and the glyph:

```swift
struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var sleepGuard: SleepGuard
    @Environment(\.openWindow) private var openWindow
    @State private var promptedForLogin = false

    var body: some View {
        HStack(spacing: 2) {
            // The consequence of keep-awake is invisible otherwise, and a Mac that
            // silently stopped sleeping is worth a few pixels of warning.
            if sleepGuard.isOn {
                Image(systemName: "moon.zzz.fill")
            }
            Image(nsImage: ProgressBarImage.make(
                percent: MenuBarView.labelPercent(for: model.state),
                dimmed: MenuBarView.isDimmed(model.state)))
            Text(MenuBarView.labelText(for: model.state))
        }
        .onAppear {
            guard !promptedForLogin else { return }
            promptedForLogin = true
            if !model.isSignedIn {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage && xcodegen generate && \
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If it fails on `SettingsView(model:sleepGuard:)`, that parameter arrives in Task 13 — add `@ObservedObject var sleepGuard: SleepGuard` to `SettingsView` now and leave it unused until then.

- [ ] **Step 5: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/ClaudeUsage/KeepAwakeRow.swift ClaudeUsage/ClaudeUsage/MenuBarView.swift ClaudeUsage/ClaudeUsage/ClaudeUsageApp.swift
git commit -m "feat(app): add keep-awake dropdown row, explainer sheet and moon glyph"
```

---

## Task 13: Settings tab

**Files:**
- Modify: `ClaudeUsage/ClaudeUsage/SettingsView.swift`

- [ ] **Step 1: Add the tab**

Change the `Tab` enum and tab bar in `SettingsView`:

```swift
    @ObservedObject var sleepGuard: SleepGuard
    private enum Tab: Hashable { case general, notifications, sleep, about }
```

```swift
            HStack(spacing: 6) {
                tabButton(.general, "General", "gearshape")
                tabButton(.notifications, "Notifications", "bell")
                tabButton(.sleep, "Sleep", "moon.zzz")
                tabButton(.about, "About", "info.circle")
            }
```

```swift
                switch tab {
                case .general: GeneralSettingsView(model: model)
                case .notifications: NotificationsSettingsView()
                case .sleep: SleepSettingsView(sleepGuard: sleepGuard)
                case .about: AboutSettingsView()
                }
```

- [ ] **Step 2: Add the view**

Append before `AboutSettingsView`:

```swift
private struct SleepSettingsView: View {
    @ObservedObject var sleepGuard: SleepGuard
    @AppStorage("keepAwakeCapSeconds") private var capSeconds = sleepCapDefault
    @State private var removing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Keep awake with lid closed") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lets a running Claude Code session survive a closed lid. \
                             Turn it on from the menu bar dropdown.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(keepAwakeSubtitle(sleepGuard.uiState))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Time limit") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $capSeconds) {
                            Text("1 hour").tag(TimeInterval(3600))
                            Text("4 hours").tag(TimeInterval(4 * 3600))
                            Text("8 hours").tag(TimeInterval(8 * 3600))
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text("Sleep is restored after this long no matter what. \
                             There is deliberately no unlimited option.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("What this changes") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A background helper running as an administrator flips the \
                             system sleep setting. Sleep is restored automatically when \
                             nothing is running, when the time limit is reached, when the \
                             battery drops below 20%, and if this app quits or crashes.")
                        Text("Leaving a Mac awake in a bag will keep draining the battery.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                Button(role: .destructive) {
                    removing = true
                    Task {
                        await sleepGuard.removeHelper()
                        removing = false
                    }
                } label: {
                    Label(removing ? "Removing…" : "Remove helper", systemImage: "trash")
                }
                .disabled(removing)
                Text("Removes the background helper. The toggle stops working until you \
                     approve it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
```

- [ ] **Step 3: Add `removeHelper` to SleepGuard**

In `ClaudeUsage/ClaudeUsage/SleepGuard.swift`, add after `toggle(_:)`:

```swift
    /// Turn the feature off first, then tear down the helper — never leave a
    /// disabled-sleep setting behind with no privileged way to undo it.
    func removeHelper() async {
        if isOn { await disable(notifying: nil) }
        await client.unregister()
        refreshIdleState()
    }
```

- [ ] **Step 4: Build**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage && xcodegen generate && \
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add ClaudeUsage/ClaudeUsage/SettingsView.swift ClaudeUsage/ClaudeUsage/SleepGuard.swift
git commit -m "feat(app): add Sleep settings tab with cap picker and helper removal"
```

---

## Task 14: Manual verification

Nothing here is automatable: it needs root, a real lid, and a signed build in `/Applications`. Run all of it before tagging.

**Setup:**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build
APP=$(xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
rm -rf "/Applications/Claude Usage.app"
cp -R "$APP/Claude Usage.app" /Applications/
open "/Applications/Claude Usage.app"
```

- [ ] **1. Registration.** Toggle on. Expect the explainer sheet, then an admin prompt. Confirm `Claude Usage` appears in System Settings, Login Items and Extensions.

- [ ] **2. The setting is actually applied.**
```bash
pmset -g | grep -i SleepDisabled
```
Expected: `SleepDisabled 1`.

- [ ] **3. A session survives a closed lid.** Start a writer, close the lid for 5 minutes, reopen:
```bash
( while true; do date >> /tmp/lidtest.log; sleep 5; done ) &
```
Expected: no gap longer than ~10s in `/tmp/lidtest.log`. Kill the loop afterwards.

- [ ] **4. Crash self-heal.** With the toggle on:
```bash
pkill -9 -f "Claude Usage"; sleep 95; pmset -g | grep -i SleepDisabled
```
Expected: `SleepDisabled 0` — the lease lapsed and the daemon restored it unattended.

- [ ] **5. Cap expiry.** Temporarily change `sleepCapDefault` in `SleepPolicy.swift` to `60`, delete the stored preference so the default applies, rebuild, and enable the toggle:
```bash
defaults delete com.sven.claude-usage keepAwakeCapSeconds 2>/dev/null
```
Expected: within ~75s, `pmset -g | grep -i SleepDisabled` reports 0 and a "Sleep re-enabled, the 0 hour limit was reached" notification fires. (The odd "0 hour" wording is expected with a 60s cap and confirms `capHours` is being read; it is correct for the real 1/4/8 hour values.) Revert `sleepCapDefault` to `4 * 3600` and rebuild.

- [ ] **6. Battery floor.** Unplug and run the battery below 20%, or temporarily raise `sleepBatteryFloor` above the current charge and rebuild. Expect restore plus the "Battery dropped below" notification.

- [ ] **7. Boot self-heal.** With the toggle on, hard-restart the Mac. After login:
```bash
pmset -g | grep -i SleepDisabled; sudo ls -l "/Library/Application Support/com.sven.claude-usage/"
```
Expected: `SleepDisabled 0` and no `lease.json`.

- [ ] **8. Toggle off is clean.**
```bash
pmset -g | grep -i SleepDisabled; sudo ls "/Library/Application Support/com.sven.claude-usage/" 2>&1
```
Expected: `SleepDisabled 0`, no marker file.

- [ ] **9. Unsigned clients are rejected.**
```bash
cat > /tmp/attack.swift <<'EOF'
import Foundation
let c = NSXPCConnection(machServiceName: "com.sven.claude-usage.sleeperd", options: .privileged)
c.remoteObjectInterface = NSXPCInterface(with: NSObjectProtocol.self)
c.resume()
print("connected:", c.remoteObjectProxy)
EOF
swiftc -o /tmp/attack /tmp/attack.swift && /tmp/attack
```
Expected: the connection is refused and the daemon logs `rejected connection`. Check with `log show --predicate 'process == "claude-usage-sleeperd"' --last 2m`.

- [ ] **10. Guardrail restore sleeps a closed Mac.** This is the assumption the whole battery argument rests on. Set the grace period to 20s temporarily, enable, close the lid with nothing running, wait a minute, then reopen and check:
```bash
log show --predicate 'eventMessage contains "Wake reason"' --last 5m | tail -5
pmset -g log | grep -i "sleep" | tail -5
```
Expected: the machine actually slept rather than waiting for the lid event. If it did not, `Clamshell.sleepNow()` is not firing — check `Clamshell.isClosed()` returns true with the lid shut.

- [ ] **11. A lid-open guardrail restore does NOT sleep the Mac.** With the lid open, let a guardrail trip. Expected: the Mac stays awake and usable.

- [ ] **12. Pre-existing user setting is respected.**
```bash
sudo pmset -a disablesleep 1
```
Then toggle on and off in the app, and check:
```bash
pmset -g | grep -i SleepDisabled
```
Expected: still `1`. The app must not have undone a setting it did not make. Clean up with `sudo pmset -a disablesleep 0`.

- [ ] **13. Helper removal.** Settings, Sleep, Remove helper. Confirm it disappears from System Settings and the toggle reverts to "Set up…".

- [ ] **14. Notarisation.**
```bash
spctl -a -vvv "/Applications/Claude Usage.app"
codesign --verify --deep --strict --verbose=2 "/Applications/Claude Usage.app"
```
Expected: `accepted`, `source=Notarized Developer ID`, and no errors on the embedded helper.

- [ ] **15. Commit any fixes found**

```bash
cd /Users/sven/Projects/claude-usage
git add -A && git commit -m "fix(sleep): address issues found in manual verification"
```

---

## Task 15: Ship

**Files:**
- Modify: `README.md`
- Modify: `homebrew/claude-usage.rb`

- [ ] **Step 1: Document the feature in README.md**

Add after the "Display states" section:

```markdown
## Keep awake with lid closed

Closing the lid normally ends any running Claude Code session. The dropdown has a
**Keep awake with lid closed** toggle that suspends that behaviour while you need it.

The first time you turn it on, macOS asks you to approve a background helper. This
is required: changing the system sleep setting needs administrator rights.

Sleep is restored automatically when:

- nothing has held the Mac awake for 2 minutes,
- the time limit is reached (4 hours by default, configurable in Settings → Sleep),
- the battery drops below 20% on battery power,
- or Claude Usage quits, crashes, or you log out.

A moon icon appears in the menu bar whenever it is active.

> A Mac left awake with the lid shut keeps drawing power and getting warm. Under a
> heavy workload the 20% battery floor will trigger before the time limit does.
```

Then extend the Uninstall section:

```markdown
If you used **Keep awake with lid closed**, remove the helper first via
**Settings → Sleep → Remove helper**. To clean up its state directory manually:

    sudo rm -rf "/Library/Application Support/com.sven.claude-usage"
```

- [ ] **Step 2: Update the cask**

Build the release zip and take its checksum:

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsage
APP=$(xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
ditto -c -k --keepParent "$APP/Claude Usage.app" /tmp/ClaudeUsage-0.8.0.zip
shasum -a 256 /tmp/ClaudeUsage-0.8.0.zip
```

In `homebrew/claude-usage.rb`, set `version "0.8.0"`, paste that checksum into `sha256`, and add the daemon cleanup:

```ruby
  app "Claude Usage.app"

  uninstall launchctl: "com.sven.claude-usage.sleeperd"

  zap trash: [
    "~/Library/Preferences/com.sven.claude-usage.plist",
  ]
```

- [ ] **Step 3: Run the full test suite one final time**

```bash
cd /Users/sven/Projects/claude-usage/ClaudeUsageCore && swift test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/sven/Projects/claude-usage
git add README.md homebrew/claude-usage.rb
git commit -m "docs: document keep-awake toggle and daemon cleanup on uninstall"
```

- [ ] **Step 5: Open the PR**

```bash
cd /Users/sven/Projects/claude-usage
git push -u origin feat/keep-awake-lid-closed
gh pr create --title "feat: keep awake with lid closed" --body "$(cat <<'EOF'
Adds a menu-bar toggle that keeps the Mac awake with the lid closed so Claude Code
sessions survive, backed by an SMAppService LaunchDaemon.

Design: `docs/superpowers/specs/2026-08-06-keep-awake-lid-closed-design.md`
Plan: `docs/superpowers/plans/2026-08-06-keep-awake-lid-closed.md`

Safety properties worth reviewing closely:

- The daemon holds a renewable lease, so a crashed or force-quit app restores sleep
  structurally rather than via a cleanup path.
- `setCodeSigningRequirement` gates every XPC connection.
- A root-owned marker file handles boot-after-crash and avoids stomping a
  `disablesleep` value the user set themselves.
- Guardrail restores sleep the machine explicitly when the lid is already shut,
  rather than trusting undocumented `disablesleep` behaviour.

Manual verification matrix is Task 14 of the plan; all 15 checks were run against a
signed build in /Applications.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the implementer

- **Do not link `ClaudeUsageCore` into the daemon.** The whole security argument is that the privileged binary is small enough to audit in one sitting. It links `SleepLease` only.
- **`sleeperClientRequirement` hardcodes team `H9PBNT2Q88`.** If the signing identity ever changes, this string and `project.yml` must change together or the app silently loses the ability to talk to its own helper.
- **Debug builds cannot register the daemon.** `SMAppService` refuses bundles outside a stable location, so anything touching registration must be tested from a signed copy in `/Applications`.
- **The two numbers most likely to need tuning after real use** are `sleepCapDefault` (4h) and `sleepGracePeriod` (120s), both in `SleepPolicy.swift`.
