import Foundation
import ServiceManagement

/// Bridges one XPC call onto one continuation.
///
/// Two things can answer a message sent over NSXPCConnection: the reply block, or
/// the proxy's error handler when the message could not be delivered or the
/// connection died with the message outstanding. Exactly one of them has to resume
/// the continuation — never resuming hangs the caller forever, and resuming twice
/// traps — and they arrive on arbitrary queues, so the hand-off needs a lock rather
/// than the `var resumed = false` a single-threaded reading would suggest.
private final class XPCReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// First caller wins; every later one is dropped.
    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

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
    static let unreachable = "Could not reach the sleep helper."

    private var currentConnection: NSXPCConnection?

    /// Static so the off-main-actor register path can build its own instance from
    /// the plist name rather than capturing one across an actor boundary.
    nonisolated private static var service: SMAppService { .daemon(plistName: plistName) }

    nonisolated private static func registration(for status: SMAppService.Status) -> Registration {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .failed("Helper missing from the app bundle.")
        @unknown default: return .failed("Unknown helper status.")
        }
    }

    var registration: Registration { Self.registration(for: Self.service.status) }

    /// Prompts for admin approval the first time. Safe to call when already
    /// registered.
    ///
    /// `SMAppService.register()` is a throwing, blocking call with no async
    /// variant, and it raises the system authorisation prompt. Run on the main
    /// actor it freezes the menu-bar popover until the user answers, so the
    /// blocking work happens off it and only the result hops back. `SMAppService`
    /// is not main-actor-bound, which is what makes that safe.
    func register() async -> Registration {
        guard Self.service.status != .enabled else { return .enabled }
        return await Task.detached {
            let service = Self.service
            do {
                try service.register()
            } catch {
                // SMAppService throws for states that are not failures. Already
                // registered throws, and so does registering again while the user
                // still has the approval pending — the likeliest first-run path,
                // because dismissing the Login Items prompt leaves the service at
                // `.requiresApproval` and the next press throws
                // kSMErrorAlreadyRegistered. Surfacing that error text would show
                // "Operation not permitted", which dead-ends, instead of the
                // actionable "approve it in Login Items".
                //
                // So map from the live status, and only trust the thrown error when
                // the status agrees nothing was registered.
                let status = service.status
                guard status == .notRegistered else { return Self.registration(for: status) }
                return .failed(error.localizedDescription)
            }
            return Self.registration(for: service.status)
        }.value
    }

    func unregister() async {
        currentConnection?.invalidate()
        currentConnection = nil
        try? await Self.service.unregister()
    }

    /// Drop and recreate the registration. Used when launchd reports the helper
    /// as enabled but refuses to spawn it: the launch constraint recorded at first
    /// registration pins the signature of the build that registered it, so after
    /// the app is re-signed (new certificate, local build) launchd exits it with
    /// EX_CONFIG forever. Re-registering records the current signature.
    func reRegister() async -> Registration {
        await unregister()
        return await register()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    /// The connection is kept between calls so renewals do not pay for a new one
    /// every 15s. It is dropped on invalidation or interruption, so the next call
    /// reconnects and relaunches the daemon on demand.
    private func connection() -> NSXPCConnection {
        if let currentConnection { return currentConnection }
        let c = NSXPCConnection(machServiceName: sleeperMachServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: SleeperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.forget(c) }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.forget(c) }
        }
        c.resume()
        currentConnection = c
        return c
    }

    /// Only clear the cache if it still holds the connection that died: the
    /// handlers hop to the main actor, so a stale one could otherwise land after a
    /// later call already replaced it.
    private func forget(_ dead: NSXPCConnection) {
        if currentConnection === dead { currentConnection = nil }
    }

    /// Sends one message, resolving to `fallback` if the message cannot be
    /// delivered at all. `send` receives the proxy and a gate that must be resumed
    /// from the reply block.
    private func call<Value>(
        fallback: @autoclosure @escaping () -> Value,
        _ send: (SleeperProtocol, XPCReplyGate<Value>) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let gate = XPCReplyGate(continuation)
            // A fresh error-handling proxy per message: the handler closes over
            // *this* call's gate, which is what makes a dead daemon an answer
            // instead of a hang.
            let proxy = connection().remoteObjectProxyWithErrorHandler { error in
                NSLog("claude-usage: XPC error: \(error.localizedDescription)")
                gate.resume(fallback())
            }
            guard let sleeper = proxy as? SleeperProtocol else {
                gate.resume(fallback())
                return
            }
            send(sleeper, gate)
        }
    }

    /// Returns nil on success, else a message to show the user.
    ///
    /// `sleepIfLidClosed` is required rather than defaulted even though it means
    /// nothing when `disabled` is true: it decides whether a closed-lid Mac is
    /// actually sent to sleep, and a call site that silently inherits a default for
    /// that is exactly the bug this parameter was added to fix.
    func setSleepDisabled(_ disabled: Bool, ttl: Int, sleepIfLidClosed: Bool) async -> String? {
        await call(fallback: Self.unreachable) { sleeper, gate in
            sleeper.setSleepDisabled(disabled, ttl: ttl,
                                     sleepIfLidClosed: sleepIfLidClosed) { ok, error in
                gate.resume(ok ? nil : (error ?? "Unknown helper error."))
            }
        }
    }

    /// The daemon's view of the world, or nil if it could not be reached.
    ///
    /// The two values answer different questions and can legitimately disagree:
    /// `disabled` is the live system setting, which is also true when the user set
    /// `disablesleep` themselves, while `secondsRemaining` is the daemon's own
    /// lease bookkeeping. Callers must not read ownership out of `disabled`.
    func status() async -> (disabled: Bool, secondsRemaining: Int)? {
        await call(fallback: nil) { sleeper, gate in
            sleeper.status { disabled, remaining in
                gate.resume((disabled: disabled, secondsRemaining: remaining))
            }
        }
    }
}
