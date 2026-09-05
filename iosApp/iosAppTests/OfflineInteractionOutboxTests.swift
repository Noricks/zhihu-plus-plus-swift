import Foundation
import XCTest
@testable import iosApp

final class OfflineInteractionOutboxTests: XCTestCase {
    override func tearDown() {
        OfflineInteractionURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testAbsoluteDesiredStatesCoalesceAndSurviveReconstruction() async throws {
        let storage = LockedOfflineInteractionStorage()
        let executor = SequencedOfflineInteractionExecutor()
        let original = DurableOfflineInteractionOutbox(storage: storage, executor: executor)
        let route = AnswerRouteDTO(contentID: 42, kind: .answer)

        let first = try await original.enqueue(
            accountID: "account-a",
            mutation: .vote(.up, route: route)
        )
        let second = try await original.enqueue(
            accountID: "account-a",
            mutation: .vote(.neutral, route: route)
        )

        XCTAssertGreaterThan(second.revision, first.revision)
        let originalPending = try await original.pending(accountID: "account-a")
        XCTAssertEqual(originalPending.count, 1)
        XCTAssertEqual(originalPending.first?.mutation, .vote(.neutral, route: route))

        let reconstructed = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: executor
        )
        let restored = try await reconstructed.pending(accountID: "account-a")
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.revision, second.revision)
        XCTAssertEqual(restored.first?.mutation, .vote(.neutral, route: route))
    }

    func testFileStoragePersistsAtomicEnvelope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineInteractionOutboxTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = JSONFileOfflineInteractionOutboxStorage(
            fileURL: root.appendingPathComponent("outbox.json")
        )
        let executor = SequencedOfflineInteractionExecutor()
        let first = DurableOfflineInteractionOutbox(storage: storage, executor: executor)

        let receipt = try await first.enqueue(
            accountID: "account-a",
            mutation: .commentLike(commentID: "comment-1", isLiked: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL.path))

        let restored = DurableOfflineInteractionOutbox(storage: storage, executor: executor)
        let pending = try await restored.pending(accountID: "account-a")
        XCTAssertEqual(pending.map(\.revision), [receipt.revision])
        XCTAssertEqual(
            pending.map(\.mutation),
            [.commentLike(commentID: "comment-1", isLiked: true)]
        )
    }

    func testAccountScopeSeparatesSameTargetAndFlushesOnlySelectedAccount() async throws {
        let storage = LockedOfflineInteractionStorage()
        let executor = SequencedOfflineInteractionExecutor()
        let outbox = DurableOfflineInteractionOutbox(storage: storage, executor: executor)
        let target = OfflineInteractionMutation.pinLike(pinID: 7, isLiked: true)

        try await outbox.enqueue(accountID: "account-a", mutation: target)
        try await outbox.enqueue(
            accountID: "account-b",
            mutation: .pinLike(pinID: 7, isLiked: false)
        )

        let report = try await outbox.flush(accountID: "account-a", force: true)
        XCTAssertEqual(report.delivered.count, 1)
        XCTAssertEqual(report.remainingCount, 0)
        let accountAPending = try await outbox.pending(accountID: "account-a")
        let accountBPending = try await outbox.pending(accountID: "account-b")
        XCTAssertTrue(accountAPending.isEmpty)
        XCTAssertEqual(accountBPending.count, 1)

        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.map(\.accountID), ["account-a"])
        XCTAssertEqual(calls.map(\.mutation), [target])
        let accountBOverlay = try await outbox.overlay(accountID: "account-b")
        XCTAssertFalse(accountBOverlay.pinLike(
            pinID: 7,
            serverIsLiked: true,
            serverLikeCount: 5
        ).value)
    }

    func testRemoveAllDurablyDeletesOnlyRequestedAccount() async throws {
        let storage = LockedOfflineInteractionStorage()
        let executor = SequencedOfflineInteractionExecutor()
        let outbox = DurableOfflineInteractionOutbox(storage: storage, executor: executor)
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .pinLike(pinID: 1, isLiked: true)
        )
        try await outbox.enqueue(
            accountID: "account-b",
            mutation: .commentLike(commentID: "comment-2", isLiked: true)
        )

        try await outbox.removeAll(accountID: "account-a")

        let reconstructed = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: executor
        )
        let accountA = try await reconstructed.pending(accountID: "account-a")
        let accountB = try await reconstructed.pending(accountID: "account-b")
        XCTAssertTrue(accountA.isEmpty)
        XCTAssertEqual(accountB.map(\.mutation), [
            .commentLike(commentID: "comment-2", isLiked: true),
        ])
    }

    func testOversizedPersistenceIsClearedAndFailsClosedOnce() async throws {
        let storage = LockedOfflineInteractionStorage(
            data: Data(
                repeating: 0x41,
                count: OfflineInteractionPersistenceLimits.maximumByteCount + 1
            )
        )
        let outbox = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: SequencedOfflineInteractionExecutor()
        )

        do {
            _ = try await outbox.pending(accountID: "account-a")
            XCTFail("Expected persistenceTooLarge")
        } catch OfflineInteractionOutboxError.persistenceTooLarge {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recoveredData = try XCTUnwrap(storage.storedData())
        XCTAssertLessThan(recoveredData.count, OfflineInteractionPersistenceLimits.maximumByteCount)
        let recovered = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(recovered.isEmpty)
    }

    func testMalformedPersistenceIsReplacedWithValidEmptyEnvelope() async throws {
        let storage = LockedOfflineInteractionStorage(data: Data("not-json".utf8))
        let outbox = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: SequencedOfflineInteractionExecutor()
        )

        do {
            _ = try await outbox.pending(accountID: "account-a")
            XCTFail("Expected corruptPersistence")
        } catch OfflineInteractionOutboxError.corruptPersistence {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let replacement = try XCTUnwrap(storage.storedData())
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: replacement))
        let recovered = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(recovered.isEmpty)
    }

    func testOverlayProjectsEverySupportedInteractionAndSafeCountDeltas() async throws {
        let storage = LockedOfflineInteractionStorage()
        let outbox = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: SequencedOfflineInteractionExecutor()
        )
        let answer = AnswerRouteDTO(contentID: 1, kind: .answer)
        let article = AnswerRouteDTO(contentID: 2, kind: .article)

        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .vote(.up, route: answer)
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .vote(.neutral, route: article)
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .collection(true, collectionID: "collection-1", route: answer)
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .pinLike(pinID: 3, isLiked: false)
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .commentLike(commentID: "comment-4", isLiked: true)
        )

        let overlay = try await outbox.overlay(accountID: "account-a")
        XCTAssertEqual(overlay.pendingCount, 5)
        XCTAssertEqual(
            overlay.vote(route: answer, serverState: .neutral, serverVoteUpCount: 10),
            OfflineVoteOverlay(state: .up, voteUpCount: 11, isPending: true, revision: 1)
        )
        XCTAssertEqual(
            overlay.vote(route: article, serverState: .up, serverVoteUpCount: 10),
            OfflineVoteOverlay(state: .neutral, voteUpCount: 9, isPending: true, revision: 2)
        )
        XCTAssertEqual(
            overlay.collectionMembership(
                route: answer,
                collectionID: "collection-1",
                serverIsMember: false
            ).value,
            true
        )
        XCTAssertEqual(
            overlay.collections(
                route: answer,
                serverCollections: [
                    QACollectionDTO(id: "collection-1", title: "Synthetic", isFavorited: false),
                ]
            ).first?.isFavorited,
            true
        )
        XCTAssertEqual(
            overlay.pinLike(pinID: 3, serverIsLiked: true, serverLikeCount: 5),
            OfflineCountedBooleanOverlay(value: false, count: 4, isPending: true, revision: 4)
        )
        XCTAssertEqual(
            overlay.commentLike(
                commentID: "comment-4",
                serverIsLiked: false,
                serverLikeCount: 0
            ),
            OfflineCountedBooleanOverlay(value: true, count: 1, isPending: true, revision: 5)
        )
    }

    func testArticleDownvoteIsRejectedBeforePersistence() async throws {
        let storage = LockedOfflineInteractionStorage()
        let outbox = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: SequencedOfflineInteractionExecutor()
        )

        do {
            try await outbox.enqueue(
                accountID: "account-a",
                mutation: .contentVote(kind: .article, contentID: 2, state: .down)
            )
            XCTFail("Expected unsupported desired state")
        } catch OfflineInteractionOutboxError.unsupportedDesiredState {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(storage.storedData())
    }

    func testStaleCompletionCannotDeleteNewerRevision() async throws {
        let storage = LockedOfflineInteractionStorage()
        let executor = GatedOfflineInteractionExecutor()
        let outbox = DurableOfflineInteractionOutbox(storage: storage, executor: executor)
        let route = AnswerRouteDTO(contentID: 42, kind: .answer)
        let first = try await outbox.enqueue(
            accountID: "account-a",
            mutation: .vote(.up, route: route)
        )

        let flushing = Task {
            try await outbox.flush(accountID: "account-a", force: true)
        }
        try await waitForCallCount(1, executor: executor)
        let second = try await outbox.enqueue(
            accountID: "account-a",
            mutation: .vote(.down, route: route)
        )
        await executor.releaseFirstCall()

        let report = try await flushing.value
        XCTAssertEqual(report.supersededRevisions, [first.revision])
        XCTAssertEqual(report.delivered.map(\.revision), [second.revision])
        let pending = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(pending.isEmpty)
        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.map(\.mutation), [
            .vote(.up, route: route),
            .vote(.down, route: route),
        ])
    }

    func testConnectivityFailurePersistsBackoffAndRetriesWhenDue() async throws {
        let storage = LockedOfflineInteractionStorage()
        let clock = LockedOfflineInteractionClock(Date(timeIntervalSince1970: 1_000))
        let executor = SequencedOfflineInteractionExecutor(outcomes: [
            .connectivityFailure,
            .success(.accepted),
        ])
        let outbox = DurableOfflineInteractionOutbox(
            storage: storage,
            executor: executor,
            retryPolicy: .init(initialDelay: 4, maximumDelay: 30),
            now: { clock.value() }
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .commentLike(commentID: "comment-1", isLiked: true)
        )

        let failed = try await outbox.flush(accountID: "account-a")
        XCTAssertEqual(failed.stoppedBy, .connectivity)
        XCTAssertEqual(
            failed.earliestRetryAt,
            Date(timeIntervalSince1970: 1_004)
        )
        var callCount = await executor.callCount()
        XCTAssertEqual(callCount, 1)

        let tooEarly = try await outbox.flush(accountID: "account-a")
        XCTAssertTrue(tooEarly.delivered.isEmpty)
        callCount = await executor.callCount()
        XCTAssertEqual(callCount, 1)

        clock.advance(by: 4)
        let retried = try await outbox.flush(accountID: "account-a")
        XCTAssertEqual(retried.delivered.count, 1)
        XCTAssertEqual(retried.remainingCount, 0)
        callCount = await executor.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testForcedFlushAttemptsBlockedRevisionOnlyOncePerPass() async throws {
        let executor = SequencedOfflineInteractionExecutor(outcomes: [
            .apiStatusFailure(400),
            .success(.accepted),
        ])
        let outbox = DurableOfflineInteractionOutbox(
            storage: LockedOfflineInteractionStorage(),
            executor: executor
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .commentLike(commentID: "comment-1", isLiked: true)
        )

        let first = try await outbox.flush(accountID: "account-a", force: true)
        XCTAssertEqual(first.remainingCount, 1)
        var pending = try await outbox.pending(accountID: "account-a")
        XCTAssertEqual(pending.first?.isBlocked, true)
        var callCount = await executor.callCount()
        XCTAssertEqual(callCount, 1)

        let second = try await outbox.flush(accountID: "account-a", force: true)
        XCTAssertEqual(second.delivered.count, 1)
        pending = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(pending.isEmpty)
        callCount = await executor.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testZhihuExecutorMatchesRepositoryRequestsAndPinsExpectedAccount() async throws {
        let recorder = OfflineInteractionRequestRecorder()
        OfflineInteractionURLProtocol.setHandler { request in
            recorder.record(request)
            let body: Data
            if request.url?.path.hasSuffix("/voters") == true {
                body = Data(#"{"voteup_count":12}"#.utf8)
            } else if request.url?.path.hasSuffix("/voters/up") == true {
                body = Data(#"{"liked_count":8}"#.utf8)
            } else {
                body = Data("{}".utf8)
            }
            return (200, body)
        }
        let accountStore = OfflineInteractionAccountStore(currentAccountID: "account-a")
        let client = makeClient(accountStore: accountStore)
        let executor = ZhihuOfflineInteractionExecutor(client: client)

        let answerAcknowledgement = try await executor.execute(
            accountID: "account-a",
            mutation: .contentVote(kind: .answer, contentID: 1, state: .down)
        )
        XCTAssertEqual(answerAcknowledgement, .vote(voteUpCount: 12))
        let articleAcknowledgement = try await executor.execute(
            accountID: "account-a",
            mutation: .contentVote(kind: .article, contentID: 2, state: .neutral)
        )
        XCTAssertEqual(articleAcknowledgement, .vote(voteUpCount: 12))
        _ = try await executor.execute(
            accountID: "account-a",
            mutation: .collectionMembership(
                kind: .answer,
                contentID: 1,
                collectionID: "collection-1",
                isMember: true
            )
        )
        let pinAcknowledgement = try await executor.execute(
            accountID: "account-a",
            mutation: .pinLike(pinID: 3, isLiked: false)
        )
        XCTAssertEqual(pinAcknowledgement, .like(likeCount: 8))
        _ = try await executor.execute(
            accountID: "account-a",
            mutation: .commentLike(commentID: "comment/4", isLiked: true)
        )

        let requests = recorder.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "PUT", "DELETE", "POST"])
        XCTAssertEqual(requests.map { $0.url?.host }, [
            "www.zhihu.com", "www.zhihu.com", "api.zhihu.com", "www.zhihu.com", "www.zhihu.com",
        ])
        XCTAssertEqual(requests[0].url?.path, "/api/v4/answers/1/voters")
        XCTAssertEqual(requests[1].url?.path, "/api/v4/articles/2/voters")
        XCTAssertEqual(requests[2].url?.path, "/collections/contents/answer/1")
        XCTAssertEqual(requests[3].url?.path, "/api/v4/pins/3/voters/up")
        XCTAssertTrue(requests[4].url?.absoluteString.contains("comments/comment%2F4/like") == true)
        XCTAssertEqual(
            try jsonObject(requests[0])["type"] as? String,
            "down"
        )
        XCTAssertEqual(
            try jsonObject(requests[1])["voting"] as? Int,
            0
        )
        XCTAssertEqual(String(data: try XCTUnwrap(requests[2].httpBody), encoding: .utf8),
                       "add_collections=collection-1")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )

        accountStore.setCurrentAccountID("account-b")
        do {
            _ = try await executor.execute(
                accountID: "account-a",
                mutation: .pinLike(pinID: 9, isLiked: true)
            )
            XCTFail("Expected accountChanged")
        } catch ZhihuAPIError.accountChanged {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.requests().count, 5)
    }

    @MainActor
    func testCoordinatorPublishesOptimisticOverlayAndRetriesOnNetworkRecovery() async throws {
        let executor = SequencedOfflineInteractionExecutor()
        let outbox = DurableOfflineInteractionOutbox(
            storage: LockedOfflineInteractionStorage(),
            executor: executor
        )
        let connectivity = ManualOfflineInteractionConnectivityMonitor()
        let coordinator = OfflineInteractionCoordinator(
            outbox: outbox,
            accountID: { "account-a" },
            connectivity: connectivity
        )
        coordinator.start()
        connectivity.send(false)
        await Task.yield()

        try await coordinator.setPinLiked(true, pinID: 7)
        XCTAssertEqual(coordinator.overlay.pendingCount, 1)
        XCTAssertEqual(
            coordinator.overlay.pinLike(
                pinID: 7,
                serverIsLiked: false,
                serverLikeCount: 2
            ).count,
            3
        )
        var callCount = await executor.callCount()
        XCTAssertEqual(callCount, 0)

        connectivity.send(true)
        let delivered = await eventually { await executor.callCount() == 1 }
        XCTAssertTrue(delivered)
        let overlayCleared = await eventually { @MainActor in
            coordinator.overlay.pendingCount == 0
        }
        XCTAssertTrue(overlayCleared)
        callCount = await executor.callCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testCoordinatorRemovingNoncurrentAccountDoesNotCancelCurrentDelivery() async throws {
        let executor = DelayedOfflineInteractionExecutor(delayNanoseconds: 50_000_000)
        let outbox = DurableOfflineInteractionOutbox(
            storage: LockedOfflineInteractionStorage(),
            executor: executor
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .pinLike(pinID: 1, isLiked: true)
        )
        try await outbox.enqueue(
            accountID: "account-b",
            mutation: .pinLike(pinID: 2, isLiked: true)
        )
        let accountStore = OfflineInteractionAccountStore(currentAccountID: "account-b")
        let coordinator = OfflineInteractionCoordinator(
            outbox: outbox,
            accountID: { try accountStore.currentAccountID() },
            connectivity: ManualOfflineInteractionConnectivityMonitor()
        )

        coordinator.start()
        let started = await eventually { await executor.callCount() == 1 }
        XCTAssertTrue(started)

        try await coordinator.removeAll(accountID: "account-a")

        let delivered = await eventually {
            guard let pending = try? await outbox.pending(accountID: "account-b") else {
                return false
            }
            return pending.isEmpty
        }
        XCTAssertTrue(delivered)
        let cancellationCount = await executor.cancellationCount()
        XCTAssertEqual(cancellationCount, 0)
        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.map(\.accountID), ["account-b"])
        let accountAPending = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(accountAPending.isEmpty)
    }

    @MainActor
    func testCoordinatorRestartsCurrentAccountAfterInterruptingDeletedAccount() async throws {
        let executor = FirstCallCancellationOfflineInteractionExecutor()
        let outbox = DurableOfflineInteractionOutbox(
            storage: LockedOfflineInteractionStorage(),
            executor: executor
        )
        try await outbox.enqueue(
            accountID: "account-a",
            mutation: .pinLike(pinID: 1, isLiked: true)
        )
        try await outbox.enqueue(
            accountID: "account-b",
            mutation: .pinLike(pinID: 2, isLiked: true)
        )
        let accountStore = OfflineInteractionAccountStore(currentAccountID: "account-a")
        let coordinator = OfflineInteractionCoordinator(
            outbox: outbox,
            accountID: { try accountStore.currentAccountID() },
            connectivity: ManualOfflineInteractionConnectivityMonitor()
        )

        coordinator.start()
        let started = await eventually { await executor.callCount() == 1 }
        XCTAssertTrue(started)
        accountStore.setCurrentAccountID("account-b")

        try await coordinator.removeAll(accountID: "account-a")

        let restarted = await eventually { await executor.callCount() == 2 }
        XCTAssertTrue(restarted)
        let cancellationCount = await executor.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        let delivered = await eventually {
            guard let pending = try? await outbox.pending(accountID: "account-b") else {
                return false
            }
            return pending.isEmpty
        }
        XCTAssertTrue(delivered)
        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.map(\.accountID), ["account-a", "account-b"])
        let accountAPending = try await outbox.pending(accountID: "account-a")
        XCTAssertTrue(accountAPending.isEmpty)
    }

    private func makeClient(accountStore: OfflineInteractionAccountStore) -> ZhihuAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineInteractionURLProtocol.self]
        return ZhihuAPIClient(
            accountStore: accountStore,
            session: URLSession(configuration: configuration),
            responseCache: DisabledZhihuAPIResponseCache()
        )
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForCallCount(
        _ expected: Int,
        executor: GatedOfflineInteractionExecutor
    ) async throws {
        let reached = await eventually { await executor.callCount() >= expected }
        if !reached { throw OfflineInteractionTestError.timedOut }
    }

    private func eventually(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

private final class LockedOfflineInteractionStorage:
    OfflineInteractionOutboxStorage,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func storedData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private struct OfflineInteractionExecutorCall: Equatable, Sendable {
    let accountID: String
    let mutation: OfflineInteractionMutation
}

private actor SequencedOfflineInteractionExecutor: OfflineInteractionExecuting {
    enum Outcome: Sendable {
        case success(OfflineInteractionAcknowledgement)
        case connectivityFailure
        case apiStatusFailure(Int)
    }

    private var outcomes: [Outcome]
    private var calls: [OfflineInteractionExecutorCall] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement {
        calls.append(.init(accountID: accountID, mutation: mutation))
        guard !outcomes.isEmpty else { return .accepted }
        switch outcomes.removeFirst() {
        case let .success(acknowledgement): return acknowledgement
        case .connectivityFailure: throw URLError(.notConnectedToInternet)
        case let .apiStatusFailure(status): throw ZhihuAPIError.httpStatus(status)
        }
    }

    func recordedCalls() -> [OfflineInteractionExecutorCall] { calls }
    func callCount() -> Int { calls.count }
}

private actor GatedOfflineInteractionExecutor: OfflineInteractionExecuting {
    private var calls: [OfflineInteractionExecutorCall] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement {
        calls.append(.init(accountID: accountID, mutation: mutation))
        if calls.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return .accepted
    }

    func releaseFirstCall() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func recordedCalls() -> [OfflineInteractionExecutorCall] { calls }
    func callCount() -> Int { calls.count }
}

private actor DelayedOfflineInteractionExecutor: OfflineInteractionExecuting {
    private let delayNanoseconds: UInt64
    private var calls: [OfflineInteractionExecutorCall] = []
    private var cancellations = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement {
        calls.append(.init(accountID: accountID, mutation: mutation))
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch is CancellationError {
            cancellations += 1
            throw CancellationError()
        }
        return .accepted
    }

    func recordedCalls() -> [OfflineInteractionExecutorCall] { calls }
    func callCount() -> Int { calls.count }
    func cancellationCount() -> Int { cancellations }
}

private actor FirstCallCancellationOfflineInteractionExecutor: OfflineInteractionExecuting {
    private var calls: [OfflineInteractionExecutorCall] = []
    private var cancellations = 0

    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement {
        calls.append(.init(accountID: accountID, mutation: mutation))
        if calls.count == 1 {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                cancellations += 1
                throw CancellationError()
            }
        }
        return .accepted
    }

    func recordedCalls() -> [OfflineInteractionExecutorCall] { calls }
    func callCount() -> Int { calls.count }
    func cancellationCount() -> Int { cancellations }
}

