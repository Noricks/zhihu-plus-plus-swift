import CryptoKit
import Foundation

private extension HomeRecommendationRefreshIntent {
    var diagnosticName: String {
        switch self {
        case .pull: return "pull"
        case .automatic: return "automatic"
        case .returnToTop: return "return_to_top"
        case .sourceChanged: return "source_changed"
        case .retry: return "retry"
        }
    }
}

private extension HomeRecommendationRefreshOutcome {
    var diagnosticResult: PerformanceDiagnosticEvent.Result {
        switch self {
        case .published, .publishedPartially, .noContent: return .success
        case .failed: return .failure
        case .cancelled, .ignored: return .cancelled
        }
    }
}

struct FeedChannelRefreshMetadata: Codable, Equatable {
    var lastSuccessfulRefreshAt: Date?
    var lastViewedAt: Date?

    static let empty = FeedChannelRefreshMetadata(
        lastSuccessfulRefreshAt: nil,
        lastViewedAt: nil
    )
}

enum FeedRefreshChannelID: String, CaseIterable {
    case recommendations
    case following
    case hot
    case daily
}

struct FeedChannelRefreshPolicy: Equatable {
    static let oneHour = FeedChannelRefreshPolicy(idleThreshold: 60 * 60)

    let idleThreshold: TimeInterval

    func needsRefreshAfterIdle(
        metadata: FeedChannelRefreshMetadata,
        now: Date
    ) -> Bool {
        guard let lastViewedAt = metadata.lastViewedAt else { return false }
        if let lastSuccessfulRefreshAt = metadata.lastSuccessfulRefreshAt,
           lastSuccessfulRefreshAt >= lastViewedAt {
            return false
        }
        return now.timeIntervalSince(lastViewedAt) >= idleThreshold
    }
}

protocol FeedChannelRefreshMetadataPersisting {
    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata
    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID)
}

struct UserDefaultsFeedChannelRefreshMetadataPersistence: FeedChannelRefreshMetadataPersisting {
    static let keyPrefix = "feedChannelRefreshMetadata.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata {
        guard let data = defaults.data(forKey: key(for: channel)),
              let metadata = try? JSONDecoder().decode(FeedChannelRefreshMetadata.self, from: data)
        else { return .empty }
        return metadata
    }

    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: key(for: channel))
    }

    private func key(for channel: FeedRefreshChannelID) -> String {
        "\(Self.keyPrefix).\(channel.rawValue)"
    }
}

struct FeedChannelRefreshTracker {
    let channel: FeedRefreshChannelID
    let persistence: FeedChannelRefreshMetadataPersisting
    let policy: FeedChannelRefreshPolicy
    let now: () -> Date

    func load() -> FeedChannelRefreshMetadata {
        persistence.load(for: channel)
    }

    func recordingSuccessfulRefresh(
        in metadata: FeedChannelRefreshMetadata
    ) -> FeedChannelRefreshMetadata {
        var updated = metadata
        updated.lastSuccessfulRefreshAt = now()
        persistence.save(updated, for: channel)
        return updated
    }

    func recordingLastViewed(
        in metadata: FeedChannelRefreshMetadata,
        at date: Date? = nil
    ) -> FeedChannelRefreshMetadata {
        var updated = metadata
        updated.lastViewedAt = date ?? now()
        persistence.save(updated, for: channel)
        return updated
    }

    func clearing() -> FeedChannelRefreshMetadata {
        let cleared = FeedChannelRefreshMetadata.empty
        persistence.save(cleared, for: channel)
        return cleared
    }

    func needsRefreshAfterIdle(
        metadata: FeedChannelRefreshMetadata,
        at date: Date? = nil
    ) -> Bool {
        policy.needsRefreshAfterIdle(metadata: metadata, now: date ?? now())
    }
}

struct HomeRecommendationCacheContext: Equatable, Hashable, Sendable {
    let accountID: String
    let source: HomeRecommendationSource

    init?(accountID: String?, source: HomeRecommendationSource) {
        guard let accountID = accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty
        else { return nil }
        self.accountID = accountID
        self.source = source
    }
}

struct HomeRecommendationCacheSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountID: String
    let source: HomeRecommendationSource
    let items: [FeedItemDTO]
    let nextURL: URL?
    let isEnd: Bool
    let refreshMetadata: FeedChannelRefreshMetadata
    let savedAt: Date
}

