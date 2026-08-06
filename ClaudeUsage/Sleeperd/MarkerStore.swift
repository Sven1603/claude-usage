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
        // Atomic: a daemon killed mid-write leaves either the old marker or the new
        // one, never a half-written file that would fail to decode and so look like
        // no lease was ever taken.
        try? data.write(to: url, options: .atomic)
        // The atomic write makes a fresh file, so the mode is set afterwards. Only
        // root needs to read this.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
