import Foundation
import os
import SleepLease

private let log = Logger(subsystem: "com.sven.claude-usage.sleeperd", category: "MarkerStore")

/// Root-owned record of the fact that we disabled sleep, so a daemon started
/// after a crash or reboot knows to clean up.
enum MarkerStore {
    private static var url: URL { URL(fileURLWithPath: leaseMarkerPath) }

    static func read() -> LeaseMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LeaseMarker.decoded(from: data)
    }

    /// Writes the marker, returning false when the caller must not go on to disable
    /// sleep.
    ///
    /// Every failure here is reported rather than swallowed, because a disabled
    /// `SleepDisabled` with no marker on disk is the one unrecoverable state this
    /// design has: nothing would ever restore it, the setting survives reboot in
    /// `com.apple.PowerManagement.plist`, and the user is left with a Mac that
    /// never sleeps again.
    @discardableResult
    static func write(_ marker: LeaseMarker) -> Bool {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("""
                Could not create \(dir.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }

        // `attributes:` above applies only when createDirectory actually creates the
        // directory — verified: a pre-existing 0777 directory keeps 0777 and no error
        // is raised. Set the mode every time, because the directory being 0700 is
        // what makes the brief 0644 window on the file below harmless.
        //
        // This is defence in depth, not the security boundary: the marker's real
        // protection is that every component of /Library/Application Support is
        // root-owned and not group-writable, so no unprivileged process can
        // pre-create the directory, plant a symlink, or read the marker. A failed
        // mode fixup therefore does not fail the write.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            log.error("""
                Could not set mode 0700 on \(dir.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }

        let data: Data
        do {
            data = try marker.encoded()
        } catch {
            log.error("Could not encode lease marker: \(error.localizedDescription, privacy: .public)")
            return false
        }

        do {
            // Atomic: a daemon killed mid-write leaves either the old marker or the
            // new one, never a half-written file that would fail to decode and so
            // look like no lease was ever taken.
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("""
                Could not write \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }

        // The atomic write makes a fresh file at 0644, so the mode is set afterwards.
        // Only root needs to read this. Not fatal, per the note above.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("""
                Could not set mode 0600 on \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        return true
    }

    /// Removes the marker. A marker left behind is not dangerous — the next daemon
    /// start would restore sleep that is already restored — but it means the file is
    /// stuck, so it is worth a log line.
    static func clear() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // removeItem throws when the file is already absent, which is the
            // desired end state rather than a failure.
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            log.error("""
                Could not remove \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
