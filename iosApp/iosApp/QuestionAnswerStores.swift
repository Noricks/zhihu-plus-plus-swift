import Foundation

@MainActor
final class QuestionStore: ObservableObject {
    @Published private(set) var question: QuestionDTO?
    @Published private(set) var answers: [AnswerPreviewDTO] = []
    @Published private(set) var initialLoad: QAInitialLoadState = .idle
    @Published private(set) var nextPage: QANextPageState = .idle
    @Published private(set) var isEnd = false
    @Published private(set) var isFollowMutationInFlight = false
    @Published private(set) var message: QAUserMessage?
    @Published var sort: QuestionAnswerSort = .default
    @Published var isDetailExpanded = true

    let route: QuestionRouteDTO
    private let repository: QuestionAnswerRepository
    private var nextURL: URL?
    private var generation: UInt64 = 0

    init(route: QuestionRouteDTO, repository: QuestionAnswerRepository) {
        self.route = route
        self.repository = repository
    }

    func loadIfNeeded() async {
        guard initialLoad == .idle else { return }
        await refresh()
    }

    func refresh() async {
        generation &+= 1
        let accepted = generation
        initialLoad = .loading
        nextPage = .idle
        do {
            async let detail = repository.fetchQuestion(route)
            async let page = repository.fetchQuestionAnswers(
                questionID: route.questionID,
                sort: sort,
                after: nil
            )
            let (loadedQuestion, loadedPage) = try await (detail, page)
            guard generation == accepted else { return }
            question = loadedQuestion
            answers = loadedPage.items
            nextURL = loadedPage.nextURL
            isEnd = loadedPage.isEnd
            initialLoad = .loaded
            Task {
                await repository.recordReadHistory(
                    contentToken: String(loadedQuestion.id),
                    contentType: "question"
                )
            }
        } catch is CancellationError {
            if generation == accepted { initialLoad = question == nil ? .idle : .loaded }
            return
        } catch {
            guard generation == accepted else { return }
            initialLoad = .failed(error.localizedDescription)
        }
    }

    func selectSort(_ sort: QuestionAnswerSort) async {
        guard self.sort != sort else { return }
        self.sort = sort
        await refresh()
    }

    func loadMore() async {
        guard initialLoad == .loaded, nextPage != .loading, !isEnd else { return }
        let accepted = generation
        nextPage = .loading
        do {
            let page = try await repository.fetchQuestionAnswers(
                questionID: route.questionID,
                sort: sort,
                after: nextURL
            )
            guard generation == accepted else { return }
            let existing = Set(answers.map(\.answerID))
            answers.append(contentsOf: page.items.filter { !existing.contains($0.answerID) })
            nextURL = page.nextURL
            isEnd = page.isEnd
            nextPage = .idle
        } catch is CancellationError {
            if generation == accepted { nextPage = .idle }
            return
        } catch {
            guard generation == accepted else { return }
            nextPage = .failed(error.localizedDescription)
        }
    }

    func toggleFollowing() async {
        guard let question, !isFollowMutationInFlight else { return }
        isFollowMutationInFlight = true
        defer { isFollowMutationInFlight = false }
        let target = !question.isFollowing
        do {
            try await repository.setQuestionFollowing(target, questionID: question.id)
            guard self.question?.id == question.id else { return }
            self.question = question.replacingFollow(
                isFollowing: target,
                followerCount: question.followerCount + (target ? 1 : -1)
            )
            message = QAUserMessage(text: target ? "已关注问题" : "已取消关注问题")
        } catch is CancellationError {
            return
        } catch {
            message = QAUserMessage(text: "关注操作失败：\(error.localizedDescription)")
        }
    }

    func answerRoute(for preview: AnswerPreviewDTO) -> AnswerRouteDTO {
        return AnswerRouteDTO(
            contentID: preview.answerID,
            kind: .answer,
            questionID: preview.questionID,
            provisionalTitle: preview.questionTitle,
            source: AnswerPageSourceDTO(
                questionID: preview.questionID,
                order: sort,
                orderedAnswers: answers,
                selectedAnswerID: preview.answerID,
                nextURL: nextURL
            )
        )
    }

    func dismissMessage() { message = nil }
}

