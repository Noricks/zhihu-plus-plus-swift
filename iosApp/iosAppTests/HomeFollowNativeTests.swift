import Foundation
import XCTest
@testable import iosApp

final class FeedChannelRefreshMetadataTests: XCTestCase {
    func testOneHourPolicyRefreshesAtThresholdSinceLastView() {
        let lastViewed = Date(timeIntervalSince1970: 1_000)
        let metadata = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: nil,
            lastViewedAt: lastViewed
        )

        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: metadata,
            now: lastViewed.addingTimeInterval(60 * 60 - 1)
        ))
        XCTAssertTrue(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: metadata,
            now: lastViewed.addingTimeInterval(60 * 60)
        ))
        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: .empty,
            now: lastViewed.addingTimeInterval(60 * 60 + 1)
        ))
        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: FeedChannelRefreshMetadata(
                lastSuccessfulRefreshAt: lastViewed.addingTimeInterval(60 * 60 + 1),
                lastViewedAt: lastViewed
            ),
            now: lastViewed.addingTimeInterval(60 * 60 + 2)
        ))
    }

    func testUserDefaultsPersistenceUsesStableIndependentChannelKeys() throws {
        let suite = "FeedChannelRefreshMetadataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsFeedChannelRefreshMetadataPersistence(defaults: defaults)
        let recommendations = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 10),
            lastViewedAt: Date(timeIntervalSince1970: 20)
        )
        let hot = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 30),
            lastViewedAt: Date(timeIntervalSince1970: 40)
        )

        persistence.save(recommendations, for: .recommendations)
        persistence.save(hot, for: .hot)

        XCTAssertEqual(persistence.load(for: .recommendations), recommendations)
        XCTAssertEqual(persistence.load(for: .hot), hot)
        XCTAssertEqual(persistence.load(for: .following), .empty)
        XCTAssertEqual(persistence.load(for: .daily), .empty)
        XCTAssertNotNil(defaults.data(
            forKey: "\(UserDefaultsFeedChannelRefreshMetadataPersistence.keyPrefix).recommendations"
        ))
    }
}

final class HomeFollowMapperTests: XCTestCase {
    func testFeedMapperKeepsAuthorSourceThumbnailAndTypedAnswerRoute() throws {
        let data = Data(
            #"{"data":[{"detail_text":"关注的人赞同了","target":{"id":42,"type":"answer","excerpt":"摘要","voteup_count":10,"comment_count":2,"thumbnail":"https://pic.zhimg.com/a.jpg","question":{"id":7,"title":"问题"},"author":{"id":"member","url_token":"writer","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"}}}],"paging":{"is_end":false,"next":"http://www.zhihu.com/api/v3/next"}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.first?.route, .answer(answerID: 42, questionID: 7, questionTitle: "问题"))
        XCTAssertEqual(page.items.first?.author?.displayName, "作者")
        XCTAssertEqual(page.items.first?.sourceLabel, "关注的人赞同了")
        XCTAssertEqual(page.items.first?.thumbnailURL, URL(string: "https://pic.zhimg.com/a.jpg"))
        XCTAssertEqual(page.nextURL, URL(string: "https://www.zhihu.com/api/v3/next"))
    }

    func testFeedMapperIgnoresStringAuthorWithoutDroppingItem() throws {
        let data = Data(
            #"{"data":[{"target":{"id":"81","type":"article","title":"字符串作者文章","excerpt":"摘要","author":"匿名用户"}}],"paging":{"is_end":true,"next":null}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.route, .article(articleID: 81, title: "字符串作者文章"))
        XCTAssertNil(page.items.first?.author)
    }

    func testFeedMapperKeepsMixedObjectAndStringAuthorPage() throws {
        let data = Data(
            #"{"data":[{"target":{"id":"81","type":"article","title":"对象作者文章","author":{"id":"member","url_token":"writer","name":"对象作者","headline":"简介"}}},{"target":{"id":"82","type":"article","title":"字符串作者文章","author":"匿名用户"}}],"paging":{"is_end":true,"next":null}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.map(\.route), [
            .article(articleID: 81, title: "对象作者文章"),
            .article(articleID: 82, title: "字符串作者文章"),
        ])
        XCTAssertEqual(page.items.first?.author?.displayName, "对象作者")
        XCTAssertNil(page.items.last?.author)
    }

    func testFeedMapperFiltersPromotionExtraWithoutAffectingPaging() throws {
        let data = Data(
            #"{"data":[{"promotion_extra":"{\"is_card\":true,\"adsource\":\"zhi_plus\"}","target":{"id":"81","type":"article","title":"推广文章"}},{"target":{"id":"82","type":"article","title":"普通文章"}}],"paging":{"is_end":false,"next":"https://www.zhihu.com/api/v3/feed/topstory/recommend?offset=10&limit=10"}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.map(\.route), [
            .article(articleID: 82, title: "普通文章"),
        ])
        XCTAssertEqual(
            page.nextURL,
            URL(string: "https://www.zhihu.com/api/v3/feed/topstory/recommend?offset=10&limit=10")
        )
        XCTAssertFalse(page.isEnd)
    }

