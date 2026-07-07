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

    /// Resolve org + session usage. Uses `pinnedOrg` if given, else auto-detects
    /// the active org (mirrors `get_usage` + `pick_org_uuid`).
    public func resolve(sessionKey: String, pinnedOrg: String?, now: Date)
        async throws -> (session: SessionUsage, org: OrgUsage) {
        if let orgUUID = pinnedOrg, !orgUUID.isEmpty {
            let resp = try await fetchUsage(orgUUID: orgUUID, sessionKey: sessionKey)
            guard let s = parseSessionUsage(resp, now: now) else { throw ClientError.decoding }
            return (s, OrgUsage(uuid: orgUUID, name: nil,
                                percent: s.percent, secondsToReset: s.secondsToReset))
        }
        // `fetchOrgs` throws directly, so a 401 here already surfaces as .auth.
        let orgs = try await fetchOrgs(sessionKey: sessionKey)
        var candidates: [OrgUsage] = []
        for org in orgs {
            let resp: UsageResponse
            do {
                resp = try await fetchUsage(orgUUID: org.uuid, sessionKey: sessionKey)
            } catch ClientError.auth {
                // A bad/expired session key affects every org — surface it rather
                // than degrading to .noActiveOrg. Other per-org errors (e.g. 403
                // on inaccessible orgs) are still skipped below.
                throw ClientError.auth
            } catch {
                continue
            }
            guard let s = parseSessionUsage(resp, now: now) else { continue }
            candidates.append(OrgUsage(uuid: org.uuid, name: org.name,
                                       percent: s.percent, secondsToReset: s.secondsToReset))
        }
        guard let best = pickBestOrg(candidates) else { throw ClientError.noActiveOrg }
        return (SessionUsage(percent: best.percent, secondsToReset: best.secondsToReset), best)
    }
}