@MainActor
final class AnswerStore: ObservableObject, Identifiable {
    let id: Int64
    let initialRoute: AnswerRouteDTO

    @Published private(set) var content: AnswerDTO?
    @Published private(set) var loadState: QAInitialLoadState = .idle
    @Published private(set) var isVoteMutationInFlight = false
    @Published private(set) var collections: [QACollectionDTO] = []
    @Published private(set) var collectionsState: QAInitialLoadState = .idle
    @Published private(set) var activeCollectionID: String?
    @Published private(set) var message: QAUserMessage?

    private let repository: QuestionAnswerRepository
    private var revision: UInt64 = 0
    private var activeLoadTask: Task<AnswerDTO, Error>?
    private var didReportReadHistory = false

    init(route: AnswerRouteDTO, repository: QuestionAnswerRepository) {
        initialRoute = route
        id = route.contentID
        self.repository = repository
    }

    func loadIfNeeded() async {
        await load(force: false, reportsReadHistory: true)
    }

    func preloadIfNeeded() async {
        await load(force: false, reportsReadHistory: false)
    }

    func retry() async {
        await load(force: true, reportsReadHistory: true)
    }

    private func load(force: Bool, reportsReadHistory: Bool) async {
        if let activeLoadTask {
            do {
                let loaded = try await activeLoadTask.value
                if reportsReadHistory { reportReadHistoryIfNeeded(for: loaded) }
            } catch {
                // The request owner publishes the shared failure state.
            }
            return
        }
        guard force || loadState == .idle else {
            if reportsReadHistory, let content {
                reportReadHistoryIfNeeded(for: content)
            }
            return
        }

        revision &+= 1
        let accepted = revision
        loadState = .loading
        let repository = repository
        let route = initialRoute
        let task = Task { try await repository.fetchAnswer(route) }
        activeLoadTask = task
        defer {
            if revision == accepted { activeLoadTask = nil }
        }
        do {
            let loaded = try await task.value
            guard revision == accepted else { return }
            content = loaded
            loadState = .loaded
            if reportsReadHistory { reportReadHistoryIfNeeded(for: loaded) }
        } catch is CancellationError {
            if revision == accepted { loadState = content == nil ? .idle : .loaded }
            return
        } catch {
            guard revision == accepted else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func reportReadHistoryIfNeeded(for content: AnswerDTO) {
        guard !didReportReadHistory else { return }
        didReportReadHistory = true
        let repository = repository
        Task {
            await repository.recordReadHistory(
                contentToken: String(content.route.contentID),
                contentType: content.route.kind.rawValue
            )
        }
    }

    func setVote(_ requested: QAVoteState) async {
        guard let content, !isVoteMutationInFlight else { return }
        isVoteMutationInFlight = true
        defer { isVoteMutationInFlight = false }
        do {
            let result = try await repository.setVote(requested, route: content.route)
            guard self.content?.route.contentID == content.route.contentID else { return }
            self.content = content.replacingVote(result.state, count: result.voteUpCount)
        } catch is CancellationError {
            return
        } catch {
            message = QAUserMessage(text: "投票失败：\(error.localizedDescription)")
        }
    }

    func loadCollections(force: Bool = false) async {
        guard let content,
              collectionsState != .loading,
              activeCollectionID == nil,
              force || collectionsState != .loaded
        else { return }
        collectionsState = .loading
        do {
            let loaded = try await repository.fetchCollections(route: content.route)
            guard self.content?.route.contentID == content.route.contentID else { return }
            collections = loaded.items
            self.content = content.replacingFavorite(loaded.favoriteState, count: content.favoriteCount)
            collectionsState = .loaded
        } catch is CancellationError {
            collectionsState = collections.isEmpty ? .idle : .loaded
            return
        } catch {
            collectionsState = .failed(error.localizedDescription)
        }
    }

    func setCollection(_ collection: QACollectionDTO, selected: Bool) async {
        guard let content,
              activeCollectionID == nil,
              collectionsState != .loading,
              collection.isFavorited != selected
        else { return }
        activeCollectionID = collection.id
        defer { activeCollectionID = nil }
        do {
            try await repository.setCollection(
                selected,
                collectionID: collection.id,
                route: content.route
            )
            guard self.content?.route.contentID == content.route.contentID else { return }
            collections = collections.map {
                $0.id == collection.id
                    ? QACollectionDTO(id: $0.id, title: $0.title, isFavorited: selected)
                    : $0
            }
            let wasAnyFavorite = collections.contains(where: { $0.id != collection.id && $0.isFavorited })
            let isAnyFavorite = wasAnyFavorite || selected
            let delta = selected ? 1 : -1
            self.content = content.replacingFavorite(
                isAnyFavorite ? .favorited : .notFavorited,
                count: content.favoriteCount + delta
            )
            message = QAUserMessage(text: selected ? "收藏成功" : "已取消收藏")
        } catch is CancellationError {
            return
        } catch {
            message = QAUserMessage(text: "收藏操作失败：\(error.localizedDescription)")
        }
    }

    func dismissMessage() { message = nil }
}

protocol AnswerOpenedHistory: Sendable {
    func openedAnswerIDs(questionID: Int64) async -> Set<Int64>
    func markOpened(answerID: Int64, questionID: Int64) async
}

actor UserDefaultsAnswerOpenedHistory: AnswerOpenedHistory {
    private let defaults: UserDefaults
    private let key = "nativeAnswerOpenedHistory.v1"
    private let maximumPerQuestion = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func openedAnswerIDs(questionID: Int64) -> Set<Int64> {
        Set((storage()[String(questionID)] ?? []).compactMap(Int64.init))
    }

    func markOpened(answerID: Int64, questionID: Int64) {
        var value = storage()
        let questionKey = String(questionID)
        var answers = value[questionKey] ?? []
        answers.removeAll { $0 == String(answerID) }
        answers.append(String(answerID))
        value[questionKey] = Array(answers.suffix(maximumPerQuestion))
        defaults.set(value, forKey: key)
    }

    private func storage() -> [String: [String]] {
        defaults.dictionary(forKey: key)?.reduce(into: [:]) { result, pair in
            if let values = pair.value as? [String] { result[pair.key] = values }
        } ?? [:]
    }
}

@MainActor
final class AnswerPagerStore: ObservableObject {
    enum ForwardAvailability: Equatable {
        case loading
        case available
        case end
        case failed(String)
    }

    @Published private(set) var current: AnswerStore
    @Published private(set) var previous: AnswerStore?
    @Published private(set) var next: AnswerStore?
    @Published private(set) var isPreparingNext = false
    @Published private(set) var switchError: String?
    @Published private(set) var boundaryNotice: String?

    private let repository: QuestionAnswerRepository
    private let openedHistory: AnswerOpenedHistory
    private let diagnostics: PerformanceDiagnosticsClient
    private var routes: [AnswerRouteDTO]
    private var index: Int
    private var nextURL: URL?
    private var isEnd = false
    private let sourceOrder: QuestionAnswerSort
    private var stores: [Int64: AnswerStore] = [:]

    var forwardAvailability: ForwardAvailability {
        if next != nil { return .available }
        if isPreparingNext { return .loading }
        if let switchError { return .failed(switchError) }
        if isEnd { return .end }
        return .loading
    }

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        openedHistory: AnswerOpenedHistory = UserDefaultsAnswerOpenedHistory(),
        diagnostics: PerformanceDiagnosticsClient = .disabled
    ) {
        self.repository = repository
        self.openedHistory = openedHistory
        self.diagnostics = diagnostics
        if let source = route.source {
            sourceOrder = source.order
            routes = source.orderedAnswers.map {
                AnswerRouteDTO(
                    contentID: $0.answerID,
                    kind: .answer,
                    questionID: $0.questionID,
                    provisionalTitle: $0.questionTitle,
                    source: nil
                )
            }
            index = routes.firstIndex { $0.contentID == route.contentID } ?? 0
            if !routes.contains(where: { $0.contentID == route.contentID }) {
                routes.insert(route, at: 0)
                index = 0
            }
            nextURL = source.nextURL
        } else {
            sourceOrder = .default
            routes = [route]
            index = 0
            nextURL = nil
        }
        let store = AnswerStore(route: routes[index], repository: repository)
        current = store
        stores[store.id] = store
        updateNeighbors()
    }

    func prepare() async {
        await current.loadIfNeeded()
        if let questionID = current.content?.questionID ?? current.initialRoute.questionID {
            await openedHistory.markOpened(answerID: current.id, questionID: questionID)
        }
        await prepareNextIfNeeded()
        await preloadAdjacentAnswers()
    }

    func didDisplay(answerID: Int64) async {
        guard commitDisplayedAnswer(answerID: answerID) else { return }
        await prepareDisplayedAnswer()
    }

    @discardableResult
    func commitDisplayedAnswer(answerID: Int64) -> Bool {
        guard let selectedIndex = routes.firstIndex(where: { $0.contentID == answerID }) else { return false }
        let direction = selectedIndex > index ? "next" : "previous"
        index = selectedIndex
        current = store(for: routes[selectedIndex])
        boundaryNotice = nil
        updateNeighbors()
        diagnostics.record(.init(
            category: "answer_pager",
            operation: "switch",
            result: .success,
            pagingSource: direction
        ))
        return true
    }

    func prepareDisplayedAnswer() async {
        await current.loadIfNeeded()
        if let questionID = current.content?.questionID ?? current.initialRoute.questionID {
            await openedHistory.markOpened(answerID: current.id, questionID: questionID)
        }
        await prepareNextIfNeeded()
        await preloadAdjacentAnswers()
    }

    func retrySwitch() async {
        boundaryNotice = nil
        switchError = nil
        await prepareNextIfNeeded(force: true)
        await preloadAdjacentAnswers()
    }

    @discardableResult
    func reportForwardBoundaryReached() -> Bool {
        guard case .end = forwardAvailability,
              boundaryNotice != "没有更多了"
        else { return false }
        boundaryNotice = "没有更多了"
        return true
    }

    private func updateNeighbors() {
        previous = index > 0 ? store(for: routes[index - 1]) : nil
        next = index + 1 < routes.count ? store(for: routes[index + 1]) : nil
    }

    private func store(for route: AnswerRouteDTO) -> AnswerStore {
        if let stored = stores[route.contentID] { return stored }
        let created = AnswerStore(route: route, repository: repository)
        stores[route.contentID] = created
        return created
    }

    private func preloadAdjacentAnswers() async {
        let previousStore = previous
        let nextStore = next
        async let previousLoad: Void = preload(previousStore)
        async let nextLoad: Void = preload(nextStore)
        _ = await (previousLoad, nextLoad)
    }

    private func preload(_ store: AnswerStore?) async {
        guard let store else { return }
        await store.preloadIfNeeded()
    }

    private func prepareNextIfNeeded(force: Bool = false) async {
        guard current.initialRoute.kind == .answer,
              next == nil,
              !isPreparingNext,
              !isEnd || force,
              let questionID = current.content?.questionID ?? current.initialRoute.questionID
        else { return }
        isPreparingNext = true
        defer { isPreparingNext = false }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let opened = await openedHistory.openedAnswerIDs(questionID: questionID)
            var seenContinuations = Set<URL>()
            while next == nil, !isEnd {
                if let nextURL, !seenContinuations.insert(nextURL).inserted {
                    throw QuestionAnswerRepositoryError.untrustedContinuation
                }
                let page = try await repository.fetchQuestionAnswers(
                    questionID: questionID,
                    sort: sourceOrder,
                    after: nextURL
                )
                let known = Set(routes.map(\.contentID))
                let candidates = page.items.filter {
                    !known.contains($0.answerID) && !opened.contains($0.answerID)
                }
                routes.append(contentsOf: candidates.map {
                    AnswerRouteDTO(
                        contentID: $0.answerID,
                        kind: .answer,
                        questionID: $0.questionID,
                        provisionalTitle: $0.questionTitle
                    )
                })
                nextURL = page.nextURL
                isEnd = page.isEnd || page.nextURL == nil
                updateNeighbors()
            }
            switchError = nil
            updateNeighbors()
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "answer_pager",
                operation: "next_preload",
                result: .success,
                itemCount: next == nil ? 0 : 1,
                pagingSource: isEnd ? "end" : "next"
            ))
        } catch is CancellationError {
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "answer_pager",
                operation: "next_preload",
                result: .cancelled,
                errorKind: "cancelled"
            ))
            return
        } catch {
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "answer_pager",
                operation: "next_preload",
                result: .failure,
                errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
            ))
            switchError = error.localizedDescription
        }
    }
}