protocol HomeRecommendationCachePersisting: Sendable {
    func load(for context: HomeRecommendationCacheContext) -> HomeRecommendationCacheSnapshot?
    func save(
        _ snapshot: HomeRecommendationCacheSnapshot,
        for context: HomeRecommendationCacheContext
    )
}

struct UserDefaultsHomeRecommendationCachePersistence:
    HomeRecommendationCachePersisting,
    @unchecked Sendable
{
    static let keyPrefix = "homeRecommendationCache"

    let defaults: UserDefaults
    let expectedSchemaVersion: Int

    init(
        defaults: UserDefaults = .standard,
        expectedSchemaVersion: Int = HomeRecommendationCacheSnapshot.currentSchemaVersion
    ) {
        self.defaults = defaults
        self.expectedSchemaVersion = expectedSchemaVersion
    }

    func load(for context: HomeRecommendationCacheContext) -> HomeRecommendationCacheSnapshot? {
        guard let data = defaults.data(forKey: Self.storageKey(for: context)),
              let decoded = try? JSONDecoder().decode(
                  HomeRecommendationCacheSnapshot.self,
                  from: data
              ),
              decoded.schemaVersion == expectedSchemaVersion,
              decoded.accountID == context.accountID,
              decoded.source == context.source,
              !decoded.items.isEmpty
        else { return nil }

        let trustedNextURL: URL?
        do {
            trustedNextURL = try ZhihuAPIURLPolicy.validatedPagingURL(decoded.nextURL)
        } catch {
            return nil
        }
        return HomeRecommendationCacheSnapshot(
            schemaVersion: decoded.schemaVersion,
            accountID: decoded.accountID,
            source: decoded.source,
            items: decoded.items,
            nextURL: trustedNextURL,
            isEnd: decoded.isEnd || trustedNextURL == nil,
            refreshMetadata: decoded.refreshMetadata,
            savedAt: decoded.savedAt
        )
    }

    func save(
        _ snapshot: HomeRecommendationCacheSnapshot,
        for context: HomeRecommendationCacheContext
    ) {
        if let nextURL = snapshot.nextURL {
            guard (try? ZhihuAPIURLPolicy.validatedPagingURL(nextURL)) != nil else {
                return
            }
        }
        guard snapshot.schemaVersion == expectedSchemaVersion,
              snapshot.accountID == context.accountID,
              snapshot.source == context.source,
              !snapshot.items.isEmpty,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults.set(data, forKey: Self.storageKey(for: context))
    }

    static func storageKey(for context: HomeRecommendationCacheContext) -> String {
        let encodedAccountID = Data(context.accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(keyPrefix).\(context.source.rawValue).\(encodedAccountID)"
    }
}

struct FileHomeRecommendationCachePolicy {
    static let maximumItemCount = 60
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func isFresh(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age <= maximumAge
    }

    static func snapshotForStorage(
        _ snapshot: HomeRecommendationCacheSnapshot,
        context: HomeRecommendationCacheContext,
        expectedSchemaVersion: Int
    ) -> HomeRecommendationCacheSnapshot? {
        guard snapshot.schemaVersion == expectedSchemaVersion,
              snapshot.accountID == context.accountID,
              snapshot.source == context.source,
              !snapshot.items.isEmpty
        else { return nil }

        let trustedNextURL: URL?
        do {
            trustedNextURL = try ZhihuAPIURLPolicy.validatedPagingURL(snapshot.nextURL)
        } catch {
            return nil
        }
        let wasTruncated = snapshot.items.count > maximumItemCount
        let storedNextURL = wasTruncated ? nil : trustedNextURL
        return HomeRecommendationCacheSnapshot(
            schemaVersion: snapshot.schemaVersion,
            accountID: snapshot.accountID,
            source: snapshot.source,
            items: Array(snapshot.items.prefix(maximumItemCount)),
            nextURL: storedNextURL,
            isEnd: snapshot.isEnd || storedNextURL == nil,
            refreshMetadata: snapshot.refreshMetadata,
            savedAt: snapshot.savedAt
        )
    }
}

/// A bounded, per-account cache for already-normalized feed DTOs. The memory
/// copy makes repeated restores cheap; JSON encoding and atomic file writes are
/// serialized away from the main actor so refresh completion never waits on I/O.
final class FileHomeRecommendationCachePersistence:
    HomeRecommendationCachePersisting,
    @unchecked Sendable
{
    private let directory: URL
    private let expectedSchemaVersion: Int
    private let now: @Sendable () -> Date
    private let diagnostics: PerformanceDiagnosticsClient
    private let fileManager: FileManager
    private let writerQueue = DispatchQueue(
        label: "com.github.zly2006.zhplus.home-recommendation-cache",
        qos: .utility
    )
    private let lock = NSLock()
    private var memory: [HomeRecommendationCacheContext: HomeRecommendationCacheSnapshot] = [:]

    init(
        directory: URL? = nil,
        expectedSchemaVersion: Int = HomeRecommendationCacheSnapshot.currentSchemaVersion,
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("HomeRecommendationCache", isDirectory: true)
        self.expectedSchemaVersion = expectedSchemaVersion
        self.now = now
        self.diagnostics = diagnostics
        self.fileManager = fileManager
    }

    func load(for context: HomeRecommendationCacheContext) -> HomeRecommendationCacheSnapshot? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        if let cached = lock.withLock({ memory[context] }) {
            if FileHomeRecommendationCachePolicy.isFresh(savedAt: cached.savedAt, now: now()) {
                recordLoad(startedAt: startedAt, snapshot: cached, source: "memory")
                return cached
            }
            lock.withLock { memory.removeValue(forKey: context) }
        }

        guard let data = try? Data(contentsOf: fileURL(for: context)),
              let decoded = try? JSONDecoder().decode(HomeRecommendationCacheSnapshot.self, from: data),
              FileHomeRecommendationCachePolicy.isFresh(savedAt: decoded.savedAt, now: now()),
              let snapshot = FileHomeRecommendationCachePolicy.snapshotForStorage(
                  decoded,
                  context: context,
                  expectedSchemaVersion: expectedSchemaVersion
              )
        else {
            recordLoad(startedAt: startedAt, snapshot: nil, source: "miss")
            return nil
        }
        lock.withLock { memory[context] = snapshot }
        recordLoad(startedAt: startedAt, snapshot: snapshot, source: "disk")
        return snapshot
    }

    func save(
        _ snapshot: HomeRecommendationCacheSnapshot,
        for context: HomeRecommendationCacheContext
    ) {
        guard let bounded = FileHomeRecommendationCachePolicy.snapshotForStorage(
            snapshot,
            context: context,
            expectedSchemaVersion: expectedSchemaVersion
        ) else { return }
        lock.withLock { memory[context] = bounded }
        let directory = directory
        let fileURL = fileURL(for: context)
        let fileManager = fileManager
        let diagnostics = diagnostics
        writerQueue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(bounded)
                try data.write(to: fileURL, options: .atomic)
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
                diagnostics.record(.init(
                    durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                    category: "recommendation_cache",
                    operation: "write",
                    result: .success,
                    responseBytes: data.count,
                    itemCount: bounded.items.count,
                    cacheSource: "disk"
                ))
            } catch {
                diagnostics.record(.init(
                    durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                    category: "recommendation_cache",
                    operation: "write",
                    result: .failure,
                    itemCount: bounded.items.count,
                    cacheSource: "disk",
                    errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
                ))
            }
        }
    }

    private func fileURL(for context: HomeRecommendationCacheContext) -> URL {
        let identity = "\(context.accountID)|\(context.source.rawValue)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func recordLoad(
        startedAt: TimeInterval,
        snapshot: HomeRecommendationCacheSnapshot?,
        source: String
    ) {
        diagnostics.record(.init(
            durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
            category: "recommendation_cache",
            operation: "read",
            result: .success,
            itemCount: snapshot?.items.count ?? 0,
            cacheSource: source
        ))
    }
}