    func testFeedMapperFiltersAppAdvertisementMarkers() throws {
        let data = Data(
            #"{"data":[{"type":"feed_advert","ad":{"creatives":[{"title":"广告"}]}},{"type":"feed","ad_info":[{"id":"ad"}],"target":{"id":"81","type":"article","title":"广告文章"}},{"type":"feed","monitor_urls":["https://monitor.example"],"target":{"id":"82","type":"article","title":"监测文章"}},{"type":"feed","ad_info":[],"monitor_urls":[],"target":{"id":"83","type":"article","title":"普通文章"}}],"paging":{"is_end":true,"next":null}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.map(\.route), [
            .article(articleID: 83, title: "普通文章"),
        ])
    }

    func testFeedMapperRejectsUntrustedPagingURL() throws {
        let data = Data(#"{"data":[],"paging":{"is_end":false,"next":"https://evil.example/steal"}}"#.utf8)
        XCTAssertThrowsError(try FeedResponseMapper.page(from: data, policy: .search))
    }

    func testRecommendationRequestUsesWebFirstPageContractAndPreservesContinuationParameters() throws {
        let firstPage = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: HomeFollowRequestURL.recommendationInitialURL(for: .web)
        )
        let continuation = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: URL(
                string: "https://www.zhihu.com/api/v3/feed/topstory/recommend"
                    + "?offset=40&cursor=next-token&limit=20"
                    + "&session_token=opaque&limit=10"
            )!
        )
        let firstItems = try XCTUnwrap(
            URLComponents(url: firstPage, resolvingAgainstBaseURL: false)?.queryItems
        )
        let continuationItems = try XCTUnwrap(
            URLComponents(url: continuation, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(firstPage.host, "www.zhihu.com")
        XCTAssertEqual(firstPage.path, "/api/v3/feed/topstory/recommend")
        XCTAssertEqual(firstItems.map(\.name), ["desktop", "limit", "offset", "include"])
        XCTAssertEqual(firstItems.first(where: { $0.name == "desktop" })?.value, "true")
        XCTAssertEqual(firstItems.first(where: { $0.name == "offset" })?.value, "0")
        XCTAssertEqual(firstItems.filter { $0.name == "limit" }.map(\.value), ["10"])
        XCTAssertEqual(
            firstItems.first(where: { $0.name == "include" })?.value,
            "data[*].content,excerpt,headline,target.author.badge_v2,target.question.author"
        )
        XCTAssertEqual(continuationItems.filter { $0.name == "limit" }.map(\.value), ["10"])
        XCTAssertEqual(continuationItems.first(where: { $0.name == "offset" })?.value, "40")
        XCTAssertEqual(
            continuationItems.first(where: { $0.name == "cursor" })?.value,
            "next-token"
        )
        XCTAssertEqual(
            continuationItems.first(where: { $0.name == "session_token" })?.value,
            "opaque"
        )
        XCTAssertEqual(continuationItems.filter { $0.name == "include" }.count, 1)
    }

    func testRecommendationRequestUsesAppFirstPageContractWithTenItemLimit() throws {
        let firstPage = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: HomeFollowRequestURL.recommendationInitialURL(for: .app)
        )
        let items = try XCTUnwrap(
            URLComponents(url: firstPage, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(firstPage.host, "api.zhihu.com")
        XCTAssertEqual(firstPage.path, "/topstory/recommend")
        XCTAssertEqual(items.filter { $0.name == "limit" }.map(\.value), ["10"])
        XCTAssertEqual(items.filter { $0.name == "include" }.count, 1)
    }

    func testFollowRequestKeepsExistingQueryAndAddsPagingParametersOnce() throws {
        let source = URL(string: "https://api.zhihu.com/moments_v3?feed_type=recommend&limit=10")!
        let first = try HomeFollowRequestURL.addingFeedParameters(to: source)
        let second = try HomeFollowRequestURL.addingFeedParameters(to: first)
        let items = try XCTUnwrap(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(items.first(where: { $0.name == "feed_type" })?.value, "recommend")
        XCTAssertEqual(items.filter { $0.name == "include" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "limit" }.count, 1)
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "20")
    }

    func testRecentUserCarriesUnreadAndPersonActivitiesTab() throws {
        let data = Data(
            #"{"data":[{"actor":{"id":"member","url_token":"writer","name":"作者","avatar_url":"https://pic.zhimg.com/a.jpg"},"unread_count":3}]}"#.utf8
        )

        let user = try XCTUnwrap(HomeFollowResponseMapper.followingUsers(from: data).first)

        XCTAssertEqual(user.unreadCount, 3)
        XCTAssertEqual(user.personRoute?.initialTab, .activities)
        XCTAssertEqual(user.personRoute?.lookupKey, .memberID("member"))
    }

}

@MainActor
final class HomeFollowStoreTests: XCTestCase {
    func testQuestionAuthorFilteringDoesNotStopStorePagination() async {
        let blockedAuthor = FeedAuthorDTO(
            memberID: "blocked",
            urlToken: "blocked",
            displayName: "已屏蔽提问者",
            avatarURL: nil,
            headline: ""
        )
        let nextURL = URL(string: "https://www.zhihu.com/api/v3/next")!
        let blocked = feedItem(1, questionAuthor: blockedAuthor)
        let visible = feedItem(2)
        let store = HomeFeedNativeStore(repository: HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [blocked], nextURL: nextURL, isEnd: false)),
            .success(FeedPageDTO(items: [visible], nextURL: nil, isEnd: true)),
        ]))

        await store.loadInitialIfNeeded()

        XCTAssertTrue(FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: ["blocked"]
        ).isEmpty)
        XCTAssertTrue(store.hasNextPage)

        await store.loadMore()

        XCTAssertEqual(
            FeedQuestionAuthorVisibilityPolicy.visibleItems(
                from: store.items,
                blockedMemberIDs: ["blocked"]
            ),
            [visible]
        )
        XCTAssertFalse(store.hasNextPage)
    }

    func testHomePrefetchesNextPageWithinFiveItemsOfEndAndPreservesOrder() async {
        let nextURL = URL(string: "https://www.zhihu.com/api/v3/next")!
        let initialItems = (1 ... 10).map { feedItem(Int64($0)) }
        let repository = CacheHomeRepositoryStub(pages: [
            FeedPageDTO(items: initialItems, nextURL: nextURL, isEnd: false),
            FeedPageDTO(
                items: [feedItem(10), feedItem(11), feedItem(12)],
                nextURL: nil,
                isEnd: true
            ),
        ])
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        await store.prefetchNextPageIfNeeded(after: feedItem(5).id)
        let requestsBeforeThreshold = await repository.requestCount()
        XCTAssertEqual(requestsBeforeThreshold, 1)
        XCTAssertEqual(store.items, initialItems)

        await store.prefetchNextPageIfNeeded(after: feedItem(6).id)
        let requestsAfterThreshold = await repository.requestCount()
        XCTAssertEqual(requestsAfterThreshold, 2)
        XCTAssertEqual(store.items, initialItems + [feedItem(11), feedItem(12)])
        XCTAssertFalse(store.hasNextPage)
    }

    func testHomeConcurrentPrefetchTriggersOnlyOnePaginationRequest() async {
        let nextURL = URL(string: "https://www.zhihu.com/api/v3/next")!
        let initial = feedItem(1)
        let paginated = feedItem(2)
        let repository = HomePaginationRefreshRepositoryStub(
            initial: FeedPageDTO(items: [initial], nextURL: nextURL, isEnd: false),
            paginated: FeedPageDTO(items: [paginated], nextURL: nil, isEnd: true),
            refreshed: FeedPageDTO(items: [], nextURL: nil, isEnd: true)
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let firstPrefetch = Task {
            await store.prefetchNextPageIfNeeded(after: initial.id)
        }
        await repository.waitUntilPaginationStarts()
        await store.prefetchNextPageIfNeeded(after: initial.id)

        let requestsWhilePrefetching = await repository.requestedURLs()
        XCTAssertEqual(requestsWhilePrefetching, [nil, nextURL])

        await repository.resumePagination()
        await firstPrefetch.value
        XCTAssertEqual(store.items, [initial, paginated])
    }

    func testHomeRecordsOnlySuccessfulFirstPageAndPersistsLastViewed() async {
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let clock = FeedRefreshTestClock(initialDate)
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let first = feedItem(1)
        let second = feedItem(2)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .success(FeedPageDTO(items: [second], nextURL: nil, isEnd: true)),
            .failure(HomeFollowTestError.network),
        ])
        let store = HomeFeedNativeStore(
            repository: repository,
            refreshMetadataPersistence: persistence,
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(10)
        await store.loadMore()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(20)
        await store.refresh()
        XCTAssertEqual(store.items, [first, second])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        let viewedAt = initialDate.addingTimeInterval(30)
        store.recordLastViewed(at: viewedAt)
        XCTAssertEqual(store.refreshMetadata.lastViewedAt, viewedAt)
        XCTAssertFalse(store.needsRefreshAfterIdle(at: viewedAt.addingTimeInterval(60 * 60 - 1)))
        XCTAssertTrue(store.needsRefreshAfterIdle(at: viewedAt.addingTimeInterval(60 * 60)))

        let restored = HomeFeedNativeStore(
            repository: HomeRepositoryStub(results: []),
            refreshMetadataPersistence: persistence
        )
        XCTAssertEqual(restored.refreshMetadata, store.refreshMetadata)
    }

    func testHomeAccountChangeClearsContentAndAllowsAuthenticatedReload() async {
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let store = HomeFeedNativeStore(
            repository: HomeRepositoryStub(results: [
                .success(.init(items: [feedItem(1)], nextURL: nil, isEnd: true)),
                .success(.init(items: [feedItem(2)], nextURL: nil, isEnd: true)),
            ]),
            refreshMetadataPersistence: persistence
        )
        await store.loadInitialIfNeeded()

        store.accountDidChange()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.refreshMetadata, .empty)
        XCTAssertEqual(persistence.load(for: .recommendations), .empty)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.items, [feedItem(2)])
    }

    func testHomeColdLaunchRestoresSuccessfulSnapshotWithoutNetworkRequest() async {
        let cache = InMemoryHomeRecommendationCachePersistence()
        let nextURL = URL(string: "https://api.zhihu.com/topstory/recommend?offset=10")!
        let firstRepository = CacheHomeRepositoryStub(pages: [
            FeedPageDTO(items: [feedItem(1)], nextURL: nextURL, isEnd: false),
        ])
        let firstStore = HomeFeedNativeStore(
            repository: firstRepository,
            cachePersistence: cache,
            cacheAccountID: { "account-a" }
        )
        await firstStore.loadInitialIfNeeded()

        let restoredRepository = CacheHomeRepositoryStub(pages: [])
        let restoredStore = HomeFeedNativeStore(
            repository: restoredRepository,
            cachePersistence: cache,
            cacheAccountID: { "account-a" }
        )
        await restoredStore.loadInitialIfNeeded()

        XCTAssertEqual(restoredStore.items, [feedItem(1)])
        XCTAssertTrue(restoredStore.hasNextPage)
        XCTAssertEqual(restoredStore.nextPageLoadID, nextURL.absoluteString)
        let restoredRequestCount = await restoredRepository.requestCount()
        XCTAssertEqual(restoredRequestCount, 0)
    }

    func testHomeCachedSnapshotRefreshesAtExactOneHourIdleBoundary() async {
        let cache = InMemoryHomeRecommendationCachePersistence()
        let successfulAt = Date(timeIntervalSince1970: 1_000)
        let viewedAt = successfulAt.addingTimeInterval(10)
        let clock = FeedRefreshTestClock(successfulAt)
        let firstStore = HomeFeedNativeStore(
            repository: CacheHomeRepositoryStub(pages: [
                FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
            ]),
            cachePersistence: cache,
            cacheAccountID: { "account-a" },
            now: { clock.now }
        )
        await firstStore.loadInitialIfNeeded()
        firstStore.recordLastViewed(at: viewedAt)

        clock.now = viewedAt.addingTimeInterval(60 * 60 - 1)
        let beforeBoundaryRepository = CacheHomeRepositoryStub(pages: [])
        let beforeBoundaryStore = HomeFeedNativeStore(
            repository: beforeBoundaryRepository,
            cachePersistence: cache,
            cacheAccountID: { "account-a" },
            now: { clock.now }
        )
        await beforeBoundaryStore.loadInitialIfNeeded()

        XCTAssertEqual(beforeBoundaryStore.items, [feedItem(1)])
        let beforeBoundaryRequestCount = await beforeBoundaryRepository.requestCount()
        XCTAssertEqual(beforeBoundaryRequestCount, 0)

        clock.now = viewedAt.addingTimeInterval(60 * 60)
        let boundaryRepository = CacheHomeRepositoryStub(pages: [
            FeedPageDTO(items: [feedItem(2)], nextURL: nil, isEnd: true),
        ])
        let boundaryStore = HomeFeedNativeStore(
            repository: boundaryRepository,
            cachePersistence: cache,
            cacheAccountID: { "account-a" },
            now: { clock.now }
        )
        await boundaryStore.loadInitialIfNeeded()

        XCTAssertEqual(boundaryStore.items, [feedItem(2)])
        let boundaryRequestCount = await boundaryRepository.requestCount()
        XCTAssertEqual(boundaryRequestCount, 1)
    }

    func testHomeCacheSwitchesImmediatelyByAccountAndRecommendationSource() async throws {
        let cache = InMemoryHomeRecommendationCachePersistence()
        let now = Date(timeIntervalSince1970: 2_000)
        let appA = try XCTUnwrap(HomeRecommendationCacheContext(
            accountID: "account-a",
            source: .app
        ))
        let webA = try XCTUnwrap(HomeRecommendationCacheContext(
            accountID: "account-a",
            source: .web
        ))
        let webB = try XCTUnwrap(HomeRecommendationCacheContext(
            accountID: "account-b",
            source: .web
        ))
        cache.save(cacheSnapshot(
            context: appA,
            items: [feedItem(1)],
            now: now
        ), for: appA)
        cache.save(cacheSnapshot(
            context: webA,
            items: [feedItem(2)],
            now: now
        ), for: webA)
        cache.save(cacheSnapshot(
            context: webB,
            items: [feedItem(3)],
            now: now
        ), for: webB)

        var accountID: String? = "account-a"
        var configuration = HomeRecommendationRefreshConfiguration(
            source: .app,
            targetItemCount: 20
        )
        let repository = CacheHomeRepositoryStub(pages: [])
        let store = HomeFeedNativeStore(
            repository: repository,
            configuration: { configuration },
            cachePersistence: cache,
            cacheAccountID: { accountID },
            now: { now }
        )
        XCTAssertEqual(store.items, [feedItem(1)])

        configuration = HomeRecommendationRefreshConfiguration(
            source: .web,
            targetItemCount: 20
        )
        await store.recommendationSourceDidChange()
        XCTAssertEqual(store.items, [feedItem(2)])

        accountID = "account-b"
        store.accountDidChange()
        XCTAssertEqual(store.items, [feedItem(3)])

        accountID = nil
        store.accountDidChange()
        XCTAssertTrue(store.items.isEmpty)
        let requestCount = await repository.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testHomeCacheRejectsSchemaMismatchAndDamagedPayload() throws {
        let suite = "HomeRecommendationCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try XCTUnwrap(HomeRecommendationCacheContext(
            accountID: "account-a",
            source: .app
        ))
        let writer = UserDefaultsHomeRecommendationCachePersistence(
            defaults: defaults,
            expectedSchemaVersion: 1
        )
        writer.save(cacheSnapshot(
            context: context,
            items: [feedItem(1)],
            now: Date(timeIntervalSince1970: 100)
        ), for: context)

        XCTAssertNil(UserDefaultsHomeRecommendationCachePersistence(
            defaults: defaults,
            expectedSchemaVersion: 2
        ).load(for: context))

        defaults.set(
            Data("damaged-cache".utf8),
            forKey: UserDefaultsHomeRecommendationCachePersistence.storageKey(for: context)
        )
        XCTAssertNil(writer.load(for: context))
    }

    func testHomeCacheRejectsUntrustedPagingURL() throws {
        let suite = "HomeRecommendationCacheTrustTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try XCTUnwrap(HomeRecommendationCacheContext(
            accountID: "account-a",
            source: .web
        ))
        let snapshot = HomeRecommendationCacheSnapshot(
            schemaVersion: HomeRecommendationCacheSnapshot.currentSchemaVersion,
            accountID: context.accountID,
            source: context.source,
            items: [feedItem(1)],
            nextURL: URL(string: "https://attacker.example/next"),
            isEnd: false,
            refreshMetadata: .empty,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        defaults.set(
            try JSONEncoder().encode(snapshot),
            forKey: UserDefaultsHomeRecommendationCachePersistence.storageKey(for: context)
        )

        XCTAssertNil(
            UserDefaultsHomeRecommendationCachePersistence(defaults: defaults)
                .load(for: context)
        )
    }

    func testHomeManualRefreshReplacesFirstPageAndRecordsCurrentTime() async {
        let initialDate = Date(timeIntervalSince1970: 3_000)
        let refreshDate = initialDate.addingTimeInterval(120)
        let clock = FeedRefreshTestClock(initialDate)
        let first = feedItem(1)
        let refreshed = feedItem(2)
        let store = HomeFeedNativeStore(
            repository: HomeRepositoryStub(results: [
                .success(FeedPageDTO(items: [first], nextURL: nil, isEnd: true)),
                .success(FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)),
            ]),
            refreshMetadataPersistence: InMemoryFeedRefreshMetadataPersistence(),
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        clock.now = refreshDate
        await store.refresh()

        XCTAssertEqual(store.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshDate)
        XCTAssertFalse(store.isRefreshing)
    }

    func testHomePullRefreshSupersedesPaginationImmediately() async {
        let initial = feedItem(1)
        let paginated = feedItem(2)
        let refreshed = feedItem(3)
        let nextURL = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomePaginationRefreshRepositoryStub(
            initial: FeedPageDTO(items: [initial], nextURL: nextURL, isEnd: false),
            paginated: FeedPageDTO(items: [paginated], nextURL: nil, isEnd: true),
            refreshed: FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let pagination = Task { await store.loadMore() }
        await repository.waitUntilPaginationStarts()
        let refresh = Task { await store.refresh() }
        for _ in 0..<5 { await Task.yield() }

        let requestsWhilePaginating = await repository.requestedURLs()
        XCTAssertEqual(requestsWhilePaginating, [nil, nextURL, nil])

        await repository.resumePagination()
        await pagination.value
        await refresh.value

        let completedRequests = await repository.requestedURLs()
        XCTAssertEqual(completedRequests, [nil, nextURL, nil])
        XCTAssertEqual(store.items, [refreshed])
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isRefreshing)
    }

    func testHomeRefreshPublishesFirstBatchFeedbackThenKeepsOverflow() async {
        let initialDate = Date(timeIntervalSince1970: 4_000)
        let refreshDate = initialDate.addingTimeInterval(100)
        let clock = FeedRefreshTestClock(initialDate)
        let firstNext = URL(string: "https://api.zhihu.com/topstory/recommend?offset=10")!
        let repository = HomeRefreshLoopRepositoryStub(
            pages: [
                FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
                FeedPageDTO(
                    items: [feedItem(10), feedItem(11), feedItem(12), feedItem(13)],
                    nextURL: firstNext,
                    isEnd: false
                ),
                FeedPageDTO(
                    items: [feedItem(14), feedItem(15), feedItem(16), feedItem(17)],
                    nextURL: nil,
                    isEnd: true
                ),
            ],
            delayedRequestNumber: 3
        )
        let store = HomeFeedNativeStore(
            repository: repository,
            configuration: {
                HomeRecommendationRefreshConfiguration(source: .app, targetItemCount: 6)
            },
            refreshMetadataPersistence: InMemoryFeedRefreshMetadataPersistence(),
            now: { clock.now }
        )
        await store.loadInitialIfNeeded()
        clock.now = refreshDate

        let refresh = Task { await store.refresh(intent: .pull) }
        await repository.waitUntilDelayedRequestStarts()

        XCTAssertEqual(store.items.map(\.id.contentID), ["10", "11", "12", "13"])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshDate)
        XCTAssertEqual(store.refreshFeedbackSequence, 1)
        XCTAssertTrue(store.isRefreshing)

        await repository.resumeDelayedRequest()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .published)
        XCTAssertEqual(
            store.items.map(\.id.contentID),
            ["10", "11", "12", "13", "14", "15", "16", "17"]
        )
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshDate)
        XCTAssertEqual(store.refreshFeedbackSequence, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testHomeRepeatedPullIsIgnoredWhileRefreshLoopIsActive() async {
        let repository = HomeRefreshLoopRepositoryStub(
            pages: [
                FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
                FeedPageDTO(items: [feedItem(2)], nextURL: nil, isEnd: true),
            ],
            delayedRequestNumber: 2
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let activeRefresh = Task { await store.refresh(intent: .pull) }
        await repository.waitUntilDelayedRequestStarts()

        let ignoredOutcome = await store.refresh(intent: .pull)
        XCTAssertEqual(ignoredOutcome, .ignored)

        await repository.resumeDelayedRequest()
        let activeOutcome = await activeRefresh.value
        XCTAssertEqual(activeOutcome, .published)
        XCTAssertEqual(store.refreshFeedbackSequence, 1)
    }

    func testHomeReturnToTopCancelsActiveLoopAndStartsReplacementImmediately() async {
        let repository = HomeRefreshReplacementRepositoryStub(
            initial: FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
            replacement: FeedPageDTO(items: [feedItem(3)], nextURL: nil, isEnd: true)
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let firstRefresh = Task { await store.refresh(intent: .pull) }
        await repository.waitUntilFirstRefreshStarts()
        let replacementOutcome = await store.refresh(intent: .returnToTop)
        let cancelledOutcome = await firstRefresh.value
        let requestCount = await repository.requestCount()

        XCTAssertEqual(replacementOutcome, .published)
        XCTAssertEqual(cancelledOutcome, .cancelled)
        XCTAssertEqual(store.items, [feedItem(3)])
        XCTAssertEqual(store.refreshFeedbackSequence, 1)
        XCTAssertEqual(requestCount, 3)
    }

    func testHomeRefreshStopsAfterTwoPagesWithoutNewDisplayableItems() async {
        let firstNext = URL(string: "https://api.zhihu.com/topstory/recommend?offset=10")!
        let secondNext = URL(string: "https://api.zhihu.com/topstory/recommend?offset=20")!
        let repository = HomeRefreshLoopRepositoryStub(pages: [
            FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
            FeedPageDTO(items: [], nextURL: firstNext, isEnd: false),
            FeedPageDTO(items: [], nextURL: secondNext, isEnd: false),
            FeedPageDTO(items: [feedItem(99)], nextURL: nil, isEnd: true),
        ])
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let outcome = await store.refresh(intent: .pull)
        let requestCount = await repository.requestCount()

        XCTAssertEqual(outcome, .noContent)
        XCTAssertEqual(store.items, [feedItem(1)])
        XCTAssertEqual(store.refreshFeedbackSequence, 0)
        XCTAssertEqual(requestCount, 3)
    }

    func testHomeSourceChangeDiscardsOldPagingAndUsesNewSource() async {
        let repository = HomeRefreshLoopRepositoryStub(pages: [
            FeedPageDTO(
                items: [feedItem(1)],
                nextURL: URL(string: "https://api.zhihu.com/topstory/recommend?offset=10"),
                isEnd: false
            ),
            FeedPageDTO(items: [feedItem(2)], nextURL: nil, isEnd: true),
        ])
        var configuration = HomeRecommendationRefreshConfiguration(
            source: .app,
            targetItemCount: 6
        )
        let store = HomeFeedNativeStore(
            repository: repository,
            configuration: { configuration }
        )
        await store.loadInitialIfNeeded()

        configuration = HomeRecommendationRefreshConfiguration(
            source: .web,
            targetItemCount: 6
        )
        await store.recommendationSourceDidChange()
        let requestedSources = await repository.requestedSources()

        XCTAssertEqual(store.items, [feedItem(2)])
        XCTAssertFalse(store.hasNextPage)
        XCTAssertEqual(requestedSources, [.app, .web])
    }

    func testHomeSourceChangeWithoutNewContentNeverFallsBackToPreviousSource() async {
        let oldNext = URL(string: "https://api.zhihu.com/topstory/recommend?offset=10")!
        let repository = HomeRefreshLoopRepositoryStub(pages: [
            FeedPageDTO(items: [feedItem(1)], nextURL: oldNext, isEnd: false),
            FeedPageDTO(items: [], nextURL: nil, isEnd: true),
            FeedPageDTO(items: [feedItem(2)], nextURL: nil, isEnd: true),
        ])
        var configuration = HomeRecommendationRefreshConfiguration(
            source: .app,
            targetItemCount: 6
        )
        let store = HomeFeedNativeStore(
            repository: repository,
            configuration: { configuration }
        )
        await store.loadInitialIfNeeded()

        configuration = HomeRecommendationRefreshConfiguration(
            source: .web,
            targetItemCount: 6
        )
        await store.recommendationSourceDidChange()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.hasNextPage)

        await store.retry()
        let requestedSources = await repository.requestedSources()
        let requestedURLs = await repository.requestedURLs()

        XCTAssertEqual(store.items, [feedItem(2)])
        XCTAssertEqual(requestedSources, [.app, .web, .web])
        XCTAssertFalse(requestedURLs.compactMap { $0 }.contains(oldNext))
    }

    func testHomeRefreshStopsAfterSixRequestsWhenTargetCannotBeReached() async {
        let refreshPages = (1 ... 6).map { index in
            FeedPageDTO(
                items: [feedItem(Int64(10 + index))],
                nextURL: URL(
                    string: "https://api.zhihu.com/topstory/recommend?offset=\(index * 10)"
                ),
                isEnd: false
            )
        }
        let repository = HomeRefreshLoopRepositoryStub(
            pages: [
                FeedPageDTO(items: [feedItem(1)], nextURL: nil, isEnd: true),
            ] + refreshPages
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let outcome = await store.refresh(intent: .pull)
        let requestCount = await repository.requestCount()

        XCTAssertEqual(outcome, .published)
        XCTAssertEqual(store.items.count, 6)
        XCTAssertEqual(requestCount, 7)
        XCTAssertTrue(store.hasNextPage)
    }

    func testFollowFailedRefreshDoesNotReplaceSuccessfulRefreshTime() async {
        let initialDate = Date(timeIntervalSince1970: 2_000)
        let clock = FeedRefreshTestClock(initialDate)
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let recommend = feedItem(1)
        let repository = FollowRepositoryStub(pages: [
            .recommendations: [
                .success(FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true)),
                .failure(HomeFollowTestError.network),
            ],
        ])
        let store = FollowNativeStore(
            repository: repository,
            refreshMetadataPersistence: persistence,
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(100)
        await store.refresh(section: .recommendations)

        XCTAssertEqual(store.recommendations.items, [recommend])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)
        XCTAssertEqual(persistence.load(for: .following), store.refreshMetadata)
    }

    func testFollowAccountChangeDropsBothSectionsAndRecentUsers() async {
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let store = FollowNativeStore(
            repository: FollowRepositoryStub(pages: [
                .recommendations: [
                    .success(.init(items: [feedItem(1)], nextURL: nil, isEnd: true)),
                    .success(.init(items: [feedItem(3)], nextURL: nil, isEnd: true)),
                ],
                .moments: [
                    .success(.init(items: [feedItem(2)], nextURL: nil, isEnd: true)),
                ],
            ]),
            refreshMetadataPersistence: persistence
        )
        await store.loadIfNeeded(section: .recommendations)
        await store.loadIfNeeded(section: .moments)

        store.accountDidChange()

        XCTAssertTrue(store.recommendations.items.isEmpty)
        XCTAssertTrue(store.moments.items.isEmpty)
        XCTAssertTrue(store.recentUsers.isEmpty)
        XCTAssertEqual(store.refreshMetadata, .empty)
        XCTAssertEqual(persistence.load(for: .following), .empty)
        await store.loadIfNeeded(section: .recommendations)
        XCTAssertEqual(store.recommendations.items, [feedItem(3)])
    }

    func testFollowMomentsSuccessUpdatesMetadataAndCancellationKeepsNewTime() async {
        let initialDate = Date(timeIntervalSince1970: 2_500)
        let refreshedDate = initialDate.addingTimeInterval(60)
        let clock = FeedRefreshTestClock(initialDate)
        let initial = feedItem(1)
        let refreshed = feedItem(2)
        let store = FollowNativeStore(
            repository: FollowRepositoryStub(pages: [
                .moments: [
                    .success(FeedPageDTO(items: [initial], nextURL: nil, isEnd: true)),
                    .success(FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)),
                    .failure(URLError(.cancelled)),
                ],
            ]),
            refreshMetadataPersistence: InMemoryFeedRefreshMetadataPersistence(),
            now: { clock.now }
        )

        await store.loadMomentsIfNeeded()
        clock.now = refreshedDate
        await store.refresh(section: .moments)

        XCTAssertEqual(store.moments.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isMomentsRefreshing)

        clock.now = refreshedDate.addingTimeInterval(60)
        await store.refresh(section: .moments)

        XCTAssertEqual(store.moments.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isMomentsRefreshing)
        XCTAssertNil(store.moments.errorMessage)
    }

    func testHomeNextFailureKeepsItemsAndRetryDeduplicates() async {
        let first = feedItem(1)
        let second = feedItem(2)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .failure(HomeFollowTestError.network),
            .success(FeedPageDTO(items: [first, second], nextURL: nil, isEnd: true)),
        ])
        let store = HomeFeedNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()
        XCTAssertEqual(store.items, [first])
        XCTAssertEqual(store.errorMessage, "网络失败")

        await store.retry()
        XCTAssertEqual(store.items, [first, second])
    }

    func testHomeOpenReportsOnlyThroughRepositoryAndDoesNotDelayRouteOwner() async {
        let item = feedItem(9)
        let repository = HomeRepositoryStub(results: [])
        let store = HomeFeedNativeStore(repository: repository)

        store.opened(item)
        for _ in 0..<10 { await Task.yield() }

        let reportedIDs = await repository.reportedIDs()
        XCTAssertEqual(reportedIDs, [item.id])
    }

    func testHomeCancelledNextPageDoesNotPublishRetryError() async {
        let first = feedItem(1)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .failure(URLError(.cancelled)),
        ])
        let store = HomeFeedNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()

        XCTAssertEqual(store.items, [first])
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.hasNextPage)
    }

    func testFollowKeepsIndependentRecommendationAndMomentPages() async {
        let recommend = feedItem(1)
        let moment = feedItem(2)
        let repository = FollowRepositoryStub(pages: [
            .recommendations: [.success(FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true))],
            .moments: [.success(FeedPageDTO(items: [moment], nextURL: nil, isEnd: true))],
        ])
        let store = FollowNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        store.select(.moments)
        await store.loadIfNeeded(section: .moments)

        XCTAssertEqual(store.recommendations.items, [recommend])
        XCTAssertEqual(store.moments.items, [moment])
    }

    func testFollowMomentsEntryLoadsOnlyMomentsAndRecentUsers() async {
        let moment = feedItem(3)
        let user = FollowingUserDTO(
            id: "member",
            urlToken: "writer",
            displayName: "作者",
            avatarURL: nil,
            unreadCount: 1
        )
        let repository = FollowMomentsOnlyRepositoryStub(moment: moment, recentUser: user)
        let store = FollowNativeStore(repository: repository)

        await store.loadMomentsIfNeeded()

        XCTAssertEqual(store.moments.items, [moment])
        XCTAssertTrue(store.recommendations.items.isEmpty)
        XCTAssertEqual(store.recentUsers, [user])
        let requestedSections = await repository.requestedSections()
        let recentUserRequestCount = await repository.recentUserRequestCount()
        XCTAssertEqual(requestedSections, [.moments])
        XCTAssertEqual(recentUserRequestCount, 1)
    }

    func testFollowCanLoadMomentsWhileRecommendationsInitialPageIsInFlight() async {
        let recommend = feedItem(1)
        let moment = feedItem(2)
        let repository = FollowSectionConcurrencyRepositoryStub(
            delayedRecommendationRequest: .initial,
            recommendationInitial: FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true),
            momentsInitial: FeedPageDTO(items: [moment], nextURL: nil, isEnd: true)
        )
        let store = FollowNativeStore(repository: repository)

        let recommendationLoad = Task { await store.loadInitialIfNeeded() }
        await repository.waitUntilDelayedRecommendationRequestStarts()
        XCTAssertTrue(store.recommendations.isLoading)

        store.select(.moments)
        await store.loadIfNeeded(section: .moments)

        XCTAssertEqual(store.moments.items, [moment])
        XCTAssertTrue(store.recommendations.isLoading)
        XCTAssertTrue(store.isLoading)
        XCTAssertFalse(store.isRefreshing)

        await repository.resumeDelayedRecommendationRequest()
        await recommendationLoad.value
        XCTAssertEqual(store.recommendations.items, [recommend])
    }

    func testFollowRecommendationAndMomentsPaginationDoNotBlockEachOther() async {
        let recommendationNextURL = URL(string: "https://www.zhihu.com/api/v3/follow/recommendations?page=2")!
        let momentsNextURL = URL(string: "https://www.zhihu.com/api/v3/follow/moments?page=2")!
        let recommendFirst = feedItem(1)
        let recommendSecond = feedItem(2)
        let momentFirst = feedItem(3)
        let momentSecond = feedItem(4)
        let repository = FollowSectionConcurrencyRepositoryStub(
            delayedRecommendationRequest: .nextPage,
            recommendationInitial: FeedPageDTO(
                items: [recommendFirst],
                nextURL: recommendationNextURL,
                isEnd: false
            ),
            momentsInitial: FeedPageDTO(
                items: [momentFirst],
                nextURL: momentsNextURL,
                isEnd: false
            ),
            recommendationNext: FeedPageDTO(items: [recommendSecond], nextURL: nil, isEnd: true),
            momentsNext: FeedPageDTO(items: [momentSecond], nextURL: nil, isEnd: true)
        )
        let store = FollowNativeStore(repository: repository)
        await store.loadIfNeeded(section: .recommendations)
        await store.loadIfNeeded(section: .moments)

        let recommendationPagination = Task { await store.loadMore(section: .recommendations) }
        await repository.waitUntilDelayedRecommendationRequestStarts()
        XCTAssertTrue(store.recommendations.isLoading)

        await store.loadMore(section: .moments)

        XCTAssertEqual(store.moments.items, [momentFirst, momentSecond])
        XCTAssertTrue(store.recommendations.isLoading)

        await repository.resumeDelayedRecommendationRequest()
        await recommendationPagination.value
        XCTAssertEqual(store.recommendations.items, [recommendFirst, recommendSecond])
    }

    private func feedItem(
        _ id: Int64,
        questionAuthor: FeedAuthorDTO? = nil
    ) -> FeedItemDTO {
        FeedItemDTO(
            id: FeedItemID(kind: .article, contentID: String(id)),
            kind: .article,
            title: "文章 \(id)",
            summary: nil,
            details: "文章",
            sourceLabel: nil,
            author: nil,
            questionAuthor: questionAuthor,
            thumbnailURL: nil,
            route: .article(articleID: id, title: "文章 \(id)")
        )
    }

    private func cacheSnapshot(
        context: HomeRecommendationCacheContext,
        items: [FeedItemDTO],
        now: Date
    ) -> HomeRecommendationCacheSnapshot {
        HomeRecommendationCacheSnapshot(
            schemaVersion: HomeRecommendationCacheSnapshot.currentSchemaVersion,
            accountID: context.accountID,
            source: context.source,
            items: items,
            nextURL: nil,
            isEnd: true,
            refreshMetadata: FeedChannelRefreshMetadata(
                lastSuccessfulRefreshAt: now,
                lastViewedAt: now
            ),
            savedAt: now
        )
    }
}

