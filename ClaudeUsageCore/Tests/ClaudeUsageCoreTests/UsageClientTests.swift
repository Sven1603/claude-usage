import XCTest
@testable import ClaudeUsageCore

/// Records the request and returns a canned response.
/// `@unchecked Sendable`: mutated only from single-threaded test bodies.
private final class StubFetcher: DataFetching, @unchecked Sendable {
    var lastRequest: URLRequest?
    var status: Int
    var body: Data
    init(status: Int, body: Data) { self.status = status; self.body = body }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        return (body, resp)
    }
}

/// Returns per-path canned (status, body) responses so multi-request flows
/// like `resolve(...)` can be exercised.
private final class RoutingStubFetcher: DataFetching, @unchecked Sendable {
    /// Maps a URL path to the response to return for it.
    var routes: [String: (status: Int, body: Data)]
    init(routes: [String: (status: Int, body: Data)]) { self.routes = routes }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let route = routes[path] ?? (status: 404, body: Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                   httpVersion: nil, headerFields: nil)!
        return (route.body, resp)
    }
}

final class UsageClientTests: XCTestCase {
    func test_sendsSessionKeyCookieAndUserAgent() async throws {
        let body = Data(#"{"limits":[{"kind":"session","percent":92,"resets_at":"2026-06-19T12:20:00Z"}]}"#.utf8)
        let stub = StubFetcher(status: 200, body: body)
        let client = UsageClient(fetcher: stub)
        _ = try await client.fetchUsage(orgUUID: "org-1", sessionKey: "SECRET")
        let cookie = stub.lastRequest?.value(forHTTPHeaderField: "Cookie")
        XCTAssertEqual(cookie, "sessionKey=SECRET")
        XCTAssertNotNil(stub.lastRequest?.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(stub.lastRequest?.url?.path, "/api/organizations/org-1/usage")
    }

    func test_401MapsToAuthError() async {
        let stub = StubFetcher(status: 401, body: Data("nope".utf8))
        let client = UsageClient(fetcher: stub)
        do {
            _ = try await client.fetchUsage(orgUUID: "org-1", sessionKey: "SECRET")
            XCTFail("expected auth error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .auth)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_500MapsToNetworkError() async {
        let stub = StubFetcher(status: 500, body: Data("boom".utf8))
        let client = UsageClient(fetcher: stub)
        do {
            _ = try await client.fetchUsage(orgUUID: "org-1", sessionKey: "SECRET")
            XCTFail("expected network error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .network)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_malformedJSONMapsToDecodingError() async {
        let stub = StubFetcher(status: 200, body: Data("{ not json".utf8))
        let client = UsageClient(fetcher: stub)
        do {
            _ = try await client.fetchUsage(orgUUID: "org-1", sessionKey: "SECRET")
            XCTFail("expected decoding error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .decoding)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Auto-detect: org list succeeds, but the per-org usage fetch returns 401.
    /// The 401 must surface as .auth, not be swallowed into .noActiveOrg.
    func test_resolveAutoDetectPropagatesAuthFromUsageFetch() async {
        let orgsBody = Data(#"[{"uuid":"org-1","name":"Acme"}]"#.utf8)
        let stub = RoutingStubFetcher(routes: [
            "/api/organizations": (status: 200, body: orgsBody),
            "/api/organizations/org-1/usage": (status: 401, body: Data("nope".utf8)),
        ])
        let client = UsageClient(fetcher: stub)
        do {
            _ = try await client.resolve(sessionKey: "SECRET", pinnedOrg: nil, now: Date())
            XCTFail("expected auth error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .auth)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
