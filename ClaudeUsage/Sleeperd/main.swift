import Foundation

// RunAtLoad brings us up at boot. If a marker is on disk the app died while
// holding a lease, so restore normal sleep before doing anything else. This call
// is synchronous, so it is finished before the listener below can serve anything.
let service = SleeperService()
service.restoreIfOrphaned()

// Every orderly teardown arrives as SIGTERM, and the default disposition would
// kill us with sleep still disabled and no timer left to put it back — see
// `restoreOnTeardown`. SIG_IGN is what lets the dispatch source below see the
// signal instead of the process dying; a DispatchSourceSignal alone does not
// suppress the default action. Installed before the listener, so no connection can
// ever be served by a process that would die with a lease held. A SIGTERM in the
// window above this line still terminates outright, which is safe: the only thing
// before it is `restoreIfOrphaned`, and we have disabled nothing ourselves yet.
//
// The source is held in a global for the same reason as `delegate` below: a
// deallocated DispatchSourceSignal stops delivering, and with SIG_IGN in place that
// would leave a daemon that ignores SIGTERM entirely.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    // Synchronous: `exit(0)` must not run until pmset has been read back. The main
    // queue is drained by the run loop below, and `restoreOnTeardown` hops onto the
    // service's own serial queue, so this cannot interleave with an XPC call.
    service.restoreOnTeardown()
    exit(0)
}
sigterm.resume()

// Checked before it is handed to XPC: a malformed requirement raises an
// uncatchable Objective-C exception, and a root daemon that crashes on every
// connection attempt is worse than one that refuses to serve and says so.
let requirementIsUsable = validateClientRequirement()

// Held in a global on purpose: NSXPCListener.delegate is weak, so a delegate in a
// narrower scope would be deallocated and every connection silently rejected.
let delegate = SleeperListenerDelegate(service: service,
                                       requirementIsUsable: requirementIsUsable)

let listener = NSXPCListener(machServiceName: sleeperMachServiceName)
if requirementIsUsable {
    // The whole security boundary. Applied to the listener rather than to each
    // connection, so a peer that is not the correctly-signed app is rejected before
    // the delegate is consulted and never has our exported object attached. Must be
    // set before the listener is resumed.
    listener.setConnectionCodeSigningRequirement(sleeperClientRequirement)
}
listener.delegate = delegate
listener.resume()

// Stay resident rather than exiting when idle: a sleeping run loop costs
// nothing, and exiting races in-flight XPC connections for no real benefit.
RunLoop.main.run()
