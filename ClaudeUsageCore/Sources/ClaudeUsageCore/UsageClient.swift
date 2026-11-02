import Foundation

public enum ClientError: Error, Equatable, Sendable {
    case auth        // 401 — session key bad/expired
    case network     // transport or non-2xx (non-401)
    case decoding    // bad JSON
    case noActiveOrg // auto-detect found nothing
}

/// Seam so tests can inject responses without real network.
public protocol DataFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default implementation using the shared URLSession.
public struct URLSessionFetcher: DataFetching, Sendable {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.network }
        return (data, http)
    }
}

public struct UsageClient: Sendable {
    public static let host = URL(string: "https://claude.ai")!
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    let fetcher: DataFetching
    public init(fetcher: DataFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    private func request(path: String, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: Self.host.appendingPathComponent(path))
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue(Self.host.absoluteString, forHTTPHeaderField: "Origin")
        req.setValue("\(Self.host.absoluteString)/settings/usage",
                     forHTTPHeaderField: "Referer")
        return req
    }

    private func getJSON<T: Decodable>(_ type: T.Type, path: String,
                                       sessionKey: String) async throws -> T {
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await fetcher.data(for: request(path: path, sessionKey: sessionKey)) }
        catch { throw ClientError.network }
        if http.statusCode == 401 { throw ClientError.auth }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.network }
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        do { return try d.decode(T.self, from: data) }
        catch { throw ClientError.decoding }
    }

    /// One usage fetch for a known org.
    public func fetchUsage(orgUUID: String, sessionKey: String) async throws -> UsageResponse {
        try await getJSON(UsageResponse.self,
                          path: "/api/organizations/\(orgUUID)/usage",
                          sessionKey: sessionKey)
    }

    /// List the accessible orgs.
    public func fetchOrgs(sessionKey: String) async throws -> [Org] {
        try await getJSON([Org].self, path: "/api/organizations", sessionKey: sessionKey)
    }

    /// Resolve org + headline limit + all parsed limits. Uses `pinnedOrg` if
    /// given, else auto-detects the active org. Limits come from the same
    /// response already fetched for the selected org. The headline is the session
    /// limit when the plan has one, otherwise the most-used weekly limit; only a
    /// response with no limits at all is an error.
    public func resolve(sessionKey: String, pinnedOrg: String?, now: Date)
        async throws -> ResolvedUsage {
        if let orgUUID = pinnedOrg, !orgUUID.isEmpty {
            let resp = try await fetchUsage(orgUUID: orgUUID, sessionKey: sessionKey)
            let limits = parseUsageLimits(resp, now: now)
            guard let h = headlineLimit(limits) else { throw ClientError.decoding }
            return ResolvedUsage(
                headline: h,
                org: OrgUsage(uuid: orgUUID, name: nil, percent: h.percent, secondsToReset: h.secondsToReset),
                limits: limits)
        }
        // `fetchOrgs` throws directly, so a 401 here already surfaces as .auth.
        let orgs = try await fetchOrgs(sessionKey: sessionKey)
        var candidates: [OrgUsage] = []
        var parsed: [String: (headline: UsageLimit, limits: [UsageLimit])] = [:]
        for org in orgs {
            let resp: UsageResponse
            do {
                resp = try await fetchUsage(orgUUID: org.uuid, sessionKey: sessionKey)
            } catch ClientError.auth {
                throw ClientError.auth
            } catch {
                continue
            }
            let limits = parseUsageLimits(resp, now: now)
            guard let h = headlineLimit(limits) else { continue }
            parsed[org.uuid] = (h, limits)
            candidates.append(OrgUsage(uuid: org.uuid, name: org.name,
                                       percent: h.percent, secondsToReset: h.secondsToReset))
        }
        // Prefer orgs whose plan has a session limit, so weekly-only orgs (now
        // parseable) don't outrank the org you're actively using on weekly %.
        let withSession = candidates.filter { parsed[$0.uuid]?.headline.kind == "session" }
        guard let best = pickBestOrg(withSession.isEmpty ? candidates : withSession),
              let p = parsed[best.uuid] else {
            throw ClientError.noActiveOrg
        }
        return ResolvedUsage(headline: p.headline, org: best, limits: p.limits)
    }
}

/// Result of `UsageClient.resolve`.
public struct ResolvedUsage: Equatable, Sendable {
    /// The limit the menu bar shows (session if present, else most-used).
    public let headline: UsageLimit
    public let org: OrgUsage
    public let limits: [UsageLimit]
    public init(headline: UsageLimit, org: OrgUsage, limits: [UsageLimit]) {
        self.headline = headline; self.org = org; self.limits = limits
    }
}
