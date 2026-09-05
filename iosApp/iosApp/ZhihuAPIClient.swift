import Foundation

extension Error {
    var isNativeRequestCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError { return urlError.code == .cancelled }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    var isNativeConnectivityFailure: Bool {
        guard !isNativeRequestCancellation else { return false }
        let code: URLError.Code
        if let error = self as? URLError {
            code = error.code
        } else {
            let error = self as NSError
            guard error.domain == NSURLErrorDomain else { return false }
            code = URLError.Code(rawValue: error.code)
        }
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

enum ZhihuRequestAuthentication: Sendable {
    case guest
    case accountIfAvailable
    case accountRequired
}

enum ZhihuAPIError: LocalizedError, Equatable {
    case untrustedURL
    case accountUnavailable
    case accountChanged
    case authenticationRequired
    case invalidResponse
    case httpStatus(Int)
    case malformedPayload
    case cachedResponseUnavailable
    case cacheWriteFailed

    var errorDescription: String? {
        switch self {
        case .untrustedURL:
            return "请求地址不受信任"
        case .accountUnavailable:
            return "账号信息读取失败，请重新登录后重试"
        case .accountChanged:
            return "当前账号已变化，请重新操作"
        case .authenticationRequired:
            return "请登录或重新登录后重试"
        case .invalidResponse:
            return "服务器返回了无效响应"
        case let .httpStatus(status):
            return "请求失败（HTTP \(status)）"
        case .malformedPayload:
            return "内容格式无法识别"
        case .cachedResponseUnavailable:
            return "这项内容尚未准备到离线缓存中"
        case .cacheWriteFailed:
            return "离线内容写入失败，请检查可用存储空间后重试"
        }
    }
}

enum ZhihuAPIURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty })
        else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }

    static func allowsAPIRequest(_ url: URL) -> Bool {
        guard allows(url), let host = url.host?.lowercased() else { return false }
        let path = url.path
        switch host {
        case "zhihu.com", "www.zhihu.com":
            return matches(path, root: "/api") || path == "/lastread/touch"
        case "api.zhihu.com":
            return [
                "/collections",
                "/content",
                "/images",
                "/moments",
                "/moments_v3",
                "/notifications",
                "/people",
                "/questions",
                "/read_history",
                "/search_v3",
                "/topstory",
                "/unify-consumption",
            ].contains { matches(path, root: $0) }
        case "daily.zhihu.com", "news-at.zhihu.com":
            return matches(path, root: "/api")
        default:
            return false
        }
    }

    static func allowsCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "zhihu.com" || normalized.hasSuffix(".zhihu.com")
    }

    private static func matches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }

    static func validatedPagingURL(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZhihuAPIError.untrustedURL
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let upgraded = components.url, allowsAPIRequest(upgraded) else {
            throw ZhihuAPIError.untrustedURL
        }
        return upgraded
    }
}