@MainActor
final class HomeFeedNativeStore: ObservableObject {
    @Published private(set) var items: [FeedItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshMetadata: FeedChannelRefreshMetadata
    @Published private(set) var refreshFeedbackSequence: UInt = 0

    private let repository: HomeFeedRepository
    private let refreshTracker: FeedChannelRefreshTracker
    private let configuration: @MainActor () -> HomeRecommendationRefreshConfiguration
    private let cacheAccountID: @MainActor () -> String?
    private let cachePersistence: HomeRecommendationCachePersisting
    private let automaticallyPrefetchesFirstContinuation: Bool
    private let firstContinuationPrefetchDelayNanoseconds: UInt64
    private let thumbnailPrefetcher: FeedThumbnailPrefetching
    private let diagnostics: PerformanceDiagnosticsClient
    private let now: () -> Date
    private var nextURL: URL?
    private var isEnd = false
    private var hasLoaded = false
    private var loadedSource: HomeRecommendationSource?
    private var failedOperation: FailedOperation?
    private var generation: UInt64 = 0
    private var activeRefreshTask: Task<HomeRecommendationRefreshOutcome, Never>?
    private var activeRefreshGeneration: UInt64?
    private var firstContinuationPrefetchTask: Task<Void, Never>?

    private static let maximumConsecutivePagesWithoutNewItems = 2
    private static let refreshTimeout: TimeInterval = 15
    private static let paginationPrefetchDistance = 5

    init(
        repository: HomeFeedRepository,
        configuration: @escaping @MainActor () -> HomeRecommendationRefreshConfiguration = {
            .defaultValue
        },
        refreshMetadataPersistence: FeedChannelRefreshMetadataPersisting = UserDefaultsFeedChannelRefreshMetadataPersistence(),
        cachePersistence: HomeRecommendationCachePersisting = UserDefaultsHomeRecommendationCachePersistence(),
        cacheAccountID: @escaping @MainActor () -> String? = { nil },
        refreshPolicy: FeedChannelRefreshPolicy = .oneHour,
        automaticallyPrefetchesFirstContinuation: Bool = false,
        firstContinuationPrefetchDelayNanoseconds: UInt64 = 150_000_000,
        thumbnailPrefetcher: FeedThumbnailPrefetching = DisabledFeedThumbnailPrefetcher(),
        now: @escaping () -> Date = Date.init,
        diagnostics: PerformanceDiagnosticsClient = .disabled
    ) {
        self.repository = repository
        self.configuration = configuration
        self.cachePersistence = cachePersistence
        self.cacheAccountID = cacheAccountID
        self.automaticallyPrefetchesFirstContinuation = automaticallyPrefetchesFirstContinuation
        self.firstContinuationPrefetchDelayNanoseconds = firstContinuationPrefetchDelayNanoseconds
        self.thumbnailPrefetcher = thumbnailPrefetcher
        self.now = now
        self.diagnostics = diagnostics
        let refreshTracker = FeedChannelRefreshTracker(
            channel: .recommendations,
            persistence: refreshMetadataPersistence,
            policy: refreshPolicy,
            now: now
        )
        self.refreshTracker = refreshTracker
        refreshMetadata = refreshTracker.load()
    }

    var canLoadMore: Bool { hasLoaded && !isEnd && nextURL != nil && !isLoading }
    var hasNextPage: Bool { hasLoaded && !isEnd && nextURL != nil }
    var nextPageLoadID: String? { nextURL?.absoluteString }

    func loadInitialIfNeeded() async {
        if !hasLoaded {
            _ = await restoreCachedSnapshotForCurrentContext()
        }
        if hasLoaded {
            if needsRefreshAfterIdle() {
                _ = await refresh(intent: .automatic)
            } else {
                scheduleFirstContinuationPrefetch()
            }
            return
        }
        await loadInitialPage()
    }

    func refresh() async {
        _ = await refresh(intent: .pull)
    }

    @discardableResult
    func refresh(
        intent: HomeRecommendationRefreshIntent
    ) async -> HomeRecommendationRefreshOutcome {
        if activeRefreshTask != nil {
            guard intent.replacesActiveRefresh else { return .ignored }
            cancelActiveRefresh()
        } else if intent == .automatic, isLoading {
            return .ignored
        }

        let outcome = await startRefreshLoop(intent: intent)
        if outcome == .published || outcome == .publishedPartially {
            scheduleFirstContinuationPrefetch()
        }
        return outcome
    }

    func recommendationSourceDidChange() async {
        guard !Task.isCancelled else { return }
        let source = configuration().source
        guard loadedSource != source || isLoading else { return }
        resetForCacheContextChange()
        let restoredCachedSnapshot = await restoreCachedSnapshotForCurrentContext()
        guard !Task.isCancelled, configuration().source == source else { return }
        if restoredCachedSnapshot, !needsRefreshAfterIdle() {
            scheduleFirstContinuationPrefetch()
            return
        }
        _ = await refresh(intent: .sourceChanged)
    }

    func accountDidChange() {
        resetForCacheContextChange()
    }

    func recordLastViewed() {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata)
        persistSuccessfulSnapshot()
    }

