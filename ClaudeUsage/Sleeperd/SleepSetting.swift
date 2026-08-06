import Foundation

/// Reads and writes the undocumented `SleepDisabled` power setting.
///
/// Writing needs root, so this only ever runs inside the daemon. Every write is
/// read back: the setting is undocumented and could change behaviour in a future
/// macOS, and silently believing we disabled sleep would be worse than failing.
enum SleepSetting {
    /// Current value, read from `IOPMrootDomain` rather than by parsing `pmset -g`
    /// text.
    ///
    /// `IOPMCopySystemPowerSettings` would be the direct call, but it is exported
    /// without being declared in any public SDK header, so reaching it from Swift
    /// would mean redeclaring a private symbol inside a root binary. The registry
    /// property is public API and is the live kernel state rather than a copy of
    /// the preference, which is exactly what a read-back wants to check.
    /// The property is absent on hardware that cannot disable sleep, which reads
    /// as not disabled.
    static func isDisabled() -> Bool {
        PowerRootDomain.flag("SleepDisabled") ?? false
    }

    /// Sets the value and verifies it took. Returns nil on success, else a message.
    static func set(disabled: Bool) -> String? {
        let process = Process()
        // Absolute path, no shell, and both arguments are literals: nothing a
        // caller passes can influence what runs.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
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
        // Drain before waiting: reading returns at EOF, which pmset reaches when it
        // exits, so a full pipe buffer cannot deadlock the daemon.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "pmset exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")"
        }

        // One read, so the reported value is the one that was actually checked.
        let actual = isDisabled()
        guard actual == disabled else {
            return "pmset reported success but SleepDisabled is still \(actual ? 1 : 0)"
        }
        return nil
    }
}
