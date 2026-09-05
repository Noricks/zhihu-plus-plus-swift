import CryptoKit
import Foundation
import SwiftUI

struct FlightOfflineAnswerSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    let answerID: Int64
    let authorID: String
    let authorURLToken: String
    let authorName: String
    let authorHeadline: String
    let authorAvatarURL: URL?
    let excerpt: String
    let voteUpCount: Int
    let commentCount: Int

    var id: Int64 { answerID }

    init(_ preview: AnswerPreviewDTO) {
        answerID = preview.answerID
        authorID = preview.author.memberID
        authorURLToken = preview.author.urlToken
        authorName = preview.author.displayName
        authorHeadline = preview.author.headline
        authorAvatarURL = preview.author.avatarURL
        excerpt = preview.excerpt
        voteUpCount = preview.voteUpCount
        commentCount = preview.commentCount
    }

    func preview(questionID: Int64, questionTitle: String) -> AnswerPreviewDTO {
        AnswerPreviewDTO(
            answerID: answerID,
            questionID: questionID,
            questionTitle: questionTitle,
            author: QAAuthorDTO(
                memberID: authorID,
                urlToken: authorURLToken,
                displayName: authorName,
                headline: authorHeadline,
                avatarURL: authorAvatarURL
            ),
            excerpt: excerpt,
            voteUpCount: voteUpCount,
            commentCount: commentCount
        )
    }
}

struct FlightOfflineQuestionEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let questionID: Int64
    let title: String
    let answers: [FlightOfflineAnswerSummary]

    var id: Int64 { questionID }

    var questionRoute: QuestionRouteDTO {
        QuestionRouteDTO(
            questionID: questionID,
            provisionalTitle: title,
            prefersCachedResponse: true
        )
    }

    func answerRoute(for answer: FlightOfflineAnswerSummary) -> AnswerRouteDTO {
        let orderedAnswers = answers.map {
            $0.preview(questionID: questionID, questionTitle: title)
        }
        return AnswerRouteDTO(
            contentID: answer.answerID,
            kind: .answer,
            questionID: questionID,
            provisionalTitle: title,
            source: AnswerPageSourceDTO(
                sourceName: "离线阅读",
                questionID: questionID,
                order: .default,
                orderedAnswers: orderedAnswers,
                selectedAnswerID: answer.answerID,
                nextURL: nil
            ),
            prefersCachedResponse: true
        )
    }
}

struct FlightOfflineStandaloneEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let contentID: Int64
    let kind: QAContentKind
    let title: String
    let authorName: String
    let excerpt: String

    var id: String { "\(kind.rawValue):\(contentID)" }

    var route: AnswerRouteDTO {
        AnswerRouteDTO(
            contentID: contentID,
            kind: kind,
            provisionalTitle: title,
            prefersCachedResponse: true
        )
    }
}

struct FlightOfflinePack: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountID: String
    let source: HomeRecommendationSource
    let createdAt: Date
    let questions: [FlightOfflineQuestionEntry]
    let standalone: [FlightOfflineStandaloneEntry]
    let estimatedReadingMinutes: Int

    var answerCount: Int {
        questions.reduce(0) { $0 + $1.answers.count }
            + standalone.count
    }

    var questionCount: Int { questions.count }
}

struct FlightOfflineProgress: Equatable, Sendable {
    let completedUnitCount: Int
    let totalUnitCount: Int
    let questionCount: Int
    let answerCount: Int
    let status: String

    var fractionCompleted: Double? {
        guard totalUnitCount > 0 else { return nil }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }

    var accessibilityValue: String {
        guard let fractionCompleted else { return status }
        return "\(Int((fractionCompleted * 100).rounded()))%，\(status)"
    }
}

enum FlightOfflinePreparationState: Equatable {
    case idle
    case preparing
    case cancelling
    case deleting
    case failed(String)
}

