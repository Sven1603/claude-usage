import Foundation

/// A time-limited grant to keep the system awake.
///
/// The app renews the lease on a timer while its toggle is on. If the app stops
/// renewing for any reason — crash, force-quit, logout, kernel panic — the lease
/// lapses and the daemon restores normal sleep. Crash safety is therefore a
/// structural property rather than a cleanup path someone has to remember.
public struct Lease: Equatable, Sendable {
    public let expiresAt: Date

    // Leases are created through `starting` and renewed through `renewed` so every
    // expiry is derived from a real clock reading; the memberwise initializer stays
    // internal so no caller can mint a lease with an arbitrary deadline.
    init(expiresAt: Date) { self.expiresAt = expiresAt }

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
