import Foundation
import XCTest
@testable import iosApp

@MainActor
final class FlightOfflineFeatureTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testOfflineAnswerRouteKeepsPreparedOrderAndStopsPagination() throws {
        let first = answer(answerID: 11, authorName: "甲")
        let second = answer(answerID: 12, authorName: "乙")
        let question = FlightOfflineQuestionEntry(
            questionID: 42,
            title: "离线问题",
            answers: [first, second]
        )

        let route = question.answerRoute(for: second)
        let source = try XCTUnwrap(route.source)

        XCTAssertEqual(route.contentID, 12)
        XCTAssertEqual(route.questionID, 42)
        XCTAssertEqual(route.provisionalTitle, "离线问题")
        XCTAssertEqual(source.sourceName, "离线阅读")
        XCTAssertEqual(source.orderedAnswers.map(\.answerID), [11, 12])
        XCTAssertEqual(source.selectedAnswerID, 12)
        XCTAssertNil(source.nextURL)
    }

    func testPolicyCalculatesReadingTimeAndRejectsAnotherAccount() {
        XCTAssertEqual(
            FlightOfflinePackPolicy.estimatedMinutes(answerCount: 8, articleCount: 4),
            20
        )
        let pack = makePack(accountID: "account-a")

        XCTAssertTrue(FlightOfflinePackPolicy.valid(
            pack,
            accountID: "account-a",
            now: referenceDate
        ))
        XCTAssertFalse(FlightOfflinePackPolicy.valid(
            pack,
            accountID: "account-b",
            now: referenceDate
        ))
    }

    func testFilePersistenceIsAccountScopedAndRemoveIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineFeatureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = referenceDate
        let persistence = FileFlightOfflinePackPersistence(
            directory: directory,
            now: { referenceDate }
        )
        let pack = makePack(accountID: "account-a")

        try persistence.save(pack, accountID: "account-a")

        XCTAssertEqual(persistence.load(accountID: "account-a"), pack)
        XCTAssertNil(persistence.load(accountID: "account-b"))
        try persistence.remove(accountID: "account-a")
        try persistence.remove(accountID: "account-a")
        XCTAssertNil(persistence.load(accountID: "account-a"))
    }

    func testCorruptPersistedPackIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineCorruptionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = referenceDate
        let persistence = FileFlightOfflinePackPersistence(
            directory: directory,
            now: { referenceDate }
        )
        try persistence.save(makePack(accountID: "account-a"), accountID: "account-a")
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("not-json".utf8).write(to: file, options: .atomic)

        XCTAssertNil(persistence.load(accountID: "account-a"))
    }

    func testDiscardingStagedUpdatePreservesPreviousPack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineStagingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = referenceDate
        let persistence = FileFlightOfflinePackPersistence(
            directory: directory,
            now: { referenceDate }
        )
        let original = makePack(accountID: "account-a")
        let replacement = FlightOfflinePack(
            schemaVersion: FlightOfflinePack.currentSchemaVersion,
            accountID: "account-a",
            source: .web,
            createdAt: referenceDate,
            questions: original.questions,
            standalone: original.standalone,
            estimatedReadingMinutes: original.estimatedReadingMinutes
        )
        try persistence.save(original, accountID: "account-a")

        let staged = try persistence.stage(replacement, accountID: "account-a")
        persistence.discard(staged)

        XCTAssertEqual(persistence.load(accountID: "account-a"), original)
    }

    func testExpiredManifestIsRejectedAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineExpiryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = referenceDate
        let persistence = FileFlightOfflinePackPersistence(
            directory: directory,
            now: { referenceDate }
        )
        try persistence.save(makePack(accountID: "account-a"), accountID: "account-a")
        let expiredDate = referenceDate.addingTimeInterval(
            FlightOfflinePackPolicy.maximumAge + 1
        )
        let expiredPersistence = FileFlightOfflinePackPersistence(
            directory: directory,
            now: { expiredDate }
        )

        XCTAssertNil(expiredPersistence.load(accountID: "account-a"))
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty
        )
    }

    func testProgressClampsItsFractionAndBuildsAccessibleValue() {
        let progress = FlightOfflineProgress(
            completedUnitCount: 12,
            totalUnitCount: 10,
            questionCount: 2,
            answerCount: 6,
            status: "正在缓存回答正文"
        )

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.accessibilityValue, "100%，正在缓存回答正文")
    }

    func testStorePreparationPersistsQuestionAndUsesStrictWarmForEveryRequiredRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineStoreSuccessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileFlightOfflinePackPersistence(directory: directory)
        let homeRepository = FlightHomeRepositoryStub(page: .flightQuestion)
        let questionRepository = FlightQuestionAnswerRepositoryStub(failAnswerBody: false)
        let store = FlightOfflinePackStore(
            homeRepository: homeRepository,
            questionAnswerRepository: questionRepository,
            persistence: persistence,
            accountID: { "account-a" },
            recommendationSource: { .web }
        )

        store.startPreparation()
        try await waitForPreparation(of: store)

        let pack = try XCTUnwrap(store.pack)
        XCTAssertEqual(pack.accountID, "account-a")
        XCTAssertEqual(pack.source, .web)
        XCTAssertEqual(pack.questions.map(\.questionID), [42])
        XCTAssertEqual(pack.questions.first?.answers.map(\.answerID), [11])
        XCTAssertEqual(
            persistence.load(accountID: "account-a")?.questions.first?.answers.map(\.answerID),
            [11]
        )
        let requestedSources = await homeRepository.requestedSources()
        XCTAssertEqual(requestedSources, [.web])

        let reads = await questionRepository.recordedReads()
        XCTAssertEqual(Set(reads.map(\.operation)), Set([
            .question(42),
            .answerPage(42),
            .answer(11),
            .collections(11),
        ]))
        XCTAssertTrue(reads.allSatisfy { $0.policy == .offlinePackWarm })
    }

    func testStorePreparationRejectsQuestionWhenRequiredAnswerBodyWarmFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FlightOfflineStoreFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileFlightOfflinePackPersistence(directory: directory)
        let homeRepository = FlightHomeRepositoryStub(page: .flightQuestion)
        let questionRepository = FlightQuestionAnswerRepositoryStub(failAnswerBody: true)
        let store = FlightOfflinePackStore(
            homeRepository: homeRepository,
            questionAnswerRepository: questionRepository,
            persistence: persistence,
            accountID: { "account-a" },
            recommendationSource: { .app }
        )

        store.startPreparation()
        try await waitForPreparation(of: store)

        XCTAssertNil(store.pack)
        XCTAssertNil(persistence.load(accountID: "account-a"))
        guard case .failed = store.state else {
            return XCTFail("正文缓存失败且无其他内容时应进入失败状态")
        }
        let reads = await questionRepository.recordedReads()
        XCTAssertTrue(reads.contains {
            $0.operation == .answer(11) && $0.policy == .offlinePackWarm
        })
        XCTAssertTrue(reads.contains {
            $0.operation == .collections(11) && $0.policy == .offlinePackWarm
        })
    }

    private func waitForPreparation(of store: FlightOfflinePackStore) async throws {
        for _ in 0..<500 {
            guard store.isPreparing else { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("离线包准备未在测试超时内结束")
    }

    private func makePack(accountID: String) -> FlightOfflinePack {
        FlightOfflinePack(
            schemaVersion: FlightOfflinePack.currentSchemaVersion,
            accountID: accountID,
            source: .app,
            createdAt: referenceDate,
            questions: [
                FlightOfflineQuestionEntry(
                    questionID: 42,
                    title: "离线问题",
                    answers: [answer(answerID: 11, authorName: "作者")]
                ),
            ],
            standalone: [
                FlightOfflineStandaloneEntry(
                    contentID: 99,
                    kind: .article,
                    title: "离线文章",
                    authorName: "作者",
                    excerpt: "摘要"
                ),
            ],
            estimatedReadingMinutes: 4
        )
    }

    private func answer(
        answerID: Int64,
        authorName: String
    ) -> FlightOfflineAnswerSummary {
        FlightOfflineAnswerSummary(AnswerPreviewDTO(
            answerID: answerID,
            questionID: 42,
            questionTitle: "离线问题",
            author: QAAuthorDTO(
                memberID: "member-\(answerID)",
                urlToken: "member-\(answerID)",
                displayName: authorName,
                headline: "",
                avatarURL: nil
            ),
            excerpt: "回答摘要",
            voteUpCount: 10,
            commentCount: 2
        ))
    }
}

private actor FlightHomeRepositoryStub: HomeFeedRepository {
    private let page: FeedPageDTO
    private var sources: [HomeRecommendationSource] = []

    init(page: FeedPageDTO) {
        self.page = page
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        try await fetchPage(source: .app, after: nextURL)
    }

    func fetchPage(
        source: HomeRecommendationSource,
        after nextURL: URL?
    ) async throws -> FeedPageDTO {
        sources.append(source)
        return page
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func requestedSources() -> [HomeRecommendationSource] { sources }
}

private actor FlightQuestionAnswerRepositoryStub: QuestionAnswerRepository {
    private let failAnswerBody: Bool
    private var reads: [FlightRecordedRead] = []

    init(failAnswerBody: Bool) {
        self.failAnswerBody = failAnswerBody
    }

    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO {
        try await fetchQuestion(route, cachePolicy: .disabled)
    }

    func fetchQuestion(
        _ route: QuestionRouteDTO,
        cachePolicy: ZhihuAPICachePolicy
    ) async throws -> QuestionDTO {
        record(.question(route.questionID), policy: cachePolicy)
        return .flightQuestion
    }

    func fetchQuestionAnswers(
        questionID: Int64,
        sort: QuestionAnswerSort,
        after nextURL: URL?
    ) async throws -> QuestionAnswerPageDTO {
        try await fetchQuestionAnswers(
            questionID: questionID,
            sort: sort,
            after: nextURL,
            cachePolicy: .disabled
        )
    }

    func fetchQuestionAnswers(
        questionID: Int64,
        sort: QuestionAnswerSort,
        after nextURL: URL?,
        cachePolicy: ZhihuAPICachePolicy
    ) async throws -> QuestionAnswerPageDTO {
        record(.answerPage(questionID), policy: cachePolicy)
        return .flightAnswers
    }

    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws {}

    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO {
        try await fetchAnswer(route, cachePolicy: .disabled)
    }

    func fetchAnswer(
        _ route: AnswerRouteDTO,
        cachePolicy: ZhihuAPICachePolicy
    ) async throws -> AnswerDTO {
        record(.answer(route.contentID), policy: cachePolicy)
        if failAnswerBody { throw FlightOfflineStoreTestError.requiredBodyFailed }
        return .flightAnswer
    }

    func setVote(
        _ state: QAVoteState,
        route: AnswerRouteDTO
    ) async throws -> QAVoteMutationResult {
        QAVoteMutationResult(state: state, voteUpCount: 0)
    }

    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult {
        try await fetchCollections(route: route, cachePolicy: .disabled)
    }

    func fetchCollections(
        route: AnswerRouteDTO,
        cachePolicy: ZhihuAPICachePolicy
    ) async throws -> QACollectionsResult {
        record(.collections(route.contentID), policy: cachePolicy)
        return QACollectionsResult(items: [], favoriteState: .notFavorited)
    }

    func setCollection(
        _ selected: Bool,
        collectionID: String,
        route: AnswerRouteDTO
    ) async throws {}

    func recordReadHistory(contentToken: String, contentType: String) async {}

    func recordedReads() -> [FlightRecordedRead] { reads }

    private func record(
        _ operation: FlightRecordedRead.Operation,
        policy: ZhihuAPICachePolicy
    ) {
        reads.append(FlightRecordedRead(
            operation: operation,
            policy: FlightRecordedRead.Policy(policy)
        ))
    }
}

private struct FlightRecordedRead: Equatable, Sendable {
    enum Operation: Hashable, Sendable {
        case question(Int64)
        case answerPage(Int64)
        case answer(Int64)
        case collections(Int64)
    }

    enum Policy: Equatable, Sendable {
        case disabled
        case offlineFallback
        case cacheFirst
        case cacheOnly
        case offlinePackWarm

        init(_ policy: ZhihuAPICachePolicy) {
            switch policy {
            case .disabled: self = .disabled
            case .offlineFallback: self = .offlineFallback
            case .cacheFirst: self = .cacheFirst
            case .cacheOnly: self = .cacheOnly
            case .offlinePackWarm: self = .offlinePackWarm
            }
        }
    }

    let operation: Operation
    let policy: Policy
}

private enum FlightOfflineStoreTestError: Error {
    case requiredBodyFailed
}

private extension FeedPageDTO {
    static let flightQuestion = FeedPageDTO(
        items: [
            FeedItemDTO(
                id: FeedItemID(kind: .question, contentID: "42"),
                kind: .question,
                title: "离线问题",
                summary: "问题摘要",
                details: "问题详情",
                sourceLabel: nil,
                author: nil,
                thumbnailURL: nil,
                route: .question(questionID: 42, title: "离线问题")
            ),
        ],
        nextURL: nil,
        isEnd: true
    )
}

private extension QuestionDTO {
    static let flightQuestion = QuestionDTO(
        id: 42,
        title: "离线问题",
        detailHTML: "<p>问题详情</p>",
        detailBlocks: [],
        answerCount: 1,
        visitCount: 1,
        commentCount: 0,
        followerCount: 0,
        isFollowing: false,
        author: nil,
        topics: []
    )
}

private extension QuestionAnswerPageDTO {
    static let flightAnswers = QuestionAnswerPageDTO(
        items: [
            AnswerPreviewDTO(
                answerID: 11,
                questionID: 42,
                questionTitle: "离线问题",
                author: .flightAuthor,
                excerpt: "回答摘要",
                voteUpCount: 10,
                commentCount: 2
            ),
        ],
        nextURL: nil,
        isEnd: true
    )
}

private extension QAAuthorDTO {
    static let flightAuthor = QAAuthorDTO(
        memberID: "flight-author",
        urlToken: "flight-author",
        displayName: "离线作者",
        headline: "",
        avatarURL: nil
    )
}

private extension AnswerDTO {
    static let flightAnswer = AnswerDTO(
        route: AnswerRouteDTO(
            contentID: 11,
            kind: .answer,
            questionID: 42,
            provisionalTitle: "离线问题"
        ),
        title: "离线问题",
        questionID: 42,
        author: .flightAuthor,
        blocks: [],
        attachment: nil,
        sourceURL: URL(string: "https://www.zhihu.com/question/42/answer/11")!,
        voteUpCount: 10,
        favoriteCount: 0,
        commentCount: 2,
        voteState: .neutral,
        favoriteState: .notFavorited,
        createdTimeSeconds: 1,
        updatedTimeSeconds: 1,
        ipLocation: nil,
        invitationPreface: nil,
        endorsements: []
    )
}