enum FlightOfflinePackPolicy {
    static let maximumAge: TimeInterval = 6 * 24 * 60 * 60
    static let maximumManifestByteCount = 512 * 1_024
    static let targetReadingMinutes = 20
    static let maximumRecommendationPages = 4
    static let maximumQuestions = 10
    static let answersPerQuestion = 3
    static let maximumStandaloneItems = 4
    static let estimatedMinutesPerAnswer = 1
    static let estimatedMinutesPerArticle = 3
    static let maximumStoredQuestions = 16
    static let maximumStoredAnswers = 64

    static func estimatedMinutes(answerCount: Int, articleCount: Int) -> Int {
        max(
            0,
            answerCount * estimatedMinutesPerAnswer
                + articleCount * estimatedMinutesPerArticle
        )
    }

    static func valid(
        _ pack: FlightOfflinePack,
        accountID: String,
        now: Date = Date()
    ) -> Bool {
        guard pack.schemaVersion == FlightOfflinePack.currentSchemaVersion,
              pack.accountID == accountID,
              pack.createdAt <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(pack.createdAt) <= maximumAge,
              !pack.questions.isEmpty || !pack.standalone.isEmpty,
              pack.questions.count <= maximumStoredQuestions,
              pack.answerCount <= maximumStoredAnswers,
              pack.questions.allSatisfy({
                  !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.answers.isEmpty
                      && $0.answers.count <= answersPerQuestion
              })
        else { return false }
        return true
    }
}

protocol FlightOfflinePackPersisting: Sendable {
    func load(accountID: String) -> FlightOfflinePack?
    func stage(
        _ pack: FlightOfflinePack,
        accountID: String
    ) throws -> FlightOfflineManifestWrite
    func commit(_ write: FlightOfflineManifestWrite) throws
    func discard(_ write: FlightOfflineManifestWrite)
    func remove(accountID: String) throws
}

struct FlightOfflineManifestWrite: Sendable {
    fileprivate let accountID: String
    fileprivate let stagedURL: URL
    fileprivate let destinationURL: URL
}

extension FlightOfflinePackPersisting {
    func save(_ pack: FlightOfflinePack, accountID: String) throws {
        let write = try stage(pack, accountID: accountID)
        do {
            try commit(write)
        } catch {
            discard(write)
            throw error
        }
    }
}

final class FileFlightOfflinePackPersistence:
    FlightOfflinePackPersisting,
    @unchecked Sendable
{
    private let directory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.directory = directory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("FlightOfflinePacks", isDirectory: true)
    }

    func load(accountID: String) -> FlightOfflinePack? {
        lock.withLock {
            let source = fileURL(accountID: accountID)
            guard let values = try? source.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
            ]),
                  values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  byteCount <= FlightOfflinePackPolicy.maximumManifestByteCount,
                  let data = try? Data(contentsOf: source, options: .mappedIfSafe),
                  let pack = try? JSONDecoder().decode(FlightOfflinePack.self, from: data),
                  FlightOfflinePackPolicy.valid(pack, accountID: accountID, now: now())
            else {
                try? fileManager.removeItem(at: source)
                return nil
            }
            return pack
        }
    }

    func stage(
        _ pack: FlightOfflinePack,
        accountID: String
    ) throws -> FlightOfflineManifestWrite {
        guard FlightOfflinePackPolicy.valid(pack, accountID: accountID, now: now()) else {
            throw FlightOfflinePackError.invalidPack
        }
        return try lock.withLock {
            try createProtectedDirectoryIfNeeded()
            let data = try JSONEncoder().encode(pack)
            guard data.count <= FlightOfflinePackPolicy.maximumManifestByteCount else {
                throw FlightOfflinePackError.invalidPack
            }
            let destination = fileURL(accountID: accountID)
            let staged = directory.appendingPathComponent(
                ".pending-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try data.write(to: staged, options: [.atomic])
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: staged.path
                )
                try excludeFromBackup(staged)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
            return FlightOfflineManifestWrite(
                accountID: accountID,
                stagedURL: staged,
                destinationURL: destination
            )
        }
    }

    func commit(_ write: FlightOfflineManifestWrite) throws {
        try lock.withLock {
            guard write.destinationURL == fileURL(accountID: write.accountID),
                  write.stagedURL.deletingLastPathComponent() == directory,
                  write.stagedURL.lastPathComponent.hasPrefix(".pending-"),
                  fileManager.fileExists(atPath: write.stagedURL.path)
            else { throw FlightOfflinePackError.invalidPack }
            if fileManager.fileExists(atPath: write.destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    write.destinationURL,
                    withItemAt: write.stagedURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(
                    at: write.stagedURL,
                    to: write.destinationURL
                )
            }
        }
    }

    func discard(_ write: FlightOfflineManifestWrite) {
        lock.withLock {
            guard write.stagedURL.deletingLastPathComponent() == directory,
                  write.stagedURL.lastPathComponent.hasPrefix(".pending-")
            else { return }
            try? fileManager.removeItem(at: write.stagedURL)
        }
    }

    func remove(accountID: String) throws {
        try lock.withLock {
            let destination = fileURL(accountID: accountID)
            guard fileManager.fileExists(atPath: destination.path) else { return }
            try fileManager.removeItem(at: destination)
        }
    }

    private func fileURL(accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func createProtectedDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        try excludeFromBackup(directory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

enum FlightOfflinePackError: LocalizedError, Equatable {
    case accountUnavailable
    case noReadableContent
    case invalidPack

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            return "请先登录知乎账号"
        case .noReadableContent:
            return "暂时没有可缓存的推荐内容，请联网后重试"
        case .invalidPack:
            return "离线内容保存失败，请重试"
        }
    }
}

