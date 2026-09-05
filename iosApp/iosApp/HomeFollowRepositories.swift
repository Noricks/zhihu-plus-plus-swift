import Foundation

protocol FeedThumbnailPrefetching: Sendable {
    func prefetch(items: [FeedItemDTO]) async
}

struct DisabledFeedThumbnailPrefetcher: FeedThumbnailPrefetching {
    func prefetch(items _: [FeedItemDTO]) async {}
}

actor URLSessionFeedThumbnailPrefetcher: FeedThumbnailPrefetching {
    static let maximumItemCount = 8
    static let maximumURLCount = 12
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let session: URLSession
    private var completedURLs: Set<URL> = []
    private var completionOrder: [URL] = []
    private let maximumRememberedURLs = 192

    init(session: URLSession = .shared) {
        self.session = session
    }

    func prefetch(items: [FeedItemDTO]) async {
        let urls = Self.urls(from: items)
            .filter { !completedURLs.contains($0) }
        guard !urls.isEmpty else { return }

        await withTaskGroup(of: (URL, Bool).self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<min(3, urls.count) {
                if let url = iterator.next() {
                    group.addTask { [session] in
                        (url, await Self.fetch(url, session: session))
                    }
                }
            }
            while let (url, succeeded) = await group.next() {
                if succeeded { remember(url) }
                if let nextURL = iterator.next() {
                    group.addTask { [session] in
                        (nextURL, await Self.fetch(nextURL, session: session))
                    }
                }
            }
        }
    }

    static func urls(from items: [FeedItemDTO]) -> [URL] {
        var seen: Set<URL> = []
        return items.prefix(maximumItemCount)
            .flatMap { item in
                [item.thumbnailURL] + item.media.prefix(3).map { Optional($0.previewURL) }
            }
            .compactMap { $0 }
            .filter(allows)
            .filter { seen.insert($0).inserted }
            .prefix(maximumURLCount)
            .map { $0 }
    }

    private static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "zhimg.com" || host.hasSuffix(".zhimg.com")
            || host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Bool {
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 8
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= maximumResponseBytes,
                  response.value(forHTTPHeaderField: "Content-Type")?
                      .lowercased().hasPrefix("image/") == true
            else { return false }
            return true
        } catch {
            return false
        }
    }

    private func remember(_ url: URL) {
        guard completedURLs.insert(url).inserted else { return }
        completionOrder.append(url)
        if completionOrder.count > maximumRememberedURLs {
            let overflow = completionOrder.count - maximumRememberedURLs
            let removed = Array(completionOrder.prefix(overflow))
            completionOrder.removeFirst(overflow)
            removed.forEach { completedURLs.remove($0) }
        }
    }
}

protocol HomeFeedRepository: Sendable {
    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO
    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO
    func reportOpened(_ item: FeedItemDTO) async
}

extension HomeFeedRepository {
    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        try await fetchPage(after: nextURL)
    }
}

actor URLSessionHomeFeedRepository: HomeFeedRepository {
    private static let touchURL = URL(string: "https://www.zhihu.com/lastread/touch")!

    private let client: ZhihuAPIClient
    private let diagnostics: PerformanceDiagnosticsClient

    init(
        client: ZhihuAPIClient,
        diagnostics: PerformanceDiagnosticsClient = .disabled
    ) {
        self.client = client
        self.diagnostics = diagnostics
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        try await fetchPage(source: .app, after: nextURL)
    }

    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        let baseURL = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL)
            ?? HomeFollowRequestURL.recommendationInitialURL(for: source)
        let url = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: baseURL
        )
        let authentication: ZhihuRequestAuthentication = source == .web
            ? .accountRequired
            : .accountIfAvailable
        let data = try await client.data(for: url, authentication: authentication)
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let page = try FeedResponseMapper.page(from: data, policy: .search)
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "recommendation",
                operation: "response_map",
                result: .success,
                responseBytes: data.count,
                itemCount: page.items.count,
                pagingSource: nextURL == nil ? "initial" : "next",
                refreshSource: source.rawValue
            ))
            return page
        } catch {
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "recommendation",
                operation: "response_map",
                result: .failure,
                responseBytes: data.count,
                pagingSource: nextURL == nil ? "initial" : "next",
                refreshSource: source.rawValue,
                errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
            ))
            throw error
        }
    }

    func reportOpened(_ item: FeedItemDTO) async {
        guard item.kind == .answer || item.kind == .article || item.kind == .pin else { return }
        let payload = "[[\"\(item.kind.rawValue)\",\"\(item.id.contentID)\",\"read\"]]"
        let boundary = "ZhihuPlus-\(UUID().uuidString)"
        let body = Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"items\"\r\n\r\n\(payload)\r\n--\(boundary)--\r\n".utf8
        )
        _ = try? await client.data(
            for: Self.touchURL,
            method: "POST",
            body: body,
            additionalHeaders: [
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
                "x-requested-with": "fetch",
            ],
            authentication: .accountRequired
        )
    }
}