private final class FeedRefreshTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class InMemoryFeedRefreshMetadataPersistence: FeedChannelRefreshMetadataPersisting {
    private var values: [FeedRefreshChannelID: FeedChannelRefreshMetadata] = [:]

    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata {
        values[channel] ?? .empty
    }

    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID) {
        values[channel] = metadata
    }
}

private final class InMemoryHomeRecommendationCachePersistence:
    HomeRecommendationCachePersisting {
    private var snapshots:
        [HomeRecommendationCacheContext: HomeRecommendationCacheSnapshot] = [:]

    func load(for context: HomeRecommendationCacheContext) -> HomeRecommendationCacheSnapshot? {
        snapshots[context]
    }

    func save(
        _ snapshot: HomeRecommendationCacheSnapshot,
        for context: HomeRecommendationCacheContext
    ) {
        snapshots[context] = snapshot
    }
}

private enum HomeFollowTestError: LocalizedError {
    case network
    var errorDescription: String? { "网络失败" }
}

private actor HomeRepositoryStub: HomeFeedRepository {
    private var results: [Result<FeedPageDTO, Error>]
    private var reported: [FeedItemID] = []

    init(results: [Result<FeedPageDTO, Error>]) { self.results = results }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        guard !results.isEmpty else { throw HomeFollowTestError.network }
        return try results.removeFirst().get()
    }

    func reportOpened(_ item: FeedItemDTO) async { reported.append(item.id) }
    func reportedIDs() -> [FeedItemID] { reported }
}

