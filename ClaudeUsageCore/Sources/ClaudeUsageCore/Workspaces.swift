import Foundation

/// A claude.ai chat workspace (org) shown in the switcher.
public struct Workspace: Equatable, Sendable, Identifiable {
    public let id: String        // org uuid
    public let name: String
    public let planLabel: String?
    public init(id: String, name: String, planLabel: String?) {
        self.id = id; self.name = name; self.planLabel = planLabel
    }
}

/// Best-effort plan label from the org's fields. nil when undeterminable.
public func planLabel(for org: Org) -> String? {
    let caps = org.capabilities ?? []
    if org.ravenType == "team" { return "Team" }
    if caps.contains("raven") { return "Max" }
    if caps.contains("chat") { return org.billingType == "none" ? "Free" : "Pro" }
    return nil
}

/// The claude.ai chat workspaces (orgs with the `chat` capability), in API order.
/// API/console-only orgs are excluded.
public func chatWorkspaces(from orgs: [Org]) -> [Workspace] {
    orgs.filter { ($0.capabilities ?? []).contains("chat") }
        .map { Workspace(id: $0.uuid,
                         name: $0.name ?? String($0.uuid.prefix(8)),
                         planLabel: planLabel(for: $0)) }
}