actor ZhihuAPIClient {
    static let defaultUserAgent =
        "Mozilla/5.0 (X11; U; Linux x86_64; en-US) AppleWebKit/540.0 (KHTML, like Gecko) Ubuntu/10.10 Chrome/9.1.0.0 Safari/540.0"

    private let accountStore: AccountJSONStore
    private let session: URLSession
    private let signer: ZhihuRequestSigning
    private let diagnostics: PerformanceDiagnosticsClient
    private let responseCache: any ZhihuAPIResponseCaching

    init(
        accountStore: AccountJSONStore,
        session: URLSession? = nil,
        signer: ZhihuRequestSigning = ZhihuRequestSigner(),
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        responseCache: any ZhihuAPIResponseCaching = FileZhihuAPIResponseCache()
    ) {
        self.accountStore = accountStore
        self.session = session ?? Self.makeSession()
        self.signer = signer
        self.diagnostics = diagnostics
        self.responseCache = responseCache
    }

    func data(
        for url: URL,
        method: String = "GET",
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        authentication: ZhihuRequestAuthentication = .accountIfAvailable,
        cachePolicy: ZhihuAPICachePolicy = .disabled,
        cacheValidation: (@Sendable (Data) throws -> Void)? = nil,
        expectedAccountID: String? = nil
    ) async throws -> Data {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let endpoint = PerformanceDiagnosticEndpoint(url: url)
        var statusCode: Int?
        var cacheRequest: ZhihuAPIResponseCacheRequest?
        var cacheGeneration: UInt64?
        var accountSnapshot = RequestAccountSnapshot.untracked
        do {
            guard ZhihuAPIURLPolicy.allowsAPIRequest(url) else { throw ZhihuAPIError.untrustedURL }
            let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            accountSnapshot = try requestAccountSnapshot(authentication: authentication)
            try validateExpectedAccountID(
                expectedAccountID,
                accountSnapshot: accountSnapshot
            )
            let credentials = try credentials(
                authentication: authentication,
                accountSnapshot: accountSnapshot
            )
            try validateAccountSnapshot(accountSnapshot)
            cacheRequest = makeCacheRequest(
                policy: cachePolicy,
                method: normalizedMethod,
                url: url,
                accountSnapshot: accountSnapshot
            )
            if let cacheRequest {
                cacheGeneration = await responseCache.generation(
                    forAccountID: cacheRequest.accountID
                )
                try validateAccountSnapshot(accountSnapshot)
            }
            try Task.checkCancellation()
            if case .offlinePackWarm = cachePolicy, cacheRequest == nil {
                throw ZhihuAPIError.cacheWriteFailed
            }
            switch cachePolicy {
            case .cacheFirst, .cacheOnly:
                if let cacheRequest,
                   let cached = await validatedCachedResponse(
                       for: cacheRequest,
                       validation: cacheValidation
                   ) {
                    try Task.checkCancellation()
                    try validateAccountSnapshot(accountSnapshot)
                    diagnostics.record(.init(
                        durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                        category: "network",
                        operation: "zhihu_api_request",
                        result: .success,
                        endpoint: endpoint,
                        responseBytes: cached.count,
                        cacheSource: "offline_response"
                    ))
                    return cached
                }
                if case .cacheOnly = cachePolicy {
                    throw ZhihuAPIError.cachedResponseUnavailable
                }
            case .disabled, .offlineFallback, .offlinePackWarm:
                break
            }
            var request = URLRequest(url: url)
            request.httpMethod = normalizedMethod
            request.httpBody = body
            additionalHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")

            if !credentials.cookies.isEmpty {
                request.setValue(
                    credentials.cookies.keys.sorted().map { "\($0)=\(credentials.cookies[$0] ?? "")" }.joined(separator: "; "),
                    forHTTPHeaderField: "Cookie"
                )
            }
            if let xsrf = credentials.cookies["_xsrf"]?.nonBlank {
                request.setValue(xsrf, forHTTPHeaderField: "x-xsrftoken")
            }
            signer.applySignature(to: &request, cookies: credentials.cookies, body: body)
            try validateAccountSnapshot(accountSnapshot)
            try validateExpectedAccountID(
                expectedAccountID,
                accountSnapshot: accountSnapshot
            )

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url,
                  ZhihuAPIURLPolicy.allowsAPIRequest(finalURL)
            else { throw ZhihuAPIError.invalidResponse }
            statusCode = response.statusCode
            try validateAccountSnapshot(accountSnapshot)
            try validateExpectedAccountID(
                expectedAccountID,
                accountSnapshot: accountSnapshot
            )
            try persistResponseCookies(
                response,
                accountSnapshot: accountSnapshot,
                expectedCredentialIdentity: credentials.identity
            )
            try validateAccountSnapshot(accountSnapshot)
            guard (200..<300).contains(response.statusCode) else {
                throw ZhihuAPIError.httpStatus(response.statusCode)
            }
            if let cacheRequest,
               let cacheGeneration,
               finalURL == cacheRequest.url {
                try cacheValidation?(data)
                let stored = await responseCache.store(
                    data,
                    for: cacheRequest,
                    ifGenerationMatches: cacheGeneration
                )
                if case .offlinePackWarm = cachePolicy, !stored {
                    throw ZhihuAPIError.cacheWriteFailed
                }
                try validateAccountSnapshot(accountSnapshot)
            } else if case .offlinePackWarm = cachePolicy {
                throw ZhihuAPIError.cacheWriteFailed
            }
            try Task.checkCancellation()
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "network",
                operation: "zhihu_api_request",
                result: .success,
                endpoint: endpoint,
                httpStatus: response.statusCode,
                responseBytes: data.count
            ))
            return data
        } catch {
            let requestError = error
            if requestError.isNativeConnectivityFailure,
               cachePolicy.allowsConnectivityFallback,
               let cacheRequest {
                do {
                    try Task.checkCancellation()
                    try validateAccountSnapshot(accountSnapshot)
                    if let cached = await validatedCachedResponse(
                        for: cacheRequest,
                        validation: cacheValidation
                    ) {
                        try Task.checkCancellation()
                        try validateAccountSnapshot(accountSnapshot)
                        diagnostics.record(.init(
                            durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                            category: "network",
                            operation: "zhihu_api_request",
                            result: .success,
                            endpoint: endpoint,
                            responseBytes: cached.count,
                            cacheSource: "offline_response"
                        ))
                        return cached
                    }
                } catch {
                    recordFailure(
                        error,
                        startedAt: startedAt,
                        endpoint: endpoint,
                        statusCode: statusCode
                    )
                    throw error
                }
            }
            recordFailure(
                requestError,
                startedAt: startedAt,
                endpoint: endpoint,
                statusCode: statusCode
            )
            throw requestError
        }
    }

    func clearCachedResponses(forAccountID accountID: String) async throws {
        guard let normalizedAccountID = accountID.nonBlank else { return }
        try await responseCache.removeResponses(forAccountID: normalizedAccountID)
    }

    private func makeCacheRequest(
        policy: ZhihuAPICachePolicy,
        method: String,
        url: URL,
        accountSnapshot: RequestAccountSnapshot
    ) -> ZhihuAPIResponseCacheRequest? {
        switch policy {
        case .disabled:
            return nil
        case .offlineFallback, .cacheFirst, .cacheOnly, .offlinePackWarm:
            break
        }
        guard ZhihuAPIOfflineCacheEligibility.allows(method: method, url: url),
              let accountID = accountSnapshot.accountID
        else { return nil }
        return ZhihuAPIResponseCacheRequest(accountID: accountID, url: url)
    }

    private func requestAccountSnapshot(
        authentication: ZhihuRequestAuthentication
    ) throws -> RequestAccountSnapshot {
        if case .guest = authentication { return .untracked }
        guard let multipleAccountStore = accountStore as? MultipleAccountJSONStore else {
            return .untracked
        }
        do {
            let snapshot = try multipleAccountStore.currentAccountSnapshot()
            return .tracked(
                accountID: snapshot.accountID?.nonBlank,
                accountJSON: snapshot.accountJSON
            )
        } catch MultipleAccountStoreError.accountChanged {
            throw ZhihuAPIError.accountChanged
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private func validateAccountSnapshot(_ snapshot: RequestAccountSnapshot) throws {
        guard case let .tracked(expectedAccountID, _) = snapshot,
              let multipleAccountStore = accountStore as? MultipleAccountJSONStore
        else { return }
        do {
            guard try multipleAccountStore.currentAccountSnapshot().accountID?.nonBlank
                == expectedAccountID
            else {
                throw ZhihuAPIError.accountChanged
            }
        } catch MultipleAccountStoreError.accountChanged {
            throw ZhihuAPIError.accountChanged
        } catch let error as ZhihuAPIError {
            throw error
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private func validateExpectedAccountID(
        _ expectedAccountID: String?,
        accountSnapshot: RequestAccountSnapshot
    ) throws {
        guard let expectedAccountID else { return }
        guard let normalizedExpectedAccountID = expectedAccountID.nonBlank,
              accountSnapshot.accountID == normalizedExpectedAccountID
        else {
            throw ZhihuAPIError.accountChanged
        }
    }

    private func credentials(
        authentication: ZhihuRequestAuthentication,
        accountSnapshot: RequestAccountSnapshot
    ) throws -> Credentials {
        if case .guest = authentication {
            return Credentials(
                cookies: [:],
                userAgent: Self.defaultUserAgent,
                identity: nil
            )
        }
        do {
            let accountJSON: String?
            switch accountSnapshot {
            case .untracked:
                accountJSON = try accountStore.load()
            case let .tracked(_, snapshotAccountJSON):
                accountJSON = snapshotAccountJSON
            }
            guard let stored = try ZhihuAccountSessionCodec.credentials(from: accountJSON) else {
                if case .accountRequired = authentication { throw ZhihuAPIError.authenticationRequired }
                return Credentials(
                    cookies: [:],
                    userAgent: Self.defaultUserAgent,
                    identity: CredentialIdentity(nil)
                )
            }
            if case .accountRequired = authentication {
                guard stored.cookies["d_c0"]?.nonBlank != nil,
                      stored.cookies["z_c0"]?.nonBlank != nil
                else { throw ZhihuAPIError.authenticationRequired }
            }
            return Credentials(
                cookies: stored.cookies,
                userAgent: stored.userAgent?.nonBlank ?? Self.defaultUserAgent,
                identity: CredentialIdentity(stored)
            )
        } catch let error as ZhihuAPIError {
            throw error
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private func persistResponseCookies(
        _ response: HTTPURLResponse,
        accountSnapshot: RequestAccountSnapshot,
        expectedCredentialIdentity: CredentialIdentity?
    ) throws {
        guard let responseURL = response.url else { return }
        var headerFields: [String: String] = [:]
        response.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headerFields[key] = String(describing: value)
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: responseURL)
        guard !responseCookies.isEmpty else { return }

        let update: (String?) throws -> String? = { accountJSON in
            if let expectedCredentialIdentity {
                let currentCredentials = try ZhihuAccountSessionCodec.credentials(from: accountJSON)
                guard CredentialIdentity(currentCredentials) == expectedCredentialIdentity else {
                    throw ZhihuAPIError.accountChanged
                }
            }
            return try ZhihuAccountSessionCodec.merging(
                cookies: responseCookies,
                into: accountJSON
            )
        }

        do {
            switch accountSnapshot {
            case .untracked:
                try accountStore.update(update)
            case let .tracked(expectedAccountID, _):
                guard let multipleAccountStore = accountStore as? MultipleAccountJSONStore else {
                    throw ZhihuAPIError.accountChanged
                }
                try multipleAccountStore.updateCurrentAccount(
                    expectedAccountID: expectedAccountID,
                    update
                )
            }
        } catch MultipleAccountStoreError.accountChanged {
            throw ZhihuAPIError.accountChanged
        } catch let error as ZhihuAPIError {
            throw error
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private func recordFailure(
        _ error: Error,
        startedAt: TimeInterval,
        endpoint: PerformanceDiagnosticEndpoint?,
        statusCode: Int?
    ) {
        diagnostics.record(.init(
            durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
            category: "network",
            operation: "zhihu_api_request",
            result: error.isNativeRequestCancellation ? .cancelled : .failure,
            endpoint: endpoint,
            httpStatus: statusCode,
            errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
        ))
    }

    private func validatedCachedResponse(
        for request: ZhihuAPIResponseCacheRequest,
        validation: (@Sendable (Data) throws -> Void)?
    ) async -> Data? {
        guard let data = await responseCache.response(for: request) else { return nil }
        do {
            try validation?(data)
            return data
        } catch {
            try? await responseCache.removeResponse(for: request)
            return nil
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: ZhihuRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private struct Credentials {
        let cookies: [String: String]
        let userAgent: String
        let identity: CredentialIdentity?
    }

    private struct CredentialIdentity: Equatable {
        let deviceCookie: String?
        let loginCookie: String?

        init(_ credentials: ZhihuAccountCredentials?) {
            deviceCookie = credentials?.cookies["d_c0"]?.nonBlank
            loginCookie = credentials?.cookies["z_c0"]?.nonBlank
        }
    }

    private enum RequestAccountSnapshot: Sendable {
        case untracked
        case tracked(accountID: String?, accountJSON: String?)

        var accountID: String? {
            guard case let .tracked(accountID, _) = self else { return nil }
            return accountID
        }
    }
}

private final class ZhihuRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map { ZhihuAPIURLPolicy.allowsAPIRequest($0) } == true ? request : nil)
    }
}

struct ZhihuAccountCredentials: Equatable {
    let cookies: [String: String]
    let userAgent: String?
}

enum ZhihuAccountSessionCodec {
    static func credentials(from accountJSON: String?) throws -> ZhihuAccountCredentials? {
        guard let accountJSON, let data = accountJSON.data(using: .utf8) else { return nil }
        let stored = try JSONDecoder().decode(StoredAccountSession.self, from: data)
        return ZhihuAccountCredentials(cookies: stored.cookies, userAgent: stored.userAgent)
    }

    static func merging(cookies incoming: [HTTPCookie], into accountJSON: String?) throws -> String? {
        try updatingCookies(in: accountJSON) { cookies in
            for cookie in incoming where ZhihuAPIURLPolicy.allowsCookieDomain(cookie.domain) {
                if cookie.name == "z_c0", cookie.value.nonBlank == nil {
                    continue
                }
                if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= Date() }) == true {
                    cookies.removeValue(forKey: cookie.name)
                } else {
                    cookies[cookie.name] = cookie.value
                }
            }
        }
    }

    static func merging(cookieValues incoming: [String: String], into accountJSON: String?) throws -> String? {
        try updatingCookies(in: accountJSON) { cookies in
            for (name, value) in incoming where !name.isEmpty {
                if value.isEmpty {
                    cookies.removeValue(forKey: name)
                } else {
                    cookies[name] = value
                }
            }
        }
    }

    private static func updatingCookies(
        in accountJSON: String?,
        mutation: (inout [String: String]) -> Void
    ) throws -> String? {
        guard let accountJSON,
              let data = accountJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return accountJSON }

        var cookies = root["cookies"] as? [String: String] ?? [:]
        mutation(&cookies)
        root["cookies"] = cookies
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let updatedJSON = String(data: updated, encoding: .utf8) else {
            throw ZhihuAPIError.accountUnavailable
        }
        return updatedJSON
    }

    private struct StoredAccountSession: Decodable {
        let cookies: [String: String]
        let userAgent: String?
    }
}

enum ZhihuAccountCookieWriter {
    static func merge(cookies: [HTTPCookie], into store: AccountJSONStore) throws {
        try store.update { accountJSON in
            try ZhihuAccountSessionCodec.merging(cookies: cookies, into: accountJSON)
        }
    }

    static func merge(cookieValues: [String: String], into store: AccountJSONStore) throws {
        try store.update { accountJSON in
            try ZhihuAccountSessionCodec.merging(cookieValues: cookieValues, into: accountJSON)
        }
    }
}

extension ZhihuAPIClient {
    func recordReadHistory(contentToken: String, contentType: String) async {
        let allowedTypes = Set(["answer", "article", "question", "pin", "profile"])
        guard !contentToken.isEmpty, allowedTypes.contains(contentType) else { return }
        guard let url = URL(string: "https://www.zhihu.com/api/v4/read_history/add"),
              let body = try? JSONSerialization.data(
                withJSONObject: [
                    "content_token": contentToken,
                    "content_type": contentType,
                ],
                options: [.sortedKeys]
              )
        else { return }
        _ = try? await data(
            for: url,
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json"],
            authentication: .accountIfAvailable
        )
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