private struct FlightOfflineQuestionSeed: Equatable, Sendable {
    let questionID: Int64
    let title: String
}

@MainActor
final class FlightOfflinePackStore: ObservableObject {
    @Published private(set) var pack: FlightOfflinePack?
    @Published private(set) var state: FlightOfflinePreparationState = .idle
    @Published private(set) var progress: FlightOfflineProgress?

    private let homeRepository: HomeFeedRepository
    private let questionAnswerRepository: QuestionAnswerRepository
    private let persistence: FlightOfflinePackPersisting
    private let accountID: @MainActor () -> String?
    private let recommendationSource: @MainActor () -> HomeRecommendationSource
    private let clearCachedResponses: @Sendable (String) async throws -> Void
    private var preparationTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var generation: UInt64 = 0

    init(
        homeRepository: HomeFeedRepository,
        questionAnswerRepository: QuestionAnswerRepository,
        persistence: FlightOfflinePackPersisting = FileFlightOfflinePackPersistence(),
        accountID: @escaping @MainActor () -> String?,
        recommendationSource: @escaping @MainActor () -> HomeRecommendationSource,
        clearCachedResponses: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.homeRepository = homeRepository
        self.questionAnswerRepository = questionAnswerRepository
        self.persistence = persistence
        self.accountID = accountID
        self.recommendationSource = recommendationSource
        self.clearCachedResponses = clearCachedResponses
    }

    var isPreparing: Bool {
        switch state {
        case .preparing, .cancelling, .deleting:
            return true
        case .idle, .failed:
            return false
        }
    }

    var accountRowStatus: String? {
        if state == .cancelling { return "正在取消" }
        if state == .deleting { return "正在删除" }
        if state == .preparing, let progress, let fraction = progress.fractionCompleted {
            return "准备中 \(Int((fraction * 100).rounded()))%"
        }
        if case .failed = state, pack == nil { return "需要重试" }
        if let pack { return "\(pack.questionCount) 个问题" }
        return nil
    }

    func reload() async {
        if let preparationTask {
            await preparationTask.value
        }
        guard let requestedAccountID = normalizedAccountID() else {
            pack = nil
            state = .idle
            progress = nil
            return
        }
        generation &+= 1
        let acceptedGeneration = generation
        let persistence = persistence
        let loaded = await Task.detached(priority: .utility) {
            persistence.load(accountID: requestedAccountID)
        }.value
        guard acceptedGeneration == generation else { return }
        guard requestedAccountID == normalizedAccountID() else { return }
        pack = loaded
        if !isPreparing { state = .idle }
    }

    func accountDidChange() {
        cancelPreparation()
        pack = nil
        Task { await reload() }
    }

