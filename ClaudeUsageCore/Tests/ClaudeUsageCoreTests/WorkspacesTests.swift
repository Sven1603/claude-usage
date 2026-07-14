import XCTest
@testable import ClaudeUsageCore

final class WorkspacesTests: XCTestCase {
    // Real-shaped org list: Personal(Free, chat), Individual(API, no chat), Team(chat+raven).
    private let json = """
    [
      {"uuid":"p","name":"Personal","capabilities":["chat"],"billing_type":"none"},
      {"uuid":"i","name":"Individual","capabilities":["api","api_individual"],"billing_type":"api_evaluation"},
      {"uuid":"t","name":"ve2.agency B.V.","capabilities":["chat","raven"],"raven_type":"team","billing_type":"stripe_subscription"}
    ]
    """

    private func decodeOrgs() throws -> [Org] {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode([Org].self, from: Data(json.utf8))
    }

    func test_chatWorkspacesFiltersApiOrgAndLabels() throws {
        let ws = chatWorkspaces(from: try decodeOrgs())
        XCTAssertEqual(ws.map(\.id), ["p", "t"])              // API org "i" excluded
        XCTAssertEqual(ws.map(\.name), ["Personal", "ve2.agency B.V."])
        XCTAssertEqual(ws.map(\.planLabel), ["Free", "Team"])
    }

    func test_planLabelHeuristics() {
        func org(_ caps: [String], raven: String? = nil, billing: String? = nil) -> Org {
            let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
            let j = try! JSONSerialization.data(withJSONObject: [
                "uuid": "x", "name": "n", "capabilities": caps,
                "raven_type": raven as Any, "billing_type": billing as Any,
            ])
            return try! d.decode(Org.self, from: j)
        }
        XCTAssertEqual(planLabel(for: org(["chat","raven"], raven: "team")), "Team")
        XCTAssertEqual(planLabel(for: org(["chat","raven"])), "Max")
        XCTAssertEqual(planLabel(for: org(["chat"], billing: "none")), "Free")
        XCTAssertEqual(planLabel(for: org(["chat"], billing: "stripe_subscription")), "Pro")
        XCTAssertNil(planLabel(for: org(["api","api_individual"])))
    }
}