private actor CacheHomeRepositoryStub: HomeFeedRepository {
    private var pages: [FeedPageDTO]
    private var requests = 0

    init(pages: [FeedPageDTO]) {
        self.pages = pages
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        try await fetchPage(source: .app, after: nextURL)
    }

    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        requests += 1
        guard !pages.isEmpty else { throw HomeFollowTestError.network }
        return pages.removeFirst()
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func requestCount() -> Int { requests }
}

private actor HomePaginationRefreshRepositoryStub: HomeFeedRepository {
    private let initial: FeedPageDTO
    private let paginated: FeedPageDTO
    private let refreshed: FeedPageDTO
    private var requests: [URL?] = []
    private var paginationContinuation: CheckedContinuation<FeedPageDTO, Never>?
    private var paginationStarted = false

    init(initial: FeedPageDTO, paginated: FeedPageDTO, refreshed: FeedPageDTO) {
        self.initial = initial
        self.paginated = paginated
        self.refreshed = refreshed
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        requests.append(nextURL)
        switch requests.count {
        case 1:
            return initial
        case 2:
            paginationStarted = true
            return await withCheckedContinuation { continuation in
                paginationContinuation = continuation
            }
        default:
            return refreshed
        }
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func waitUntilPaginationStarts() async {
        while !paginationStarted { await Task.yield() }
    }

    func resumePagination() {
        paginationContinuation?.resume(returning: paginated)
        paginationContinuation = nil
    }

    func requestedURLs() -> [URL?] { requests }
}

private actor HomeRefreshLoopRepositoryStub: HomeFeedRepository {
    private var pages: [FeedPageDTO]
    private let delayedRequestNumber: Int?
    private var requests: [(HomeRecommendationSource, URL?)] = []
    private var delayedRequestStarted = false
    private var delayedRequestContinuation: CheckedContinuation<Void, Never>?

    init(
        pages: [FeedPageDTO],
        delayedRequestNumber: Int? = nil
    ) {
        self.pages = pages
        self.delayedRequestNumber = delayedRequestNumber
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        try await fetchPage(source: .app, after: nextURL)
    }

    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        requests.append((source, nextURL))
        guard !pages.isEmpty else { throw HomeFollowTestError.network }
        let page = pages.removeFirst()
        if requests.count == delayedRequestNumber {
            delayedRequestStarted = true
            await withCheckedContinuation { continuation in
                delayedRequestContinuation = continuation
            }
            try Task.checkCancellation()
        }
        return page
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func waitUntilDelayedRequestStarts() async {
        while !delayedRequestStarted { await Task.yield() }
    }

    func resumeDelayedRequest() {
        delayedRequestContinuation?.resume()
        delayedRequestContinuation = nil
    }

    func requestCount() -> Int { requests.count }
    func requestedSources() -> [HomeRecommendationSource] { requests.map { $0.0 } }
    func requestedURLs() -> [URL?] { requests.map { $0.1 } }
}

private actor HomeRefreshReplacementRepositoryStub: HomeFeedRepository {
    private let initial: FeedPageDTO
    private let replacement: FeedPageDTO
    private var requests = 0
    private var firstRefreshStarted = false

    init(initial: FeedPageDTO, replacement: FeedPageDTO) {
        self.initial = initial
        self.replacement = replacement
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        try await fetchPage(source: .app, after: nextURL)
    }

    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        requests += 1
        switch requests {
        case 1:
            return initial
        case 2:
            firstRefreshStarted = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return initial
        default:
            return replacement
        }
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func waitUntilFirstRefreshStarts() async {
        while !firstRefreshStarted { await Task.yield() }
    }

    func requestCount() -> Int { requests }
}

private actor FollowRepositoryStub: FollowRepository {
    private var pages: [FollowSection: [Result<FeedPageDTO, Error>]]

    init(pages: [FollowSection: [Result<FeedPageDTO, Error>]]) { self.pages = pages }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        guard var values = pages[section], !values.isEmpty else { throw HomeFollowTestError.network }
        let result = values.removeFirst()
        pages[section] = values
        return try result.get()
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] { [] }
}