    func startPreparation() {
        guard preparationTask == nil else { return }
        guard let requestedAccountID = normalizedAccountID() else {
            state = .failed(FlightOfflinePackError.accountUnavailable.localizedDescription)
            return
        }

        generation &+= 1
        let acceptedGeneration = generation
        let operationID = UUID()
        activeOperationID = operationID
        let source = recommendationSource()
        state = .preparing
        progress = FlightOfflineProgress(
            completedUnitCount: 0,
            totalUnitCount: 0,
            questionCount: 0,
            answerCount: 0,
            status: "正在获取推荐内容"
        )
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var stagedWrite: FlightOfflineManifestWrite?
            defer {
                self.finishOperation(operationID)
            }
            do {
                let prepared = try await buildPack(
                    accountID: requestedAccountID,
                    source: source
                )
                try Task.checkCancellation()
                guard generation == acceptedGeneration,
                      normalizedAccountID() == requestedAccountID
                else { return }
                let persistence = persistence
                let write = try await Task.detached(priority: .utility) {
                    try persistence.stage(prepared, accountID: requestedAccountID)
                }.value
                stagedWrite = write
                try Task.checkCancellation()
                guard generation == acceptedGeneration,
                      normalizedAccountID() == requestedAccountID
                else { throw CancellationError() }
                // Only the same-volume atomic replacement remains on MainActor.
                try persistence.commit(write)
                stagedWrite = nil
                pack = prepared
                progress = nil
                state = .idle
            } catch is CancellationError {
                if let stagedWrite {
                    let persistence = persistence
                    await Task.detached(priority: .utility) {
                        persistence.discard(stagedWrite)
                    }.value
                }
                if activeOperationID == operationID { progress = nil }
            } catch {
                if let stagedWrite {
                    let persistence = persistence
                    await Task.detached(priority: .utility) {
                        persistence.discard(stagedWrite)
                    }.value
                }
                guard generation == acceptedGeneration else { return }
                progress = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelPreparation() {
        guard preparationTask != nil else {
            progress = nil
            state = .idle
            return
        }
        generation &+= 1
        preparationTask?.cancel()
        progress = nil
        state = .cancelling
    }

    func deletePack() {
        guard preparationTask == nil else { return }
        guard let requestedAccountID = normalizedAccountID() else { return }
        generation &+= 1
        let acceptedGeneration = generation
        let operationID = UUID()
        activeOperationID = operationID
        state = .deleting
        progress = nil
        let persistence = persistence
        let clearCachedResponses = clearCachedResponses
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(operationID) }
            do {
                try await Task.detached(priority: .utility) {
                    try persistence.remove(accountID: requestedAccountID)
                }.value
                if acceptedGeneration == generation,
                   normalizedAccountID() == requestedAccountID {
                    pack = nil
                }
                try await clearCachedResponses(requestedAccountID)
                try Task.checkCancellation()
                guard acceptedGeneration == generation,
                      normalizedAccountID() == requestedAccountID
                else { return }
                pack = nil
                state = .idle
            } catch is CancellationError {
                return
            } catch {
                guard activeOperationID == operationID,
                      acceptedGeneration == generation,
                      normalizedAccountID() == requestedAccountID
                else { return }
                state = .failed("删除离线内容失败：\(error.localizedDescription)")
            }
        }
    }

