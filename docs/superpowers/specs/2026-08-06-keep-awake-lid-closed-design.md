# Keep awake with lid closed

Design doc, 2026-08-06. Target release: 0.8.0.

## Problem

Closing the MacBook lid ends running Claude Code sessions. `caffeinate` and
`IOPMAssertion` only block *idle* sleep; a lid close fires an explicit sleep the
kernel honours regardless of any assertion. The single lever that works is the
undocumented `pmset disablesleep` setting (it does not appear in `man pmset`),
and it requires root.

So this feature is not "which API do we call". It is "how does an unprivileged
menu-bar app get root, safely, and give it back reliably".

## Goals

- A toggle in the dropdown that lets a Claude Code session survive a closed lid.
- Ship to every Homebrew cask user, not just power users.
- A stranger's Mac must never be left permanently unable to sleep, including
  after a crash, force-quit, or hard reboot.

## Non-goals

- Clamshell mode with an external display and AC power. macOS already does this
  natively, no hack needed.
- Preventing display sleep, scheduled wake, or any other power behaviour.
- Detecting Claude Code specifically. The app reasons about system wake
  assertions in general.

## Key constraint

`SleepDisabled` persists across app quit, crash, and reboot. It lives in the
power-management preferences, not in the app's process. Whatever sets it must be
able to unset it *without user cooperation*, and unsetting also needs root.
Any mechanism that can only reach root interactively cannot self-heal, which
rules out `do shell script ... with administrator privileges`.

## Architecture

```
┌─ ClaudeUsageCore ─────────────┐  ┌─ SleepLease ─────────────────┐
│  pure, unit-tested            │  │  SPM target, no dependencies │
│  SleepPolicy.swift            │  │  Lease.swift                 │
│  WakeAssertions.swift         │  │  expiry arithmetic           │
└───────────────────────────────┘  └──────────────────────────────┘
              ▲                            ▲            ▲
              │                            │            │
┌─ Claude Usage.app (user) ─────┴────────────┴──┐       │
│  SleepGuard.swift       15s tick: evaluate    │       │
│                         policy, renew lease   │       │
│  PrivilegedClient.swift SMAppService + XPC    │       │
│  KeepAwakeRow.swift     dropdown toggle       │       │
└───────────────────────────────────────────────┘       │
              │ NSXPCConnection                         │
              │ setSleepDisabled(Bool, ttl: 90)         │
              ▼                                         │
┌─ claude-usage-sleeperd (root, new target) ─────────────┴──────┐
│  ~120 lines, links SleepLease only, never ClaudeUsageCore     │
│  NSXPCListener on com.sven.claude-usage.sleeperd              │
│  setCodeSigningRequirement() gates every connection           │
│  lease expiry: /usr/bin/pmset -a disablesleep 0               │
│  RunAtLoad: restore sleep if the marker says we own it        │
└───────────────────────────────────────────────────────────────┘
```

Every decision is a pure function in Core, so the guardrails are table-testable
without putting a Mac in a backpack. The root component makes no decisions at
all: it accepts a boolean and a TTL, and the only thing it can do is invoke
`/usr/bin/pmset` with `disablesleep 0` or `disablesleep 1`. That is the entire
privileged surface.

Reading power state does not need root and does not go through the daemon. The
app uses `IOPMCopyAssertionsStatus` to count `PreventUserIdleSystemSleep`
holders and `IOPMCopySystemPowerSettings()` to read the current `SleepDisabled`
value, rather than shelling out and parsing `pmset -g` text.

### Why a thin daemon and a lease

`setSleepDisabled(true, ttl: 90)` means "keep sleep disabled for 90 seconds,
then put it back". A single 15 second timer in the app both evaluates policy and
renews the lease, so a 90 second TTL tolerates five missed renewals before sleep
comes back. One timer rather than two keeps the state machine small.

Nothing has to *detect* a crash. If the app stops talking, the lease
runs out. Force-quit, kernel panic, logout, and `kill -9` all resolve through
the same path, so crash safety is a structural property rather than a code path
someone has to remember to write.