    func recordLastViewed(at date: Date) {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata, at: date)
        persistSuccessfulSnapshot()
    }

    func needsRefreshAfterIdle() -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata)
    }

    func needsRefreshAfterIdle(at date: Date) -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata, at: date)
    }

    func loadMore() async {
        guard canLoadMore, let requestedURL = nextURL else { return }
        let currentGeneration = generation
        let source = loadedSource ?? configuration().source
        isLoading = true
        errorMessage = nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let page = try await repository.fetchPage(source: source, after: requestedURL)
            guard currentGeneration == generation else { return }
            appendUnique(page.items)
            prefetchThumbnails(in: page.items)
            nextURL = page.nextURL
            isEnd = page.isEnd
            failedOperation = nil
            persistSuccessfulSnapshot()
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "recommendation",
                operation: "page_load",
                result: .success,
                itemCount: page.items.count,
                pagingSource: "next",
                refreshSource: source.rawValue
            ))
        } catch {
            guard currentGeneration == generation else { return }
            if error.isNativeRequestCancellation {
                diagnostics.record(.init(
                    durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                    category: "recommendation",
                    operation: "page_load",
                    result: .cancelled,
                    pagingSource: "next",
                    refreshSource: source.rawValue,
                    errorKind: "cancelled"
                ))
                isLoading = false
                return
            }
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "recommendation",
                operation: "page_load",
                result: .failure,
                pagingSource: "next",
                refreshSource: source.rawValue,
                errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
            ))
            errorMessage = error.localizedDescription
            failedOperation = .nextPage
        }
        if currentGeneration == generation { isLoading = false }
    }

    func prefetchNextPageIfNeeded(after itemID: FeedItemID) async {
        guard hasNextPage,
              let itemIndex = items.firstIndex(where: { $0.id == itemID })
        else { return }
        let remainingItemCount = items.distance(from: itemIndex, to: items.endIndex)
        guard remainingItemCount <= Self.paginationPrefetchDistance else { return }
        await loadMore()
    }

    func retry() async {
        if failedOperation == .nextPage {
            await loadMore()
        } else {
            _ = await refresh(intent: .retry)
        }
    }

    func opened(_ item: FeedItemDTO) {
        Task { await repository.reportOpened(item) }
    }

    private func loadInitialPage() async {
        guard !isLoading else { return }
        generation &+= 1
        let currentGeneration = generation
        let source = configuration().source
        isLoading = true
        isRefreshing = false
        errorMessage = nil
        do {
            let page = try await repository.fetchPage(source: source, after: nil)
            guard currentGeneration == generation else { return }
            items = page.items
            prefetchThumbnails(in: page.items)
            nextURL = page.nextURL
            isEnd = page.isEnd
            hasLoaded = true
            loadedSource = source
            failedOperation = nil
            refreshMetadata = refreshTracker.recordingSuccessfulRefresh(in: refreshMetadata)
            persistSuccessfulSnapshot()
        } catch {
            guard currentGeneration == generation else { return }
            if error.isNativeRequestCancellation {
                isLoading = false
                isRefreshing = false
                return
            }
            errorMessage = error.localizedDescription
            failedOperation = .initial
        }
        if currentGeneration == generation {
            isLoading = false
            isRefreshing = false
            scheduleFirstContinuationPrefetch()
        }
    }

    private func startRefreshLoop(
        intent: HomeRecommendationRefreshIntent
    ) async -> HomeRecommendationRefreshOutcome {
        cancelFirstContinuationPrefetch()
        generation &+= 1
        let refreshGeneration = generation
        let refreshConfiguration = configuration()
        isLoading = true
        isRefreshing = hasLoaded
        errorMessage = nil
        let startedAt = ProcessInfo.processInfo.systemUptime

        let task = Task { @MainActor [weak self] in
            guard let self else { return HomeRecommendationRefreshOutcome.cancelled }
            return await self.performRefreshLoop(
                generation: refreshGeneration,
                configuration: refreshConfiguration,
                intent: intent,
                startedAt: startedAt
            )
        }
        activeRefreshTask = task
        activeRefreshGeneration = refreshGeneration
        let outcome = await task.value
        if activeRefreshGeneration == refreshGeneration {
            activeRefreshTask = nil
            activeRefreshGeneration = nil
        }
        if generation == refreshGeneration {
            isLoading = false
            isRefreshing = false
        }
        diagnostics.record(.init(
            durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
            category: "recommendation",
            operation: "refresh_loop",
            result: outcome.diagnosticResult,
            itemCount: items.count,
            refreshSource: "\(intent.diagnosticName):\(refreshConfiguration.source.rawValue)",
            errorKind: outcome == .failed ? "refresh_failed" : nil
        ))
        return outcome
    }

    private func performRefreshLoop(
        generation refreshGeneration: UInt64,
        configuration refreshConfiguration: HomeRecommendationRefreshConfiguration,
        intent: HomeRecommendationRefreshIntent,
        startedAt: TimeInterval
    ) async -> HomeRecommendationRefreshOutcome {
        let deadline = Date().addingTimeInterval(Self.refreshTimeout)
        var requestedPageURL: URL?
        var visitedPageURLs: Set<String> = []
        var accumulatedItems: [FeedItemDTO] = []
        var knownItemIDs: Set<FeedItemID> = []
        var consecutivePagesWithoutNewItems = 0
        var publishedFirstBatch = false

        do {
            for _ in 0..<HomeRecommendationRefreshExecutionPolicy.maximumRequests(
                for: intent
            ) {
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return .cancelled }
                if let requestedPageURL,
                   !visitedPageURLs.insert(requestedPageURL.absoluteString).inserted {
                    break
                }

                let page = try await fetchRefreshPage(
                    source: refreshConfiguration.source,
                    after: requestedPageURL,
                    deadline: deadline
                )
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return .cancelled }

                let newItems = page.items.filter { knownItemIDs.insert($0.id).inserted }
                if newItems.isEmpty {
                    consecutivePagesWithoutNewItems += 1
                } else {
                    consecutivePagesWithoutNewItems = 0
                    accumulatedItems.append(contentsOf: newItems)
                    items = accumulatedItems
                    prefetchThumbnails(in: newItems)
                    loadedSource = refreshConfiguration.source

                    if !publishedFirstBatch {
                        publishedFirstBatch = true
                        hasLoaded = true
                        failedOperation = nil
                        refreshMetadata = refreshTracker.recordingSuccessfulRefresh(
                            in: refreshMetadata
                        )
                        refreshFeedbackSequence &+= 1
                        diagnostics.record(.init(
                            durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                            category: "recommendation",
                            operation: "first_publish",
                            result: .success,
                            itemCount: accumulatedItems.count,
                            pagingSource: requestedPageURL == nil ? "initial" : "next",
                            refreshSource: "\(intent.diagnosticName):\(refreshConfiguration.source.rawValue)"
                        ))
                    }
                }

                if publishedFirstBatch {
                    nextURL = page.nextURL
                    isEnd = page.isEnd
                    persistSuccessfulSnapshot()
                }

                if accumulatedItems.count >= refreshConfiguration.targetItemCount
                    || page.isEnd
                    || page.nextURL == nil
                    || consecutivePagesWithoutNewItems
                        >= Self.maximumConsecutivePagesWithoutNewItems {
                    break
                }
                requestedPageURL = page.nextURL
            }

            guard refreshGeneration == generation else { return .cancelled }
            hasLoaded = true
            failedOperation = nil
            return publishedFirstBatch ? .published : .noContent
        } catch {
            guard refreshGeneration == generation else { return .cancelled }
            if error.isNativeRequestCancellation || error is CancellationError {
                return .cancelled
            }
            errorMessage = error.localizedDescription
            failedOperation = .initial
            return publishedFirstBatch ? .publishedPartially : .failed
        }
    }

    private func fetchRefreshPage(
        source: HomeRecommendationSource,
        after nextURL: URL?,
        deadline: Date
    ) async throws -> FeedPageDTO {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw RefreshLoopError.timedOut }
        let repository = repository
        return try await withThrowingTaskGroup(of: FeedPageDTO.self) { group in
            group.addTask {
                try await repository.fetchPage(source: source, after: nextURL)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000)
                )
                throw RefreshLoopError.timedOut
            }
            guard let first = try await group.next() else {
                throw RefreshLoopError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private func cancelActiveRefresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefreshGeneration = nil
        generation &+= 1
        isLoading = false
        isRefreshing = false
    }

    private func resetForCacheContextChange() {
        cancelFirstContinuationPrefetch()
        cancelActiveRefresh()
        items = []
        nextURL = nil
        isEnd = false
        hasLoaded = false
        loadedSource = nil
        failedOperation = nil
        errorMessage = nil
        refreshMetadata = refreshTracker.clearing()
    }

    @discardableResult
    private func restoreCachedSnapshotForCurrentContext() async -> Bool {
        guard let context = currentCacheContext() else { return false }
        let persistence = cachePersistence
        let snapshot = await Task.detached(priority: .userInitiated) {
            persistence.load(for: context)
        }.value
        guard context == currentCacheContext(), let snapshot else { return false }
        items = snapshot.items
        nextURL = snapshot.nextURL
        isEnd = snapshot.isEnd
        hasLoaded = true
        loadedSource = snapshot.source
        failedOperation = nil
        errorMessage = nil
        refreshMetadata = snapshot.refreshMetadata
        return true
    }

    private func persistSuccessfulSnapshot() {
        guard !items.isEmpty,
              let context = currentCacheContext(),
              loadedSource == context.source
        else { return }
        cachePersistence.save(
            HomeRecommendationCacheSnapshot(
                schemaVersion: HomeRecommendationCacheSnapshot.currentSchemaVersion,
                accountID: context.accountID,
                source: context.source,
                items: items,
                nextURL: nextURL,
                isEnd: isEnd,
                refreshMetadata: refreshMetadata,
                savedAt: now()
            ),
            for: context
        )
    }

    private func currentCacheContext() -> HomeRecommendationCacheContext? {
        HomeRecommendationCacheContext(
            accountID: cacheAccountID(),
            source: configuration().source
        )
    }

    private func appendUnique(_ incoming: [FeedItemDTO]) {
        var known = Set(items.map(\.id))
        items.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
    }

    private func scheduleFirstContinuationPrefetch() {
        guard automaticallyPrefetchesFirstContinuation,
              firstContinuationPrefetchTask == nil,
              hasNextPage
        else { return }
        let scheduledGeneration = generation
        firstContinuationPrefetchTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.generation == scheduledGeneration {
                    self.firstContinuationPrefetchTask = nil
                }
            }
            do {
                // Let the first-page List update and refresh-control dismissal
                // commit before beginning continuation work.
                try await Task.sleep(
                    nanoseconds: self?.firstContinuationPrefetchDelayNanoseconds ?? 0
                )
            } catch {
                return
            }
            guard let self,
                  self.generation == scheduledGeneration,
                  !self.isRefreshing,
                  self.hasNextPage
            else { return }
            await self.loadMore()
        }
    }

    private func cancelFirstContinuationPrefetch() {
        firstContinuationPrefetchTask?.cancel()
        firstContinuationPrefetchTask = nil
    }

    private func prefetchThumbnails(in items: [FeedItemDTO]) {
        guard !items.isEmpty else { return }
        let thumbnailPrefetcher = thumbnailPrefetcher
        Task(priority: .utility) {
            await thumbnailPrefetcher.prefetch(items: items)
        }
    }

    private enum FailedOperation {
        case initial
        case nextPage
    }

    private enum RefreshLoopError: LocalizedError {
        case timedOut

        var errorDescription: String? { "刷新超时，请稍后重试" }
    }
}

