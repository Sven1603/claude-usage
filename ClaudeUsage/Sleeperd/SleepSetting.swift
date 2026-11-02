import Foundation
import os

private let log = Logger(subsystem: "com.sven.claude-usage.sleeperd", category: "SleepSetting")

/// How long to wait for `pmset` before killing it. The caller runs `set` on the
/// same serial queue that expires the lease, so an unbounded wait here would stop
/// the lease from ever lapsing — the one guarantee the whole feature rests on.
private let pmsetTimeout: TimeInterval = 5

/// How long the read-back tolerates the setting not having propagated yet, and how
/// often it looks in the meantime.
private let readBackTimeout: TimeInterval = 0.2
private let readBackInterval: TimeInterval = 0.025

/// Records that the watchdog, not something else, killed `pmset`. Written on a
/// global queue and read on the caller's queue, so it is lock-guarded.
private final class TimeoutFlag {
    private let lock = NSLock()
    private var fired = false

    func mark() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

/// Reads and writes the undocumented `SleepDisabled` power setting.
///
/// Writing needs root, so this only ever runs inside the daemon. Every write is
/// read back: the setting is undocumented and could change behaviour in a future
/// macOS, and silently believing we disabled sleep would be worse than failing.
///
/// `set(disabled:)` below is the only place the privileged binary spawns a
/// subprocess. Nothing else in the daemon execs anything.
enum SleepSetting {
    /// Current value, read from `IOPMrootDomain` rather than by parsing `pmset -g`
    /// text.
    ///
    /// `IOPMCopySystemPowerSettings` would be the direct call, but it is exported
    /// without being declared in any public SDK header, so reaching it from Swift
    /// would mean redeclaring a private symbol inside a root binary. The registry
    /// property is public API and reflects the kernel's own state rather than a copy
    /// of the preference, which is what a read-back wants. It is not guaranteed to
    /// update synchronously with the `pmset` call that causes it, which is why
    /// `set(disabled:)` gives it a moment to settle instead of trusting one read.
    /// The property is absent on hardware that cannot disable sleep, which reads as
    /// not disabled.
    static func isDisabled() -> Bool {
        PowerRootDomain.flag("SleepDisabled") ?? false
    }

    /// Waits briefly for `SleepDisabled` to reach `want`, and returns the last value
    /// seen either way.
    ///
    /// A single immediate read would let a propagation delay masquerade as a real
    /// failure. That fails safe when disabling, but not when restoring: the caller
    /// returns before clearing the marker and before the lid-closed guardrail sleep,
    /// so a manufactured mismatch would skip the very safety net it exists for.
    /// Bounded so a genuine failure is still reported promptly, and so this cannot
    /// hold the caller's serial queue for long.
    private static func settle(to want: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(readBackTimeout)
        var actual = isDisabled()
        while actual != want, Date() < deadline {
            Thread.sleep(forTimeInterval: readBackInterval)
            actual = isDisabled()
        }
        return actual
    }

    /// Sets the value and verifies it took. Returns nil on success, else a message.
    static func set(disabled: Bool) -> String? {
        let process = Process()
        // Absolute path, no shell, and both arguments are literals: nothing a
        // caller passes can influence what runs. The empty environment is not
        // load-bearing today — pmset reads nothing from it — but it makes "nothing
        // external influences this exec" true by construction rather than something
        // an auditor has to derive from launchd's environment and SIP.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.environment = [:]
        // pmset prints its diagnostics to stdout, not stderr — verified: a failing
        // `pmset` exits nonzero with "Error: ..." on stdout and stderr empty. Both
        // streams go to one pipe so the reason reaches the user either way, and so
        // neither stream is left unread and able to fill up.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return "Could not run pmset: \(error.localizedDescription)"
        }

        // The watchdog has to cover the read as well as the wait: a wedged pmset
        // holds the pipe open, so readDataToEndOfFile is what would block first.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.mark()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + pmsetTimeout, execute: watchdog)

        // Drain before waiting: reading returns at EOF, which pmset reaches when it
        // exits, so a full pipe buffer cannot deadlock the daemon.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.didFire {
            log.error("pmset did not finish within \(pmsetTimeout, privacy: .public)s; terminated")
            return "pmset did not finish within \(Int(pmsetTimeout))s and was terminated"
        }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = text.isEmpty ? "" : ": \(text)"

        guard process.terminationStatus == 0 else {
            // Do not assume a failed pmset changed nothing. The caller treats any
            // message as failure, so it has to be told which kind of failure this is
            // or it will restore state it never actually changed — or leave changed
            // state alone.
            let actual = settle(to: disabled)
            let status = process.terminationStatus
            if actual == disabled {
                log.error("""
                    pmset exited \(status, privacy: .public) but SleepDisabled reached \
                    \(actual ? 1 : 0, privacy: .public) anyway
                    """)
                return "pmset exited \(status) but SleepDisabled is now "
                    + "\(actual ? 1 : 0) anyway\(detail)"
            }
            log.error("pmset exited \(status, privacy: .public); SleepDisabled unchanged")
            return "pmset exited \(status), SleepDisabled unchanged at \(actual ? 1 : 0)\(detail)"
        }

        // One settled read, so the reported value is the one that was checked.
        let actual = settle(to: disabled)
        guard actual == disabled else {
            log.error("""
                pmset reported success but SleepDisabled is \(actual ? 1 : 0, privacy: .public) \
                after \(readBackTimeout, privacy: .public)s
                """)
            return "pmset reported success but SleepDisabled is still \(actual ? 1 : 0)"
        }
        return nil
    }
}