The lease arithmetic lives in `SleepLease`, its own SPM target with no
dependencies, because it is the one piece of logic both the app and the daemon
need. Linking the full `ClaudeUsageCore` into a root process would drag the
usage client, networking, and keychain code into the privileged binary and
undo the "auditable in one sitting" property. `SleepLease` is a few dozen lines
of date arithmetic and is unit-tested like the rest of Core.

A fat daemon owning the timers and polling was considered and rejected. Its only
advantage is that the feature keeps working after the user quits the app, which
is not wanted: a quit menu-bar app should not keep your Mac awake. The cost
would be tripling the amount of code running as root and losing the ability to
unit-test policy in Core.

## Policy engine

```swift
struct SleepWorld {
    let now, enabledAt: Date
    let cap: TimeInterval        // 1h / 4h / 8h, default 4h
    let lastAssertionAt: Date    // seeded to enabledAt on enable
    let batteryPercent: Int
    let onACPower: Bool
}

enum SleepDecision: Equatable {
    case keepAwake
    case restore(Reason)
}

enum Reason: Equatable { case lowBattery, capReached, noActiveWork }
```

Evaluated every 15 seconds. Checked in this precedence order so the notification
reports the most serious cause:

| Reason | Condition |
| --- | --- |
| `.lowBattery` | `!onACPower && batteryPercent <= 20` |
| `.capReached` | `now - enabledAt >= cap` |
| `.noActiveWork` | `now - lastAssertionAt >= 120` |

`lastAssertionAt` is seeded to `enabledAt`, so the two-minute grace clock never
fires immediately just because Claude Code happens to be between turns. On AC
power the battery check is skipped entirely, since the machine is charging.

### Known limitation of the assertion check

`PreventUserIdleSystemSleep` is held by plenty of things that are not Claude:
Docker, an active download, Music, a video call. On a busy machine that
assertion is up more or less permanently, so `.noActiveWork` will rarely be the
reason that fires and the 4 hour cap becomes the real backstop.

One holder is filtered out explicitly. `powerd` takes a
`PreventUserIdleSystemSleep` assertion named "Powerd - Prevent sleep while
display is on" for as long as the display is lit, which was confirmed live
during implementation. That is a restatement of "the display is on" rather than
a signal that work is running, and counting it would have kept the idle
guardrail permanently satisfied whenever the lid was open. It is absent once the
lid is shut, so filtering it makes the guardrail behave identically in both lid
states instead of only working in the closed-lid case.

The check is still worth keeping because it works well on a quiet machine, which
is the common case for "I closed the laptop and walked away". But the cap is
what the safety argument actually rests on, and it is therefore not
user-settable to "unlimited".

To make this visible rather than mysterious, the app calls
`IOPMCopyAssertionsByProcess` and shows which processes are holding the machine
awake.

## Privileged helper

### Bundle layout

```
Claude Usage.app/Contents/
  MacOS/Claude Usage
  MacOS/claude-usage-sleeperd
  Library/LaunchDaemons/com.sven.claude-usage.sleeperd.plist
```

### Daemon plist

| Key | Value |
| --- | --- |
| `Label` | `com.sven.claude-usage.sleeperd` |
| `BundleProgram` | `Contents/MacOS/claude-usage-sleeperd` |
| `MachServices` | `com.sven.claude-usage.sleeperd` = true |
| `RunAtLoad` | true |
| `AssociatedBundleIdentifiers` | `com.sven.claude-usage` |

`AssociatedBundleIdentifiers` makes System Settings show "Claude Usage" instead
of a raw label in Login Items and Extensions.

`RunAtLoad` is what gives boot-time self-heal. The daemon stays resident rather
than exiting when idle: it is a sleeping runloop with negligible cost, and
exiting introduces races with in-flight XPC connections for no real benefit.

### XPC interface

```swift
@objc protocol SleeperProtocol {
    func setSleepDisabled(_ disabled: Bool, ttl: Int,
                          reply: @escaping (Bool, String?) -> Void)
    func status(reply: @escaping (Bool, Int) -> Void)   // disabled, secondsLeft
}
```

### Connection authorisation

