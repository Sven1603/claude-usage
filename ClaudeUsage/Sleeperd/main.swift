import Foundation

// RunAtLoad brings us up at boot. If a marker is on disk the app died while
// holding a lease, so restore normal sleep before doing anything else. This call
// is synchronous, so it is finished before the listener below can serve anything.
let service = SleeperService()
service.restoreIfOrphaned()

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