protocol FollowRepository: Sendable {
    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO
    func fetchRecentUsers() async throws -> [FollowingUserDTO]
}

actor URLSessionFollowRepository: FollowRepository {
    private static let recommendationURL = URL(string: "https://api.zhihu.com/moments_v3?feed_type=recommend&limit=20")!
    private static let momentsURL = URL(string: "https://www.zhihu.com/api/v3/moments?limit=20&desktop=true")!
    private static let recentURL = URL(string: "https://api.zhihu.com/moments/recent?type=raw")!

    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        let initial = section == .recommendations ? Self.recommendationURL : Self.momentsURL
        let baseURL = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL) ?? initial
        let url = try HomeFollowRequestURL.addingFeedParameters(to: baseURL)
        let data = try await client.data(for: url, authentication: .accountRequired)
        let endpointCategory: FeedResponseEndpointCategory = section == .recommendations
            ? .followRecommendations
            : .followMoments
        return try FeedResponseMapper.page(
            from: data,
            policy: .search,
            endpointCategory: endpointCategory
        )
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] {
        let data = try await client.data(for: Self.recentURL, authentication: .accountRequired)
        return try HomeFollowResponseMapper.followingUsers(from: data)
    }
}

enum HomeFollowRequestURL {
    private static let appRecommendationInitialURL = URL(
        string: "https://api.zhihu.com/topstory/recommend?limit=10"
    )!
    private static let webRecommendationInitialURL = URL(
        string: "https://www.zhihu.com/api/v3/feed/topstory/recommend"
            + "?desktop=true&limit=10&offset=0"
            + "&include=data[*].content,excerpt,headline,target.author.badge_v2,target.question.author"
    )!

    private static let include =
        "data[*].content,excerpt,headline,target.author.badge_v2,target.question.author"
    private static let standardPageSize = "20"
    private static let recommendationPageSize = String(
        HomeRecommendationRefreshConfiguration.requestLimit
    )

    static func recommendationInitialURL(
        for source: HomeRecommendationSource
    ) -> URL {
        switch source {
        case .app: return appRecommendationInitialURL
        case .web: return webRecommendationInitialURL
        }
    }

    static func addingRecommendationFeedParameters(to url: URL) throws -> URL {
        try addingFeedParameters(
            to: url,
            pageSize: recommendationPageSize
        )
    }

    static func addingFeedParameters(to url: URL) throws -> URL {
        try addingFeedParameters(to: url, pageSize: standardPageSize)
    }

    private static func addingFeedParameters(
        to url: URL,
        pageSize: String
    ) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZhihuAPIError.malformedPayload
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "include" }) {
            items.append(URLQueryItem(name: "include", value: include))
        }
        var replacedLimit = false
        items = items.compactMap { item in
            guard item.name == "limit" else { return item }
            guard !replacedLimit else { return nil }
            replacedLimit = true
            return URLQueryItem(name: "limit", value: pageSize)
        }
        if !replacedLimit {
            items.append(URLQueryItem(name: "limit", value: pageSize))
        }
        components.queryItems = items
        guard let result = components.url else { throw ZhihuAPIError.malformedPayload }
        return result
    }
}

enum HomeFollowResponseMapper {
    static func followingUsers(from data: Data) throws -> [FollowingUserDTO] {
        let root = try jsonObject(data)
        return (root["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let actor = item["actor"] as? [String: Any],
                  let id = (actor["id"] as? String)?.nonBlank,
                  let token = (actor["url_token"] as? String ?? actor["urlToken"] as? String)?.nonBlank,
                  let name = (actor["name"] as? String)?.nonBlank
            else { return nil }
            return FollowingUserDTO(
                id: id,
                urlToken: token,
                displayName: name,
                avatarURL: (actor["avatar_url"] as? String ?? actor["avatarUrl"] as? String).flatMap(httpsURL),
                unreadCount: max(0, item["unread_count"] as? Int ?? item["unreadCount"] as? Int ?? 0)
            )
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZhihuAPIError.malformedPayload
        }
        return root
    }
}

private func httpsURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