Without this, any local process could disable sleep. In
`listener(_:shouldAcceptNewConnection:)`:

```swift
newConnection.setCodeSigningRequirement(
  """
  anchor apple generic and identifier "com.sven.claude-usage" \
  and certificate leaf[subject.OU] = "H9PBNT2Q88"
  """)
```

`NSXPCConnection.setCodeSigningRequirement(_:)` is public API from macOS 13,
which matches the deployment target exactly. It avoids the older pattern of
reaching for the private `auditToken` property or racing on
`processIdentifier`.

### Ownership marker

`/Library/Application Support/com.sven.claude-usage/lease.json`, root-owned,
mode 0600:

```json
{ "ownedByUs": true, "preexisting": false, "setAt": 1785000000 }
```

Written before setting `disablesleep 1`, removed after restoring to 0. Two cases
it handles:

- **Boot after a hard crash.** On `RunAtLoad` the daemon reads the marker. If it
  exists, it runs `pmset -a disablesleep 0` and removes it. If it does not
  exist, it does nothing.
- **A user who set `disablesleep 1` themselves.** On enable, the daemon reads
  the current value first. If it is already 1 and there is no marker, it records
  `preexisting: true` and never restores to 0, so we do not stomp a setting we
  did not make.

### Sleeping the machine on a guardrail restore

Setting `disablesleep` back to 0 while the lid is already shut may not sleep the
machine on its own. The behaviour is undocumented and could plausibly wait for
the next lid event, which would make every guardrail useless in exactly the
situation they exist for. Rather than depend on it, the daemon makes it
explicit.

The daemon reads `AppleClamshellState` from `IOPMrootDomain` (unprivileged, via
`ioreg`, but the daemon is already root):

- **Guardrail restore with the lid closed:** set `disablesleep 0`, then call
  `IOPMSleepSystem` to sleep the machine immediately.
- **Guardrail restore with the lid open:** set `disablesleep 0` only. Normal
  idle policy takes over. Never force sleep on a machine someone is using.
- **User toggled off:** set `disablesleep 0` only, regardless of lid state.

This is why the battery argument holds: the machine sleeps roughly two minutes
after the last session ends, not at the cap.

### Verify after write

`disablesleep` is undocumented and could change behaviour in a future macOS. The
daemon reads the value back after every write. If the read-back does not match,
it reports failure to the app, which turns the toggle off and surfaces the error
rather than claiming a protection it does not have.

## Registration flow

1. First toggle press shows an explainer sheet: what it changes, that macOS will
   ask for approval, the backpack and battery caveats, and the list of
   conditions that auto-restore sleep. No system prompt happens before this.
2. `SMAppService.daemon(plistName: "com.sven.claude-usage.sleeperd.plist").register()`
3. macOS presents an admin authorisation prompt. Status may land on
   `.requiresApproval`, in which case the app calls
   `SMAppService.openSystemSettingsLoginItems()` and shows inline guidance.
4. Poll `service.status` until `.enabled`, then connect and enable.

`register()` fails with `.notFound` when the app is not in a stable location.
The cask installs to `/Applications`, so this is fine for users, but a debug
build run from DerivedData cannot register. Development requires a signed copy
in `/Applications`. This goes in the build notes.

## User interface

### Dropdown row

New `KeepAwakeRow.swift`, placed between the limit cards and the divider.
`MenuBarView.swift` already holds three view types at 245 lines, so the toggle
gets its own file rather than making it four.

```
Off        🌙 Keep awake with lid closed          [ ○ ]
           Your Mac sleeps normally when you close the lid.

Active     🌙 Keep awake with lid closed          [ ● ]
           Awake for claude, caffeinate · 3h 12m left · 64%

Grace      🌙 Keep awake with lid closed          [ ● ]
           Nothing running, sleeping in 1m 40s

Setup      🌙 Keep awake with lid closed      [Set up…]
           Needs a one-time admin approval.

Error      🌙 Keep awake with lid closed          [ ○ ]
           Could not change the sleep setting. See Settings.
```

### Menu bar indicator