private final class LockedOfflineInteractionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date.addTimeInterval(interval)
        lock.unlock()
    }
}

private final class ManualOfflineInteractionConnectivityMonitor:
    OfflineInteractionConnectivityMonitoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var update: (@Sendable (Bool) -> Void)?

    func start(_ update: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        self.update = update
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        update = nil
        lock.unlock()
    }

    func send(_ available: Bool) {
        lock.lock()
        let callback = update
        lock.unlock()
        callback?(available)
    }
}

private final class OfflineInteractionAccountStore:
    MultipleAccountJSONStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var accountID: String?

    init(currentAccountID: String?) {
        accountID = currentAccountID
    }

    func load() throws -> String? {
        #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"offline-test"}"#
    }

    func save(_ accountJSON: String) throws {}
    func clear() throws {}

    func update(_ transform: (String?) throws -> String?) throws {
        _ = try transform(try load())
    }

    func listAccounts() throws -> [NativeSavedAccountSummary] { [] }

    func currentAccountID() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accountID
    }

    func switchAccount(to accountID: String) throws {
        setCurrentAccountID(accountID)
    }

    func deleteAccount(_ accountID: String) throws {}

    func clearCurrentAccount() throws {
        setCurrentAccountID(nil)
    }

    func setCurrentAccountID(_ accountID: String?) {
        lock.lock()
        self.accountID = accountID
        lock.unlock()
    }
}

private final class OfflineInteractionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class OfflineInteractionURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum OfflineInteractionTestError: Error {
    case timedOut
}