private actor FollowMomentsOnlyRepositoryStub: FollowRepository {
    private let moment: FeedItemDTO
    private let recentUser: FollowingUserDTO
    private var sections: [FollowSection] = []
    private var recentUserRequests = 0

    init(moment: FeedItemDTO, recentUser: FollowingUserDTO) {
        self.moment = moment
        self.recentUser = recentUser
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        sections.append(section)
        return FeedPageDTO(items: [moment], nextURL: nil, isEnd: true)
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] {
        recentUserRequests += 1
        return [recentUser]
    }

    func requestedSections() -> [FollowSection] { sections }
    func recentUserRequestCount() -> Int { recentUserRequests }
}

private actor FollowSectionConcurrencyRepositoryStub: FollowRepository {
    enum DelayedRecommendationRequest {
        case initial
        case nextPage
    }

    private let delayedRecommendationRequest: DelayedRecommendationRequest
    private let recommendationInitial: FeedPageDTO
    private let momentsInitial: FeedPageDTO
    private let recommendationNext: FeedPageDTO?
    private let momentsNext: FeedPageDTO?
    private var delayedRecommendationContinuation: CheckedContinuation<FeedPageDTO, Error>?
    private var delayedRecommendationRequestStarted = false

    init(
        delayedRecommendationRequest: DelayedRecommendationRequest,
        recommendationInitial: FeedPageDTO,
        momentsInitial: FeedPageDTO,
        recommendationNext: FeedPageDTO? = nil,
        momentsNext: FeedPageDTO? = nil
    ) {
        self.delayedRecommendationRequest = delayedRecommendationRequest
        self.recommendationInitial = recommendationInitial
        self.momentsInitial = momentsInitial
        self.recommendationNext = recommendationNext
        self.momentsNext = momentsNext
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        switch (section, nextURL) {
        case (.recommendations, nil):
            if delayedRecommendationRequest == .initial {
                return try await suspendRecommendationRequest()
            }
            return recommendationInitial
        case (.moments, nil):
            return momentsInitial
        case (.recommendations, .some):
            guard let recommendationNext else { throw HomeFollowTestError.network }
            if delayedRecommendationRequest == .nextPage {
                return try await suspendRecommendationRequest()
            }
            return recommendationNext
        case (.moments, .some):
            guard let momentsNext else { throw HomeFollowTestError.network }
            return momentsNext
        }
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] { [] }

    func waitUntilDelayedRecommendationRequestStarts() async {
        while !delayedRecommendationRequestStarted { await Task.yield() }
    }

    func resumeDelayedRecommendationRequest() {
        let page = delayedRecommendationRequest == .initial
            ? recommendationInitial
            : recommendationNext
        guard let page else { return }
        delayedRecommendationContinuation?.resume(returning: page)
        delayedRecommendationContinuation = nil
    }

    private func suspendRecommendationRequest() async throws -> FeedPageDTO {
        delayedRecommendationRequestStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            delayedRecommendationContinuation = continuation
        }
    }
}