struct HomeRecommendationRefreshExecutionPolicy {
    static let maximumExtendedRequests = 6

    static func maximumRequests(for intent: HomeRecommendationRefreshIntent) -> Int {
        intent == .pull ? 1 : maximumExtendedRequests
    }
}

@MainActor
final class FollowNativeStore: ObservableObject {
    @Published var selectedSection: FollowSection = .recommendations
    @Published private(set) var recommendations = FollowPageState()
    @Published private(set) var moments = FollowPageState()
    @Published private(set) var recentUsers: [FollowingUserDTO] = []
    @Published private(set) var recentUsersErrorMessage: String?
    @Published private(set) var refreshMetadata: FeedChannelRefreshMetadata

    private let repository: FollowRepository
    private let refreshTracker: FeedChannelRefreshTracker
    private var recommendationGeneration: UInt64 = 0
    private var momentsGeneration: UInt64 = 0
    private var loadedRecentUsers = false

    init(
        repository: FollowRepository,
        refreshMetadataPersistence: FeedChannelRefreshMetadataPersisting = UserDefaultsFeedChannelRefreshMetadataPersistence(),
        refreshPolicy: FeedChannelRefreshPolicy = .oneHour,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        let refreshTracker = FeedChannelRefreshTracker(
            channel: .following,
            persistence: refreshMetadataPersistence,
            policy: refreshPolicy,
            now: now
        )
        self.refreshTracker = refreshTracker
        refreshMetadata = refreshTracker.load()
    }

