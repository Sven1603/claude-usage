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

    func test_500MapsToHTTPError() async {
        let stub = StubFetcher(status: 500, body: Data("boom".utf8))
        let client = UsageClient(fetcher: stub)
        do {
            _ = try await client.fetchUsage(orgUUID: "org-1", sessionKey: "SECRET")
            XCTFail("expected network error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .http(500))
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

    func test_resolvePinnedReturnsLimits() async throws {
        let body = Data(#"""
        {"limits":[
          {"kind":"session","percent":50,"resets_at":"2026-06-19T13:00:00Z"},
          {"kind":"weekly_all","percent":20,"resets_at":"2026-06-20T13:00:00Z"}
        ]}
        """#.utf8)
        let stub = StubFetcher(status: 200, body: body)
        let client = UsageClient(fetcher: stub)
        let now = Date(timeIntervalSince1970: 1_781_870_400)
        let limits = try await client.resolve(sessionKey: "K", pinnedOrg: "org-1", now: now).limits
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all"])
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

    /// Pinned org whose plan has no session limit (weekly only): must resolve with
    /// the weekly limit as headline instead of throwing .decoding.
    func test_resolvePinnedWithoutSessionLimit() async throws {
        let body = Data(#"""
        {"five_hour":null,"limits":[
          {"kind":"weekly_all","percent":100,"resets_at":"2026-06-20T12:00:00Z"},
          {"kind":"weekly_scoped","percent":0,"resets_at":"2026-06-20T12:00:00Z"}
        ]}
        """#.utf8)
        let client = UsageClient(fetcher: StubFetcher(status: 200, body: body))
        let now = Date(timeIntervalSince1970: 1_781_870_400)
        let r = try await client.resolve(sessionKey: "K", pinnedOrg: "org-1", now: now)
        XCTAssertEqual(r.headline.kind, "weekly_all")
        XCTAssertEqual(r.headline.percent, 100)
        XCTAssertEqual(r.org.percent, 100)
        XCTAssertEqual(r.limits.count, 2)
    }

    /// Auto-detect must consider weekly-only orgs as candidates (not skip them).
    func test_resolveAutoDetectWithoutSessionLimit() async throws {
        let orgsBody = Data(#"[{"uuid":"org-1","name":"Max 20x"}]"#.utf8)
        let usage = Data(#"{"limits":[{"kind":"weekly_all","percent":42,"resets_at":"2026-06-20T12:00:00Z"}]}"#.utf8)
        let stub = RoutingStubFetcher(routes: [
            "/api/organizations": (status: 200, body: orgsBody),
            "/api/organizations/org-1/usage": (status: 200, body: usage),
        ])
        let now = Date(timeIntervalSince1970: 1_781_870_400)
        let r = try await UsageClient(fetcher: stub).resolve(sessionKey: "K", pinnedOrg: nil, now: now)
        XCTAssertEqual(r.org.name, "Max 20x")
        XCTAssertEqual(r.headline.percent, 42)
    }

    /// A response with no limits at all is still a decoding failure.
    func test_resolvePinnedWithNoLimitsThrows() async {
        let client = UsageClient(fetcher: StubFetcher(status: 200, body: Data("{}".utf8)))
        do {
            _ = try await client.resolve(sessionKey: "K", pinnedOrg: "org-1", now: Date())
            XCTFail("expected decoding error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .decoding)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Auto-detect prefers orgs that have a session limit over weekly-only orgs,
    /// so adding weekly-only support doesn't silently switch workspaces.
    func test_resolveAutoDetectPrefersOrgWithSessionLimit() async throws {
        let orgsBody = Data(#"[{"uuid":"team","name":"Team"},{"uuid":"me","name":"Personal"}]"#.utf8)
        let team = Data(#"{"limits":[{"kind":"weekly_all","percent":60,"resets_at":"2026-06-20T12:00:00Z"}]}"#.utf8)
        let me = Data(#"{"limits":[{"kind":"session","percent":10,"resets_at":"2026-06-19T13:00:00Z"}]}"#.utf8)
        let stub = RoutingStubFetcher(routes: [
            "/api/organizations": (status: 200, body: orgsBody),
            "/api/organizations/team/usage": (status: 200, body: team),
            "/api/organizations/me/usage": (status: 200, body: me),
        ])
        let now = Date(timeIntervalSince1970: 1_781_870_400)
        let r = try await UsageClient(fetcher: stub).resolve(sessionKey: "K", pinnedOrg: nil, now: now)
        XCTAssertEqual(r.org.uuid, "me")
        XCTAssertEqual(r.headline.kind, "session")
    }

    func test_403IsReportedWithItsStatus() async {
        let client = UsageClient(fetcher: StubFetcher(status: 403, body: Data("{}".utf8)))
        do {
            _ = try await client.fetchUsage(orgUUID: "o", sessionKey: "K")
            XCTFail("expected error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .http(403))
            XCTAssertTrue(describeFailure(e).contains("403"))
        } catch { XCTFail("wrong error type: \(error)") }
    }

    /// Real body from claude.ai for a revoked session (Nov 2026): 403, not 401.
    func test_403AccountSessionInvalidMapsToAuth() async {
        let body = Data(#"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization","details":{"error_code":"account_session_invalid","error_visibility":"user_facing"}},"request_id":"req_x"}"#.utf8)
        let client = UsageClient(fetcher: StubFetcher(status: 403, body: body))
        do {
            _ = try await client.fetchUsage(orgUUID: "o", sessionKey: "K")
            XCTFail("expected auth error")
        } catch let e as ClientError {
            XCTAssertEqual(e, .auth)
        } catch { XCTFail("wrong error type: \(error)") }
    }
}