When active, a small moon glyph is drawn before the progress bar in the menu bar
label. Not configurable. The consequence of this feature is invisible, and
"my Mac silently stopped sleeping" is exactly the confusion worth a few pixels.

### Settings

A new Sleep section containing the cap picker (1h / 4h / 8h), a "Remove helper"
button, and the risk text.

### Notifications

Fired on every auto-restore, reusing the existing notification plumbing from
0.7.2 and 0.7.3:

- "Sleep re-enabled, no active sessions"
- "Sleep re-enabled, 4 hour limit reached"
- "Sleep re-enabled, battery below 20%"

Silent state changes to something this consequential produce bug reports.

## Removal

- **Settings, "Remove helper":** restore sleep, then
  `SMAppService.daemon(...).unregister()`.
- **Cask:** add `uninstall launchctl: "com.sven.claude-usage.sleeperd"` to
  `homebrew/claude-usage.rb`. macOS also disables bundle-registered daemons
  automatically once the app bundle is deleted.
- **Marker file:** the daemon removes it whenever it restores sleep, so the
  normal path leaves only an empty directory behind. Deleting
  `/Library/Application Support/com.sven.claude-usage` needs root, so the README
  uninstall section gets a `sudo rm -rf` line alongside the existing
  `security delete-generic-password` line.

## Testing

### Unit tests

In `ClaudeUsageCore`:

- `SleepPolicyTests`: table-driven over `decide`. Each reason in isolation,
  precedence between reasons, the `enabledAt` seeding case, battery ignored on
  AC, boundary values at exactly 20% and exactly the cap.
- `WakeAssertionsTests`: fake `WakeAssertions` conformer, covering zero holders,
  multiple holders, and process-name extraction.
In `SleepLease`:

- `LeaseTests`: expiry arithmetic, renewal extending the deadline, expiry across
  a clock jump.

### Manual test matrix

The privileged and lid-dependent paths cannot be unit tested. Each of these is
run against a signed build in `/Applications` before release:

1. Enable, then confirm `pmset -g | grep SleepDisabled` reports 1.
2. Close the lid for 5 minutes with a long-running command writing timestamps to
   a file. Confirm no gap in the output.
3. `kill -9` the app while enabled. Confirm `SleepDisabled` returns to 0 within
   90 seconds.
4. Set the cap to 1 minute via a debug override. Confirm expiry restores sleep
   and posts the notification.
5. Unplug and drive the battery below 20%. Confirm restore and notification.
6. Reboot with the marker file present. Confirm the daemon restores sleep at
   boot.
7. Toggle off. Confirm `SleepDisabled` is 0 and the marker is gone.
8. Remove helper. Confirm the daemon is gone from System Settings.
9. Connect to the Mach service from an unsigned binary. Confirm rejection.
10. With the lid closed and the feature on, trigger a guardrail restore.
    Confirm the machine actually sleeps within seconds rather than waiting for
    a lid event. This is the assumption the whole battery argument rests on.
11. With the lid open, trigger a guardrail restore. Confirm the machine does
    *not* sleep.

## Risks

| Risk | Mitigation |
| --- | --- |
| Awake Mac in a closed bag, thermal and battery drain | 4h cap, 20% battery floor, assertion check, explicit sleep on guardrail restore, notifications. On a 64 Wh M4 Air the floor binds before the cap under heavy load (~2.5h at 20 W) and the cap binds under light load (~25% of the battery over 4h at 4 W). Worst case is a Mac at 20%, not a dead one. The Air is fanless and thermally self-limiting, so the realistic outcome is drain rather than damage. |
| `disablesleep` changes or disappears in a future macOS | Read back after every write, fail loudly, turn the toggle off. |
| Notarisation of a bundled daemon | The daemon is a separate target signed with the same Developer ID and hardened runtime. Notarisation covers the whole bundle. Verify with `spctl -a -vvv` before tagging. |
| A root daemon on every user's machine | It accepts one operation, validates the caller's code signature, and can only run `pmset` with two fixed argument sets. Reviewable in one sitting. |

## Open items for implementation

None blocking. The cap default (4h) and the grace period (120s) are the two
numbers most likely to want tuning after real use.