    var isLoading: Bool { recommendations.isLoading || moments.isLoading }
    var isRefreshing: Bool {
        let page = selectedSection == .recommendations ? recommendations : moments
        return page.isLoading && page.hasLoaded
    }
    var isMomentsLoading: Bool { moments.isLoading }
    var isMomentsRefreshing: Bool { moments.isLoading && moments.hasLoaded }

    func loadInitialIfNeeded() async {
        async let page: Void = loadInitial(section: selectedSection)
        async let users: Void = loadRecentUsersIfNeeded()
        _ = await (page, users)
    }

    func select(_ section: FollowSection) {
        selectedSection = section
    }

    func accountDidChange() {
        recommendationGeneration &+= 1
        momentsGeneration &+= 1
        recommendations = FollowPageState()
        moments = FollowPageState()
        recentUsers = []
        recentUsersErrorMessage = nil
        loadedRecentUsers = false
        refreshMetadata = refreshTracker.clearing()
    }

    func loadIfNeeded(section: FollowSection) async {
        await loadInitial(section: section)
    }

    func loadMomentsIfNeeded() async {
        async let page: Void = loadInitial(section: .moments)
        async let users: Void = loadRecentUsersIfNeeded()
        _ = await (page, users)
    }

    func refresh(section: FollowSection) async {
        let didRefresh = await replace(section: section)
        if didRefresh, section == .recommendations { await reloadRecentUsers() }
    }