    private func finishOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        preparationTask = nil
        progress = nil
        switch state {
        case .preparing, .cancelling, .deleting:
            state = .idle
        case .idle, .failed:
            break
        }
    }

    private func buildPack(
        accountID: String,
        source: HomeRecommendationSource
    ) async throws -> FlightOfflinePack {
        var candidates: [FeedItemDTO] = []
        var nextURL: URL?

        for pageIndex in 0..<FlightOfflinePackPolicy.maximumRecommendationPages {
            try Task.checkCancellation()
            guard normalizedAccountID() == accountID else { throw CancellationError() }
            do {
                let page = try await homeRepository.fetchPage(
                    source: source,
                    after: pageIndex == 0 ? nil : nextURL
                )
                candidates = uniqueReadableItems(candidates + page.items)
                nextURL = page.nextURL
                let seeds = questionSeeds(from: candidates)
                if seeds.count >= FlightOfflinePackPolicy.maximumQuestions
                    || page.isEnd
                    || page.nextURL == nil {
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if candidates.isEmpty { throw error }
                break
            }
        }

        let seeds = Array(
            questionSeeds(from: candidates)
                .prefix(FlightOfflinePackPolicy.maximumQuestions)
        )
        let articles = Array(
            standaloneArticleSeeds(from: candidates)
                .prefix(FlightOfflinePackPolicy.maximumStandaloneItems)
        )
        guard !seeds.isEmpty || !articles.isEmpty else {
            throw FlightOfflinePackError.noReadableContent
        }

        let unitsPerQuestion = 2 + FlightOfflinePackPolicy.answersPerQuestion * 2
        let totalUnits = seeds.count * unitsPerQuestion + articles.count * 2
        var completedUnits = 0
        var questions: [FlightOfflineQuestionEntry] = []
        var standalone: [FlightOfflineStandaloneEntry] = []
        var estimatedMinutes = 0

        for seed in seeds {
            try Task.checkCancellation()
            guard normalizedAccountID() == accountID else { throw CancellationError() }
            updateProgress(
                completed: completedUnits,
                total: totalUnits,
                questions: questions.count,
                answers: questions.reduce(0) { $0 + $1.answers.count } + standalone.count,
                status: "正在缓存问题和相关回答"
            )

            let questionRoute = QuestionRouteDTO(
                questionID: seed.questionID,
                provisionalTitle: seed.title
            )
            async let loadedQuestion: QuestionDTO? = try? await questionAnswerRepository
                .fetchQuestion(questionRoute, cachePolicy: .offlinePackWarm)
            async let loadedPage: QuestionAnswerPageDTO? = try? await questionAnswerRepository
                .fetchQuestionAnswers(
                    questionID: seed.questionID,
                    sort: .default,
                    after: nil,
                    cachePolicy: .offlinePackWarm
                )
            let (question, page) = await (loadedQuestion, loadedPage)
            completedUnits += 2
            guard let question, let page else { continue }

            let selectedPreviews = Array(
                page.items.prefix(FlightOfflinePackPolicy.answersPerQuestion)
            )
            let repository = questionAnswerRepository
            var cachedAnswerIDs: Set<Int64> = []
            await withTaskGroup(of: (Int64, Bool).self) { group in
                for preview in selectedPreviews {
                    group.addTask {
                        let route = AnswerRouteDTO(
                            contentID: preview.answerID,
                            kind: .answer,
                            questionID: seed.questionID,
                            provisionalTitle: question.title
                        )
                        async let body: AnswerDTO? = try? await repository.fetchAnswer(
                            route,
                            cachePolicy: .offlinePackWarm
                        )
                        async let collections: QACollectionsResult? = try? await repository
                            .fetchCollections(route: route, cachePolicy: .offlinePackWarm)
                        let (loadedBody, loadedCollections) = await (body, collections)
                        return (
                            preview.answerID,
                            loadedBody != nil && loadedCollections != nil
                        )
                    }
                }
                for await (answerID, succeeded) in group {
                    completedUnits += 2
                    if succeeded { cachedAnswerIDs.insert(answerID) }
                    updateProgress(
                        completed: completedUnits,
                        total: totalUnits,
                        questions: questions.count,
                        answers: questions.reduce(0) { $0 + $1.answers.count }
                            + cachedAnswerIDs.count
                            + standalone.count,
                        status: "正在缓存回答正文"
                    )
                }
            }

            let cachedAnswers = selectedPreviews
                .filter { cachedAnswerIDs.contains($0.answerID) }
                .map(FlightOfflineAnswerSummary.init)
            guard !cachedAnswers.isEmpty else { continue }
            let title = question.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            questions.append(FlightOfflineQuestionEntry(
                questionID: seed.questionID,
                title: title,
                answers: cachedAnswers
            ))
            estimatedMinutes += cachedAnswers.count
            if estimatedMinutes >= FlightOfflinePackPolicy.targetReadingMinutes {
                break
            }
        }

        if estimatedMinutes < FlightOfflinePackPolicy.targetReadingMinutes {
            for item in articles {
                try Task.checkCancellation()
                guard normalizedAccountID() == accountID else { throw CancellationError() }
                guard case let .article(articleID, title) = item.route else { continue }
                let route = AnswerRouteDTO(
                    contentID: articleID,
                    kind: .article,
                    provisionalTitle: title
                )
                async let loadedBody: AnswerDTO? = try? await questionAnswerRepository
                    .fetchAnswer(route, cachePolicy: .offlinePackWarm)
                async let loadedCollections: QACollectionsResult? = try? await
                    questionAnswerRepository.fetchCollections(
                        route: route,
                        cachePolicy: .offlinePackWarm
                    )
                let (body, collections) = await (loadedBody, loadedCollections)
                completedUnits += 2
                guard let body, collections != nil else { continue }
                standalone.append(FlightOfflineStandaloneEntry(
                    contentID: articleID,
                    kind: .article,
                    title: body.title,
                    authorName: body.author.displayName,
                    excerpt: item.summary ?? item.details
                ))
                estimatedMinutes += FlightOfflinePackPolicy.estimatedMinutesPerArticle
                updateProgress(
                    completed: completedUnits,
                    total: totalUnits,
                    questions: questions.count,
                    answers: questions.reduce(0) { $0 + $1.answers.count } + standalone.count,
                    status: "正在缓存文章正文"
                )
                if estimatedMinutes >= FlightOfflinePackPolicy.targetReadingMinutes {
                    break
                }
            }
        }

        guard !questions.isEmpty || !standalone.isEmpty else {
            throw FlightOfflinePackError.noReadableContent
        }
        let finalAnswerCount = questions.reduce(0) { $0 + $1.answers.count }
        return FlightOfflinePack(
            schemaVersion: FlightOfflinePack.currentSchemaVersion,
            accountID: accountID,
            source: source,
            createdAt: Date(),
            questions: questions,
            standalone: standalone,
            estimatedReadingMinutes: FlightOfflinePackPolicy.estimatedMinutes(
                answerCount: finalAnswerCount,
                articleCount: standalone.count
            )
        )
    }

    private func normalizedAccountID() -> String? {
        let value = accountID()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func updateProgress(
        completed: Int,
        total: Int,
        questions: Int,
        answers: Int,
        status: String
    ) {
        progress = FlightOfflineProgress(
            completedUnitCount: completed,
            totalUnitCount: total,
            questionCount: questions,
            answerCount: answers,
            status: status
        )
    }

    private func uniqueReadableItems(_ items: [FeedItemDTO]) -> [FeedItemDTO] {
        var seen: Set<FeedItemID> = []
        return items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            switch item.route {
            case .answer, .article, .question:
                return true
            case .pin, .video:
                return false
            }
        }
    }

    private func questionSeeds(from items: [FeedItemDTO]) -> [FlightOfflineQuestionSeed] {
        var seen: Set<Int64> = []
        return items.compactMap { item in
            let questionID: Int64
            let title: String
            switch item.route {
            case let .answer(_, candidateQuestionID, candidateTitle):
                guard let candidateQuestionID else { return nil }
                questionID = candidateQuestionID
                title = candidateTitle.isEmpty ? item.title : candidateTitle
            case let .question(candidateQuestionID, candidateTitle):
                questionID = candidateQuestionID
                title = candidateTitle.isEmpty ? item.title : candidateTitle
            case .article, .pin, .video:
                return nil
            }
            guard questionID > 0, seen.insert(questionID).inserted else { return nil }
            return FlightOfflineQuestionSeed(questionID: questionID, title: title)
        }
    }

    private func standaloneArticleSeeds(from items: [FeedItemDTO]) -> [FeedItemDTO] {
        items.filter {
            if case .article = $0.route { return true }
            return false
        }
    }
}

