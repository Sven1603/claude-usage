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