    func refresh() async {
        await refresh(section: selectedSection)
    }

    func recordLastViewed() {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata)
    }

    func recordLastViewed(at date: Date) {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata, at: date)
    }

    func needsRefreshAfterIdle() -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata)
    }

    func needsRefreshAfterIdle(at date: Date) -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata, at: date)
    }

    func retry(section: FollowSection) async {
        let page = section == .recommendations ? recommendations : moments
        if page.items.isEmpty {
            await replace(section: section)
        } else {
            await loadMore(section: section)
        }
    }

    func reloadRecentUsers() async {
        do {
            recentUsers = try await repository.fetchRecentUsers()
            loadedRecentUsers = true
            recentUsersErrorMessage = nil
        } catch {
            if error.isNativeRequestCancellation { return }
            loadedRecentUsers = true
            recentUsersErrorMessage = error.localizedDescription
        }
    }

    private func loadRecentUsersIfNeeded() async {
        guard !loadedRecentUsers else { return }
        await reloadRecentUsers()
    }

    private func loadInitial(section: FollowSection) async {
        let page = section == .recommendations ? recommendations : moments
        guard !page.hasLoaded else { return }
        await replace(section: section)
    }

    @discardableResult
    private func replace(section: FollowSection) async -> Bool {
        let page = section == .recommendations ? recommendations : moments
        guard !page.isLoading else { return false }
        let generation = advanceGeneration(section)
        update(section) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        do {
            let result = try await repository.fetchPage(section: section, after: nil)
            guard generation == currentGeneration(section) else { return false }
            update(section) { page in
                page.items = result.items
                page.nextURL = result.nextURL
                page.isEnd = result.isEnd
                page.hasLoaded = true
                page.isLoading = false
            }
            refreshMetadata = refreshTracker.recordingSuccessfulRefresh(in: refreshMetadata)
            return true
        } catch {
            guard generation == currentGeneration(section) else { return false }
            if error.isNativeRequestCancellation {
                update(section) { $0.isLoading = false }
                return false
            }
            update(section) { page in
                page.isLoading = false
                page.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func loadMore(section: FollowSection) async {
        let current = section == .recommendations ? recommendations : moments
        guard current.canLoadMore, let nextURL = current.nextURL else { return }
        let generation = currentGeneration(section)
        update(section) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        do {
            let result = try await repository.fetchPage(section: section, after: nextURL)
            guard generation == currentGeneration(section) else { return }
            update(section) { page in
                var known = Set(page.items.map(\.id))
                page.items.append(contentsOf: result.items.filter { known.insert($0.id).inserted })
                page.nextURL = result.nextURL
                page.isEnd = result.isEnd
                page.isLoading = false
            }
        } catch {
            guard generation == currentGeneration(section) else { return }
            if error.isNativeRequestCancellation {
                update(section) { $0.isLoading = false }
                return
            }
            update(section) { page in
                page.isLoading = false
                page.errorMessage = error.localizedDescription
            }
        }
    }

    private func update(_ section: FollowSection, mutation: (inout FollowPageState) -> Void) {
        switch section {
        case .recommendations: mutation(&recommendations)
        case .moments: mutation(&moments)
        }
    }

    private func advanceGeneration(_ section: FollowSection) -> UInt64 {
        switch section {
        case .recommendations:
            recommendationGeneration &+= 1
            return recommendationGeneration
        case .moments:
            momentsGeneration &+= 1
            return momentsGeneration
        }
    }

    private func currentGeneration(_ section: FollowSection) -> UInt64 {
        section == .recommendations ? recommendationGeneration : momentsGeneration
    }
}