struct FlightOfflineReadingView: View {
    @ObservedObject var store: FlightOfflinePackStore
    let pendingInteractionCount: Int
    let interactionStatus: String?
    let onRetryInteractions: () -> Void
    let onOpenQuestion: (QuestionRouteDTO) -> Void
    let onOpenAnswer: (AnswerRouteDTO) -> Void

    @State private var confirmsDeletion = false

    var body: some View {
        List {
            statusSection
            if pendingInteractionCount > 0 || interactionStatus != nil {
                interactionSection
            }
            if let pack = store.pack {
                contentSections(pack)
            }
        }
        .navigationTitle("离线阅读")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.reload() }
        .toolbar {
            if store.pack != nil, !store.isPreparing {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            store.startPreparation()
                        } label: {
                            Label("更新离线内容", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            confirmsDeletion = true
                        } label: {
                            Label("删除离线内容", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("离线阅读操作")
                }
            }
        }
        .confirmationDialog(
            "删除离线内容？",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive, action: store.deletePack)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机下载的问题和回答；知乎收藏与待同步操作不会受到影响。")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    store.pack == nil ? "准备航班内容" : "可离线阅读",
                    systemImage: "airplane"
                )
                .font(.headline)

                if let progress = store.progress {
                    Text(progress.status)
                        .font(.subheadline)
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .accessibilityValue(progress.accessibilityValue)
                    } else {
                        ProgressView()
                            .accessibilityValue(progress.accessibilityValue)
                    }
                    Text(
                        "\(progress.questionCount) 个问题 · "
                            + "\(progress.answerCount) 篇回答已缓存"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let pack = store.pack {
                    Text(
                        "\(pack.questionCount) 个问题 · "
                            + "\(pack.answerCount) 篇内容 · "
                            + "约 \(pack.estimatedReadingMinutes) 分钟"
                    )
                    .font(.subheadline)
                    Text(pack.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("提前缓存约 20 分钟的推荐问题与相关回答，飞行模式下也能阅读。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("缓存文字正文和收藏夹选择；图片可能依赖系统缓存，暂不下载视频。准备时请保持 App 在前台。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch store.state {
                case .preparing:
                    Button(role: .cancel, action: store.cancelPreparation) {
                        Label("取消准备", systemImage: "xmark.circle")
                    }
                case .cancelling:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在安全取消")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                case .deleting:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在删除本机离线内容")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button {
                        store.startPreparation()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                case .idle:
                    if store.pack == nil {
                        Button {
                            store.startPreparation()
                        } label: {
                            Label("准备 20 分钟内容", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var interactionSection: some View {
        Section("同步状态") {
            LabeledContent("待同步操作", value: "\(pendingInteractionCount) 项")
            Text(interactionStatus ?? "联网并打开 App 后会自动同步。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if interactionStatus != nil {
                Button("立即重试", action: onRetryInteractions)
            }
        }
    }

    @ViewBuilder
    private func contentSections(_ pack: FlightOfflinePack) -> some View {
        ForEach(pack.questions) { question in
            Section {
                Button {
                    onOpenQuestion(question.questionRoute)
                } label: {
                    Label("查看问题详情", systemImage: "text.bubble")
                }
                ForEach(question.answers) { answer in
                    Button {
                        onOpenAnswer(question.answerRoute(for: answer))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(answer.authorName.isEmpty ? "匿名用户" : answer.authorName)
                                .font(.subheadline.weight(.semibold))
                            if !answer.excerpt.isEmpty {
                                Text(answer.excerpt)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Text(
                                "\(answer.voteUpCount) 赞同 · "
                                    + "\(answer.commentCount) 评论"
                            )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(question.title)
                    .textCase(nil)
            } footer: {
                Text("\(question.answers.count) 个回答已缓存")
            }
        }

        if !pack.standalone.isEmpty {
            Section("文章") {
                ForEach(pack.standalone) { entry in
                    Button {
                        onOpenAnswer(entry.route)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title)
                                .font(.headline)
                            if !entry.authorName.isEmpty {
                                Text(entry.authorName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.excerpt.isEmpty {
                                Text(entry.excerpt)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
