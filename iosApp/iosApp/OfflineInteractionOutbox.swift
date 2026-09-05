import Combine
import Foundation
import Network

// MARK: - Absolute interaction intents

/// A durable interaction describes the state the server should have, never a toggle operation.
/// Re-enqueuing the same account/target replaces the previous desired state.
enum OfflineInteractionMutation: Equatable, Sendable {
    case contentVote(kind: QAContentKind, contentID: Int64, state: QAVoteState)
    case collectionMembership(
        kind: QAContentKind,
        contentID: Int64,
        collectionID: String,
        isMember: Bool
    )
    case pinLike(pinID: Int64, isLiked: Bool)
    case commentLike(commentID: String, isLiked: Bool)

    var target: OfflineInteractionTarget {
        switch self {
        case let .contentVote(kind, contentID, _):
            return .contentVote(kind: kind, contentID: contentID)
        case let .collectionMembership(kind, contentID, collectionID, _):
            return .collectionMembership(
                kind: kind,
                contentID: contentID,
                collectionID: collectionID
            )
        case let .pinLike(pinID, _):
            return .pinLike(pinID: pinID)
        case let .commentLike(commentID, _):
            return .commentLike(commentID: commentID)
        }
    }

    static func vote(_ state: QAVoteState, route: AnswerRouteDTO) -> Self {
        .contentVote(kind: route.kind, contentID: route.contentID, state: state)
    }

    static func collection(
        _ isMember: Bool,
        collectionID: String,
        route: AnswerRouteDTO
    ) -> Self {
        .collectionMembership(
            kind: route.kind,
            contentID: route.contentID,
            collectionID: collectionID,
            isMember: isMember
        )
    }

    fileprivate func validated() throws {
        switch self {
        case let .contentVote(kind, contentID, state):
            guard contentID > 0 else { throw OfflineInteractionOutboxError.invalidIdentifier }
            guard kind == .answer || state != .down else {
                throw OfflineInteractionOutboxError.unsupportedDesiredState
            }
        case let .collectionMembership(_, contentID, collectionID, _):
            guard contentID > 0,
                  collectionID.utf8.count <= Self.maximumIdentifierByteCount,
                  Self.isValidCollectionID(collectionID)
            else {
                throw OfflineInteractionOutboxError.invalidIdentifier
            }
        case let .pinLike(pinID, _):
            guard pinID > 0 else { throw OfflineInteractionOutboxError.invalidIdentifier }
        case let .commentLike(commentID, _):
            guard !commentID.isEmpty,
                  commentID.utf8.count <= Self.maximumIdentifierByteCount,
                  commentID.addingPercentEncoding(
                    withAllowedCharacters: Self.commentPathSegmentCharacters
                  ) != nil
            else { throw OfflineInteractionOutboxError.invalidIdentifier }
        }
    }

    fileprivate static func isValidCollectionID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy {
            $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_"
        }
    }

    fileprivate static let commentPathSegmentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
    fileprivate static let maximumIdentifierByteCount = 1_024
}

enum OfflineInteractionTarget: Hashable, Sendable {
    case contentVote(kind: QAContentKind, contentID: Int64)
    case collectionMembership(kind: QAContentKind, contentID: Int64, collectionID: String)
    case pinLike(pinID: Int64)
    case commentLike(commentID: String)
}

extension OfflineInteractionMutation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case contentKind
        case contentID
        case collectionID
        case voteState
        case desiredValue
        case pinID
        case commentID
    }

    private enum MutationType: String, Codable {
        case contentVote
        case collectionMembership
        case pinLike
        case commentLike
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MutationType.self, forKey: .type)
        switch type {
        case .contentVote:
            guard let kind = QAContentKind(
                rawValue: try container.decode(String.self, forKey: .contentKind)
            ), let state = QAVoteState(
                rawValue: try container.decode(String.self, forKey: .voteState)
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown content-vote value"
                )
            }
            self = .contentVote(
                kind: kind,
                contentID: try container.decode(Int64.self, forKey: .contentID),
                state: state
            )
        case .collectionMembership:
            guard let kind = QAContentKind(
                rawValue: try container.decode(String.self, forKey: .contentKind)
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .contentKind,
                    in: container,
                    debugDescription: "Unknown collection content kind"
                )
            }
            self = .collectionMembership(
                kind: kind,
                contentID: try container.decode(Int64.self, forKey: .contentID),
                collectionID: try container.decode(String.self, forKey: .collectionID),
                isMember: try container.decode(Bool.self, forKey: .desiredValue)
            )
        case .pinLike:
            self = .pinLike(
                pinID: try container.decode(Int64.self, forKey: .pinID),
                isLiked: try container.decode(Bool.self, forKey: .desiredValue)
            )
        case .commentLike:
            self = .commentLike(
                commentID: try container.decode(String.self, forKey: .commentID),
                isLiked: try container.decode(Bool.self, forKey: .desiredValue)
            )
        }
        do {
            try validated()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Invalid offline interaction mutation"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .contentVote(kind, contentID, state):
            try container.encode(MutationType.contentVote, forKey: .type)
            try container.encode(kind.rawValue, forKey: .contentKind)
            try container.encode(contentID, forKey: .contentID)
            try container.encode(state.rawValue, forKey: .voteState)
        case let .collectionMembership(kind, contentID, collectionID, isMember):
            try container.encode(MutationType.collectionMembership, forKey: .type)
            try container.encode(kind.rawValue, forKey: .contentKind)
            try container.encode(contentID, forKey: .contentID)
            try container.encode(collectionID, forKey: .collectionID)
            try container.encode(isMember, forKey: .desiredValue)
        case let .pinLike(pinID, isLiked):
            try container.encode(MutationType.pinLike, forKey: .type)
            try container.encode(pinID, forKey: .pinID)
            try container.encode(isLiked, forKey: .desiredValue)
        case let .commentLike(commentID, isLiked):
            try container.encode(MutationType.commentLike, forKey: .type)
            try container.encode(commentID, forKey: .commentID)
            try container.encode(isLiked, forKey: .desiredValue)
        }
    }
}

// MARK: - Optimistic projections

struct OfflineVoteOverlay: Equatable, Sendable {
    let state: QAVoteState
    let voteUpCount: Int
    let isPending: Bool
    let revision: UInt64?
}

struct OfflineBooleanOverlay: Equatable, Sendable {
    let value: Bool
    let isPending: Bool
    let revision: UInt64?
}

struct OfflineCountedBooleanOverlay: Equatable, Sendable {
    let value: Bool
    let count: Int
    let isPending: Bool
    let revision: UInt64?
}

/// An immutable, account-scoped snapshot intended to be kept by a MainActor UI store.
/// It can be queried synchronously while rendering.
struct OfflineInteractionOverlaySnapshot: Equatable, Sendable {
    fileprivate struct Entry: Equatable, Sendable {
        let mutation: OfflineInteractionMutation
        let revision: UInt64
    }

    static let empty = Self(entries: [:])

    fileprivate let entries: [OfflineInteractionTarget: Entry]

    fileprivate init(entries: [OfflineInteractionTarget: Entry]) {
        self.entries = entries
    }

    var pendingCount: Int { entries.count }

    func vote(
        route: AnswerRouteDTO,
        serverState: QAVoteState,
        serverVoteUpCount: Int
    ) -> OfflineVoteOverlay {
        let key = OfflineInteractionTarget.contentVote(
            kind: route.kind,
            contentID: route.contentID
        )
        guard let entry = entries[key],
              case let .contentVote(_, _, desiredState) = entry.mutation
        else {
            return OfflineVoteOverlay(
                state: serverState,
                voteUpCount: max(0, serverVoteUpCount),
                isPending: false,
                revision: nil
            )
        }
        let serverContribution = serverState == .up ? 1 : 0
        let desiredContribution = desiredState == .up ? 1 : 0
        return OfflineVoteOverlay(
            state: desiredState,
            voteUpCount: max(0, serverVoteUpCount - serverContribution + desiredContribution),
            isPending: true,
            revision: entry.revision
        )
    }

    func collectionMembership(
        route: AnswerRouteDTO,
        collectionID: String,
        serverIsMember: Bool
    ) -> OfflineBooleanOverlay {
        let key = OfflineInteractionTarget.collectionMembership(
            kind: route.kind,
            contentID: route.contentID,
            collectionID: collectionID
        )
        guard let entry = entries[key],
              case let .collectionMembership(_, _, _, desiredValue) = entry.mutation
        else {
            return OfflineBooleanOverlay(
                value: serverIsMember,
                isPending: false,
                revision: nil
            )
        }
        return OfflineBooleanOverlay(
            value: desiredValue,
            isPending: true,
            revision: entry.revision
        )
    }

    func collections(
        route: AnswerRouteDTO,
        serverCollections: [QACollectionDTO]
    ) -> [QACollectionDTO] {
        serverCollections.map { collection in
            let projection = collectionMembership(
                route: route,
                collectionID: collection.id,
                serverIsMember: collection.isFavorited
            )
            guard projection.isPending else { return collection }
            return QACollectionDTO(
                id: collection.id,
                title: collection.title,
                isFavorited: projection.value
            )
        }
    }

    func pinLike(
        pinID: Int64,
        serverIsLiked: Bool,
        serverLikeCount: Int
    ) -> OfflineCountedBooleanOverlay {
        countedBoolean(
            key: .pinLike(pinID: pinID),
            serverValue: serverIsLiked,
            serverCount: serverLikeCount
        )
    }

    func commentLike(
        commentID: String,
        serverIsLiked: Bool,
        serverLikeCount: Int
    ) -> OfflineCountedBooleanOverlay {
        countedBoolean(
            key: .commentLike(commentID: commentID),
            serverValue: serverIsLiked,
            serverCount: serverLikeCount
        )
    }

    private func countedBoolean(
        key: OfflineInteractionTarget,
        serverValue: Bool,
        serverCount: Int
    ) -> OfflineCountedBooleanOverlay {
        guard let entry = entries[key] else {
            return OfflineCountedBooleanOverlay(
                value: serverValue,
                count: max(0, serverCount),
                isPending: false,
                revision: nil
            )
        }
        let desiredValue: Bool
        switch entry.mutation {
        case let .pinLike(_, isLiked), let .commentLike(_, isLiked):
            desiredValue = isLiked
        default:
            return OfflineCountedBooleanOverlay(
                value: serverValue,
                count: max(0, serverCount),
                isPending: false,
                revision: nil
            )
        }
        return OfflineCountedBooleanOverlay(
            value: desiredValue,
            count: max(0, serverCount + (desiredValue ? 1 : 0) - (serverValue ? 1 : 0)),
            isPending: true,
            revision: entry.revision
        )
    }
}

// MARK: - Persistence and delivery contracts

protocol OfflineInteractionOutboxStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

enum OfflineInteractionPersistenceLimits {
    static let maximumByteCount = 2 * 1_024 * 1_024
}

struct JSONFileOfflineInteractionOutboxStorage: OfflineInteractionOutboxStorage, Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> JSONFileOfflineInteractionOutboxStorage {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            fileURL: root
                .appendingPathComponent("OfflineInteractionOutbox", isDirectory: true)
                .appendingPathComponent("outbox-v1.json", isDirectory: false)
        )
    }

    func read() throws -> Data? {
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize,
               fileSize > OfflineInteractionPersistenceLimits.maximumByteCount {
                throw OfflineInteractionOutboxError.persistenceTooLarge
            }
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func write(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }
}

enum OfflineInteractionAcknowledgement: Equatable, Sendable {
    case accepted
    case vote(voteUpCount: Int)
    case like(likeCount: Int)
}

protocol OfflineInteractionExecuting: Sendable {
    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement
}

/// Keeps an already-downloaded flight pack coherent after the server accepts a mutation.
/// Implementations must not create new caches for ordinary, previously uncached content.
protocol OfflineInteractionCacheRefreshing: Sendable {
    func refreshCachedVote(
        accountID: String,
        kind: QAContentKind,
        contentID: Int64,
        desiredState: QAVoteState
    ) async throws

    func refreshCachedCollectionMembership(
        accountID: String,
        kind: QAContentKind,
        contentID: Int64,
        collectionID: String,
        isMember: Bool
    ) async throws
}

struct DisabledOfflineInteractionCacheRefresher: OfflineInteractionCacheRefreshing {
    func refreshCachedVote(
        accountID: String,
        kind: QAContentKind,
        contentID: Int64,
        desiredState: QAVoteState
    ) async throws {}

    func refreshCachedCollectionMembership(
        accountID: String,
        kind: QAContentKind,
        contentID: Int64,
        collectionID: String,
        isMember: Bool
    ) async throws {}
}

/// Sends the same methods, paths and payloads as the existing answer, pin and comment repositories.
/// Every non-GET request is pinned to the account captured when the intent was enqueued.
actor ZhihuOfflineInteractionExecutor: OfflineInteractionExecuting {
    private let client: ZhihuAPIClient
    private let cacheRefresher: any OfflineInteractionCacheRefreshing

    init(
        client: ZhihuAPIClient,
        cacheRefresher: any OfflineInteractionCacheRefreshing =
            DisabledOfflineInteractionCacheRefresher()
    ) {
        self.client = client
        self.cacheRefresher = cacheRefresher
    }

    func execute(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionAcknowledgement {
        guard !accountID.isEmpty else { throw OfflineInteractionOutboxError.accountRequired }
        try mutation.validated()

        switch mutation {
        case let .contentVote(kind, contentID, state):
            let url = try endpoint(
                host: "www.zhihu.com",
                path: "/api/v4/\(kind.rawValue)s/\(contentID)/voters"
            )
            let payload: [String: Any]
            switch kind {
            case .answer:
                payload = ["type": answerVoteRequestValue(state)]
            case .article:
                payload = ["voting": state == .up ? 1 : 0]
            }
            let body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            let data = try await client.data(
                for: url,
                method: "POST",
                body: body,
                additionalHeaders: ["Content-Type": "application/json"],
                authentication: .accountRequired,
                expectedAccountID: accountID
            )
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = root["voteup_count"] as? Int
            else { throw QuestionAnswerRepositoryError.malformedMutation }
            try await cacheRefresher.refreshCachedVote(
                accountID: accountID,
                kind: kind,
                contentID: contentID,
                desiredState: state
            )
            return .vote(voteUpCount: count)

        case let .collectionMembership(kind, contentID, collectionID, isMember):
            let url = try endpoint(
                host: "api.zhihu.com",
                path: "/collections/contents/\(kind.rawValue)/\(contentID)"
            )
            let field = isMember ? "add_collections" : "remove_collections"
            _ = try await client.data(
                for: url,
                method: "PUT",
                body: Data("\(field)=\(collectionID)".utf8),
                additionalHeaders: ["Content-Type": "application/x-www-form-urlencoded"],
                authentication: .accountRequired,
                expectedAccountID: accountID
            )
            try await cacheRefresher.refreshCachedCollectionMembership(
                accountID: accountID,
                kind: kind,
                contentID: contentID,
                collectionID: collectionID,
                isMember: isMember
            )
            return .accepted

        case let .pinLike(pinID, isLiked):
            let url = try endpoint(
                host: "www.zhihu.com",
                path: "/api/v4/pins/\(pinID)/voters/up"
            )
            let data = try await client.data(
                for: url,
                method: isLiked ? "POST" : "DELETE",
                authentication: .accountRequired,
                expectedAccountID: accountID
            )
            return .like(likeCount: try PinResponseMapper.likedCount(from: data))

        case let .commentLike(commentID, isLiked):
            guard let encodedID = commentID.addingPercentEncoding(
                withAllowedCharacters: OfflineInteractionMutation.commentPathSegmentCharacters
            ), let url = URL(
                string: "https://www.zhihu.com/api/v4/comments/\(encodedID)/like"
            ), ZhihuAPIURLPolicy.allowsAPIRequest(url)
            else { throw OfflineInteractionOutboxError.invalidIdentifier }
            _ = try await client.data(
                for: url,
                method: isLiked ? "POST" : "DELETE",
                authentication: .accountRequired,
                expectedAccountID: accountID
            )
            return .accepted
        }
    }

    private func endpoint(host: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url, ZhihuAPIURLPolicy.allowsAPIRequest(url) else {
            throw OfflineInteractionOutboxError.invalidIdentifier
        }
        return url
    }

    private func answerVoteRequestValue(_ state: QAVoteState) -> String {
        switch state {
        case .neutral: return "neutral"
        case .up: return "up"
        case .down: return "down"
        }
    }
}

// MARK: - Durable outbox

enum OfflineInteractionFailureKind: String, Codable, Equatable, Sendable {
    case connectivity
    case authentication
    case accountChanged
    case rateLimited
    case server
    case rejected
    case invalidResponse
    case unknown
}

struct OfflineInteractionReceipt: Equatable, Sendable {
    let target: OfflineInteractionTarget
    let revision: UInt64
}

struct OfflineInteractionPending: Equatable, Sendable {
    let mutation: OfflineInteractionMutation
    let revision: UInt64
    let createdAt: Date
    let updatedAt: Date
    let attemptCount: Int
    let nextAttemptAt: Date?
    let lastFailure: OfflineInteractionFailureKind?
    let isBlocked: Bool
}

struct OfflineInteractionDelivery: Equatable, Sendable {
    let target: OfflineInteractionTarget
    let revision: UInt64
    let acknowledgement: OfflineInteractionAcknowledgement
}

struct OfflineInteractionFlushReport: Equatable, Sendable {
    let delivered: [OfflineInteractionDelivery]
    let supersededRevisions: [UInt64]
    let remainingCount: Int
    let readyCount: Int
    let earliestRetryAt: Date?
    let stoppedBy: OfflineInteractionFailureKind?
    let wasAlreadyRunning: Bool
}

struct OfflineInteractionRetryPolicy: Equatable, Sendable {
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(initialDelay: TimeInterval = 2, maximumDelay: TimeInterval = 5 * 60) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard initialDelay > 0 else { return 0 }
        let exponent = min(max(0, attempt - 1), 20)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }
}

enum OfflineInteractionOutboxError: LocalizedError, Equatable, Sendable {
    case accountRequired
    case invalidIdentifier
    case unsupportedDesiredState
    case queueCapacityReached
    case revisionExhausted
    case unsupportedSchema(Int)
    case corruptPersistence
    case persistenceTooLarge

    var errorDescription: String? {
        switch self {
        case .accountRequired: return "请登录后再操作"
        case .invalidIdentifier: return "操作目标无效"
        case .unsupportedDesiredState: return "该内容不支持此操作状态"
        case .queueCapacityReached: return "待同步操作过多，请联网同步后重试"
        case .revisionExhausted: return "离线操作版本号已耗尽"
        case let .unsupportedSchema(version): return "不支持的离线操作队列版本（\(version)）"
        case .corruptPersistence: return "离线操作队列数据损坏"
        case .persistenceTooLarge: return "离线操作队列文件超过安全大小限制"
        }
    }
}

actor DurableOfflineInteractionOutbox {
    private struct ScopedTarget: Hashable {
        let accountID: String
        let target: OfflineInteractionTarget
    }

    private struct Record: Codable, Equatable {
        let accountID: String
        let mutation: OfflineInteractionMutation
        let revision: UInt64
        let createdAt: Date
        let updatedAt: Date
        let attemptCount: Int
        let nextAttemptAt: Date?
        let lastFailure: OfflineInteractionFailureKind?
        let isBlocked: Bool

        var scopedTarget: ScopedTarget {
            ScopedTarget(accountID: accountID, target: mutation.target)
        }

        var pendingValue: OfflineInteractionPending {
            OfflineInteractionPending(
                mutation: mutation,
                revision: revision,
                createdAt: createdAt,
                updatedAt: updatedAt,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastFailure: lastFailure,
                isBlocked: isBlocked
            )
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        var nextRevision: UInt64
        var records: [Record]
    }

    private struct LoadedState {
        var nextRevision: UInt64
        var records: [ScopedTarget: Record]
    }

    private struct FailureDisposition {
        let kind: OfflineInteractionFailureKind
        let isAutomaticallyRetryable: Bool
        let stopsFlush: Bool
    }

    private static let schemaVersion = 1
    private static let maximumRecordCount = 4_096
    private static let maximumDeliveriesPerFlush = 256
    private static let maximumAccountIDByteCount = 1_024

    private let storage: any OfflineInteractionOutboxStorage
    private let executor: any OfflineInteractionExecuting
    private let retryPolicy: OfflineInteractionRetryPolicy
    private let now: @Sendable () -> Date
    private var loadedState: LoadedState?
    private var flushingAccounts: Set<String> = []

    init(
        storage: any OfflineInteractionOutboxStorage,
        executor: any OfflineInteractionExecuting,
        retryPolicy: OfflineInteractionRetryPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.executor = executor
        self.retryPolicy = retryPolicy
        self.now = now
    }

    @discardableResult
    func enqueue(
        accountID: String,
        mutation: OfflineInteractionMutation
    ) throws -> OfflineInteractionReceipt {
        try validateAccountID(accountID)
        try mutation.validated()
        try loadIfNeeded()
        guard var state = loadedState else { throw OfflineInteractionOutboxError.corruptPersistence }
        let key = ScopedTarget(accountID: accountID, target: mutation.target)
        guard state.records[key] != nil || state.records.count < Self.maximumRecordCount else {
            throw OfflineInteractionOutboxError.queueCapacityReached
        }
        guard state.nextRevision > 0, state.nextRevision < UInt64.max else {
            throw OfflineInteractionOutboxError.revisionExhausted
        }

        let revision = state.nextRevision
        state.nextRevision += 1
        let timestamp = now()
        state.records[key] = Record(
            accountID: accountID,
            mutation: mutation,
            revision: revision,
            createdAt: state.records[key]?.createdAt ?? timestamp,
            updatedAt: timestamp,
            attemptCount: 0,
            nextAttemptAt: nil,
            lastFailure: nil,
            isBlocked: false
        )
        try commit(state)
        return OfflineInteractionReceipt(target: mutation.target, revision: revision)
    }

    func pending(accountID: String) throws -> [OfflineInteractionPending] {
        try validateAccountID(accountID)
        try loadIfNeeded()
        return loadedState?.records.values
            .filter { $0.accountID == accountID }
            .sorted { $0.revision < $1.revision }
            .map(\.pendingValue) ?? []
    }

    func overlay(accountID: String) throws -> OfflineInteractionOverlaySnapshot {
        guard !accountID.isEmpty else { return .empty }
        try validateAccountID(accountID)
        try loadIfNeeded()
        let entries = loadedState?.records.values.reduce(
            into: [OfflineInteractionTarget: OfflineInteractionOverlaySnapshot.Entry]()
        ) { result, record in
            guard record.accountID == accountID else { return }
            result[record.mutation.target] = .init(
                mutation: record.mutation,
                revision: record.revision
            )
        } ?? [:]
        return OfflineInteractionOverlaySnapshot(entries: entries)
    }

    /// Removes only the selected account's durable intents. If a corrupt or newer-schema file
    /// cannot be inspected safely, privacy cleanup clears the whole outbox instead.
    func removeAll(accountID: String) throws {
        try validateAccountID(accountID)
        do {
            try loadIfNeeded()
        } catch OfflineInteractionOutboxError.corruptPersistence,
                OfflineInteractionOutboxError.persistenceTooLarge {
            // Corruption recovery already committed an empty envelope.
            return
        } catch OfflineInteractionOutboxError.unsupportedSchema(_) {
            try commit(LoadedState(nextRevision: 1, records: [:]))
            return
        }
        guard var state = loadedState else {
            throw OfflineInteractionOutboxError.corruptPersistence
        }
        let originalCount = state.records.count
        state.records = state.records.filter { $0.key.accountID != accountID }
        guard state.records.count != originalCount else { return }
        try commit(state)
    }

    /// Delivers only records belonging to `accountID`. A completion removes a record only when
    /// its revision is still current, so an in-flight older request cannot erase a newer intent.
    func flush(
        accountID: String,
        force: Bool = false
    ) async throws -> OfflineInteractionFlushReport {
        try validateAccountID(accountID)
        try loadIfNeeded()
        guard !flushingAccounts.contains(accountID) else {
            return makeReport(
                accountID: accountID,
                delivered: [],
                superseded: [],
                stoppedBy: nil,
                wasAlreadyRunning: true
            )
        }
        flushingAccounts.insert(accountID)
        defer { flushingAccounts.remove(accountID) }

        var deliveries: [OfflineInteractionDelivery] = []
        var superseded: [UInt64] = []
        var stoppedBy: OfflineInteractionFailureKind?
        var deliveryCount = 0
        var attemptedRevisions: Set<UInt64> = []

        while deliveryCount < Self.maximumDeliveriesPerFlush {
            guard let record = nextEligibleRecord(
                accountID: accountID,
                force: force,
                excluding: attemptedRevisions
            ) else { break }
            deliveryCount += 1
            attemptedRevisions.insert(record.revision)
            do {
                let acknowledgement = try await executor.execute(
                    accountID: record.accountID,
                    mutation: record.mutation
                )
                guard isCurrent(record) else {
                    superseded.append(record.revision)
                    continue
                }
                guard var state = loadedState else {
                    throw OfflineInteractionOutboxError.corruptPersistence
                }
                state.records.removeValue(forKey: record.scopedTarget)
                try commit(state)
                deliveries.append(OfflineInteractionDelivery(
                    target: record.mutation.target,
                    revision: record.revision,
                    acknowledgement: acknowledgement
                ))
            } catch is CancellationError {
                break
            } catch {
                if error.isNativeRequestCancellation { break }
                guard isCurrent(record) else {
                    superseded.append(record.revision)
                    continue
                }
                let disposition = failureDisposition(error)
                try recordFailure(record, disposition: disposition)
                if disposition.stopsFlush {
                    stoppedBy = disposition.kind
                    break
                }
            }
        }

        return makeReport(
            accountID: accountID,
            delivered: deliveries,
            superseded: superseded,
            stoppedBy: stoppedBy,
            wasAlreadyRunning: false
        )
    }

    private func loadIfNeeded() throws {
        guard loadedState == nil else { return }
        let persistedData: Data?
        do {
            persistedData = try storage.read()
        } catch OfflineInteractionOutboxError.persistenceTooLarge {
            try discardCorruptPersistence(andThrow: .persistenceTooLarge)
        }
        guard let data = persistedData else {
            loadedState = LoadedState(nextRevision: 1, records: [:])
            return
        }
        guard data.count <= OfflineInteractionPersistenceLimits.maximumByteCount else {
            try discardCorruptPersistence(andThrow: .persistenceTooLarge)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            try discardCorruptPersistence(andThrow: .corruptPersistence)
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw OfflineInteractionOutboxError.unsupportedSchema(envelope.schemaVersion)
        }

        var records: [ScopedTarget: Record] = [:]
        var maximumRevision: UInt64 = 0
        for record in envelope.records {
            guard !record.accountID.isEmpty,
                  record.accountID.utf8.count <= Self.maximumAccountIDByteCount,
                  record.revision > 0
            else {
                try discardCorruptPersistence(andThrow: .corruptPersistence)
            }
            do {
                try record.mutation.validated()
            } catch {
                try discardCorruptPersistence(andThrow: .corruptPersistence)
            }
            maximumRevision = max(maximumRevision, record.revision)
            if let existing = records[record.scopedTarget], existing.revision >= record.revision {
                continue
            }
            records[record.scopedTarget] = record
        }
        guard records.count <= Self.maximumRecordCount,
              maximumRevision < UInt64.max,
              envelope.nextRevision > maximumRevision
        else { try discardCorruptPersistence(andThrow: .corruptPersistence) }
        loadedState = LoadedState(
            nextRevision: envelope.nextRevision,
            records: records
        )
    }

    private func commit(_ state: LoadedState) throws {
        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            nextRevision: state.nextRevision,
            records: state.records.values.sorted {
                if $0.revision == $1.revision { return $0.accountID < $1.accountID }
                return $0.revision < $1.revision
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= OfflineInteractionPersistenceLimits.maximumByteCount else {
            throw OfflineInteractionOutboxError.queueCapacityReached
        }
        try storage.write(data)
        loadedState = state
    }

    private func validateAccountID(_ accountID: String) throws {
        guard !accountID.isEmpty else { throw OfflineInteractionOutboxError.accountRequired }
        guard accountID.utf8.count <= Self.maximumAccountIDByteCount else {
            throw OfflineInteractionOutboxError.invalidIdentifier
        }
    }

    private func discardCorruptPersistence(
        andThrow error: OfflineInteractionOutboxError
    ) throws -> Never {
        try commit(LoadedState(nextRevision: 1, records: [:]))
        throw error
    }

    private func nextEligibleRecord(
        accountID: String,
        force: Bool,
        excluding attemptedRevisions: Set<UInt64>
    ) -> Record? {
        guard let records = loadedState?.records.values else { return nil }
        let timestamp = now()
        return records
            .filter { record in
                guard record.accountID == accountID,
                      !attemptedRevisions.contains(record.revision)
                else { return false }
                if force { return true }
                guard !record.isBlocked else { return false }
                return record.nextAttemptAt.map { $0 <= timestamp } ?? true
            }
            .min { $0.revision < $1.revision }
    }

    private func isCurrent(_ record: Record) -> Bool {
        loadedState?.records[record.scopedTarget]?.revision == record.revision
    }

    private func recordFailure(
        _ record: Record,
        disposition: FailureDisposition
    ) throws {
        guard var state = loadedState,
              state.records[record.scopedTarget]?.revision == record.revision
        else { return }
        let attempt = record.attemptCount == Int.max ? Int.max : record.attemptCount + 1
        let retryAt = disposition.isAutomaticallyRetryable
            ? now().addingTimeInterval(retryPolicy.delay(afterAttempt: attempt))
            : nil
        state.records[record.scopedTarget] = Record(
            accountID: record.accountID,
            mutation: record.mutation,
            revision: record.revision,
            createdAt: record.createdAt,
            updatedAt: now(),
            attemptCount: attempt,
            nextAttemptAt: retryAt,
            lastFailure: disposition.kind,
            isBlocked: !disposition.isAutomaticallyRetryable
        )
        try commit(state)
    }

    private func failureDisposition(_ error: Error) -> FailureDisposition {
        if error.isNativeConnectivityFailure {
            return FailureDisposition(
                kind: .connectivity,
                isAutomaticallyRetryable: true,
                stopsFlush: true
            )
        }
        guard let apiError = error as? ZhihuAPIError else {
            if error is DecodingError || error is CocoaError {
                return FailureDisposition(
                    kind: .invalidResponse,
                    isAutomaticallyRetryable: true,
                    stopsFlush: false
                )
            }
            return FailureDisposition(
                kind: .unknown,
                isAutomaticallyRetryable: true,
                stopsFlush: false
            )
        }
        switch apiError {
        case .accountChanged:
            return FailureDisposition(
                kind: .accountChanged,
                isAutomaticallyRetryable: false,
                stopsFlush: true
            )
        case .accountUnavailable, .authenticationRequired:
            return FailureDisposition(
                kind: .authentication,
                isAutomaticallyRetryable: false,
                stopsFlush: true
            )
        case let .httpStatus(status) where status == 408 || status == 425:
            return FailureDisposition(
                kind: .server,
                isAutomaticallyRetryable: true,
                stopsFlush: false
            )
        case let .httpStatus(status) where status == 429:
            return FailureDisposition(
                kind: .rateLimited,
                isAutomaticallyRetryable: true,
                stopsFlush: true
            )
        case let .httpStatus(status) where (500...599).contains(status):
            return FailureDisposition(
                kind: .server,
                isAutomaticallyRetryable: true,
                stopsFlush: false
            )
        case .invalidResponse,
             .malformedPayload,
             .cachedResponseUnavailable,
             .cacheWriteFailed:
            // All supported mutations are absolute/idempotent, so an uncertain acknowledgement
            // can safely be retried without reversing a later user choice.
            return FailureDisposition(
                kind: .invalidResponse,
                isAutomaticallyRetryable: true,
                stopsFlush: false
            )
        case .untrustedURL:
            return FailureDisposition(
                kind: .rejected,
                isAutomaticallyRetryable: false,
                stopsFlush: false
            )
        case .httpStatus:
            return FailureDisposition(
                kind: .rejected,
                isAutomaticallyRetryable: false,
                stopsFlush: false
            )
        }
    }

    private func makeReport(
        accountID: String,
        delivered: [OfflineInteractionDelivery],
        superseded: [UInt64],
        stoppedBy: OfflineInteractionFailureKind?,
        wasAlreadyRunning: Bool
    ) -> OfflineInteractionFlushReport {
        let remaining = loadedState?.records.values.filter { $0.accountID == accountID } ?? []
        let retryAt = remaining
            .filter { !$0.isBlocked }
            .compactMap(\.nextAttemptAt)
            .min()
        let timestamp = now()
        let readyCount = remaining.filter { record in
            !record.isBlocked && (record.nextAttemptAt.map { $0 <= timestamp } ?? true)
        }.count
        return OfflineInteractionFlushReport(
            delivered: delivered,
            supersededRevisions: superseded,
            remainingCount: remaining.count,
            readyCount: readyCount,
            earliestRetryAt: retryAt,
            stoppedBy: stoppedBy,
            wasAlreadyRunning: wasAlreadyRunning
        )
    }
}

// MARK: - MainActor coordination and reachability

protocol OfflineInteractionConnectivityMonitoring: Sendable {
    func start(_ update: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

final class NWPathOfflineInteractionConnectivityMonitor:
    OfflineInteractionConnectivityMonitoring,
    @unchecked Sendable
{
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var didStart = false

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "OfflineInteractionConnectivity")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func start(_ update: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { path in
            update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        let shouldCancel = didStart
        didStart = false
        lock.unlock()
        if shouldCancel { monitor.cancel() }
    }
}

enum OfflineInteractionCoordinatorState: Equatable {
    case stopped
    case idle
    case syncing
    case waitingForNetwork
    case waitingForRetry(Date)
    case failed(String)
}

enum OfflineInteractionCoordinatorError: LocalizedError, Equatable {
    case accountRequired

    var errorDescription: String? { "请登录后再操作" }
}

/// MainActor facade for UI integration. Call `applicationDidBecomeActive()` from scene/app
/// lifecycle handling; network recovery is observed automatically after `start()`.
@MainActor
final class OfflineInteractionCoordinator: ObservableObject {
    @Published private(set) var overlay: OfflineInteractionOverlaySnapshot = .empty
    @Published private(set) var state: OfflineInteractionCoordinatorState = .stopped
    @Published private(set) var lastDeliveries: [OfflineInteractionDelivery] = []

    private let outbox: DurableOfflineInteractionOutbox
    private let accountIDProvider: () throws -> String?
    private let connectivity: any OfflineInteractionConnectivityMonitoring
    private var deliveryTask: Task<Void, Never>?
    private var deliveryAccountID: String?
    private var retryTask: Task<Void, Never>?
    private var retryAccountID: String?
    private var deliveryRequested = false
    private var forceRequested = false
    private var networkAvailable: Bool?
    private var didStart = false

    init(
        outbox: DurableOfflineInteractionOutbox,
        accountID: @escaping () throws -> String?,
        connectivity: any OfflineInteractionConnectivityMonitoring =
            NWPathOfflineInteractionConnectivityMonitor()
    ) {
        self.outbox = outbox
        accountIDProvider = accountID
        self.connectivity = connectivity
    }

    deinit {
        connectivity.cancel()
        deliveryTask?.cancel()
        retryTask?.cancel()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        state = .idle
        connectivity.start { [weak self] available in
            Task { @MainActor [weak self] in
                self?.connectivityChanged(isAvailable: available)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshOverlayForCurrentAccount()
            requestDelivery(force: false)
        }
    }

    /// Call for foreground activation. It also refreshes account scope, so account switches never
    /// expose or deliver another account's pending overlay.
    func applicationDidBecomeActive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshOverlayForCurrentAccount()
            requestDelivery(force: true)
        }
    }

    func accountDidChange() {
        applicationDidBecomeActive()
    }

    func retryNow() {
        requestDelivery(force: true)
    }

    /// Privacy cleanup for account deletion/sign-out. Any in-flight older completion becomes stale
    /// because the actor removes the current durable record before that completion can commit.
    func removeAll(accountID: String) async throws {
        let currentAccountID = currentAccountID()
        let shouldInterruptDelivery = deliveryAccountID == accountID || (
            deliveryAccountID == nil &&
                deliveryTask != nil &&
                currentAccountID == accountID
        )
        let shouldCancelRetry = retryAccountID == accountID
        let interruptedDeliveryTask = shouldInterruptDelivery ? deliveryTask : nil

        if shouldInterruptDelivery {
            deliveryRequested = false
            forceRequested = false
            interruptedDeliveryTask?.cancel()
        }
        if shouldCancelRetry {
            retryTask?.cancel()
            retryTask = nil
            retryAccountID = nil
        }
        // Wait for a matching in-flight request to observe cancellation before deleting its
        // durable state. A nonmatching account's delivery is deliberately left uninterrupted.
        if let interruptedDeliveryTask {
            await interruptedDeliveryTask.value
        }
        try await outbox.removeAll(accountID: accountID)
        await refreshOverlayForCurrentAccount()
        if didStart, shouldInterruptDelivery || shouldCancelRetry {
            requestDelivery(force: false)
        }
    }

    func removeAllForCurrentAccount() async throws {
        try await removeAll(accountID: requiredAccountID())
    }

    @discardableResult
    func setVote(
        _ state: QAVoteState,
        route: AnswerRouteDTO
    ) async throws -> OfflineInteractionReceipt {
        try await enqueue(.vote(state, route: route))
    }

    @discardableResult
    func setCollectionMembership(
        _ isMember: Bool,
        collectionID: String,
        route: AnswerRouteDTO
    ) async throws -> OfflineInteractionReceipt {
        try await enqueue(.collection(isMember, collectionID: collectionID, route: route))
    }

    @discardableResult
    func setPinLiked(
        _ isLiked: Bool,
        pinID: Int64
    ) async throws -> OfflineInteractionReceipt {
        try await enqueue(.pinLike(pinID: pinID, isLiked: isLiked))
    }

    @discardableResult
    func setCommentLiked(
        _ isLiked: Bool,
        commentID: String
    ) async throws -> OfflineInteractionReceipt {
        try await enqueue(.commentLike(commentID: commentID, isLiked: isLiked))
    }

    private func enqueue(
        _ mutation: OfflineInteractionMutation
    ) async throws -> OfflineInteractionReceipt {
        let accountID = try requiredAccountID()
        let receipt = try await outbox.enqueue(accountID: accountID, mutation: mutation)
        await refreshOverlayForCurrentAccount()
        requestDelivery(force: true)
        return receipt
    }

    private func requiredAccountID() throws -> String {
        guard let accountID = try accountIDProvider(), !accountID.isEmpty else {
            throw OfflineInteractionCoordinatorError.accountRequired
        }
        return accountID
    }

    private func currentAccountID() -> String? {
        do {
            guard let accountID = try accountIDProvider(), !accountID.isEmpty else { return nil }
            return accountID
        } catch {
            return nil
        }
    }

    private func refreshOverlayForCurrentAccount() async {
        guard let accountID = currentAccountID() else {
            overlay = .empty
            return
        }
        do {
            let snapshot = try await outbox.overlay(accountID: accountID)
            // The actor hop can yield to an account switch. Re-check before publishing.
            guard currentAccountID() == accountID else {
                overlay = .empty
                return
            }
            overlay = snapshot
        } catch {
            overlay = .empty
            state = .failed("离线操作队列暂时不可用")
        }
    }

    private func connectivityChanged(isAvailable: Bool) {
        networkAvailable = isAvailable
        guard isAvailable else {
            retryTask?.cancel()
            retryTask = nil
            retryAccountID = nil
            if overlay.pendingCount > 0 { state = .waitingForNetwork }
            return
        }
        requestDelivery(force: true)
    }

    private func requestDelivery(force: Bool) {
        guard didStart else { return }
        deliveryRequested = true
        forceRequested = forceRequested || force
        guard networkAvailable != false else {
            if overlay.pendingCount > 0 { state = .waitingForNetwork }
            return
        }
        guard deliveryTask == nil else { return }
        deliveryTask = Task { @MainActor [weak self] in
            await self?.runDeliveryLoop()
        }
    }

    private func runDeliveryLoop() async {
        defer {
            deliveryTask = nil
            if deliveryRequested, !Task.isCancelled { requestDelivery(force: forceRequested) }
        }
        while deliveryRequested, !Task.isCancelled {
            deliveryRequested = false
            let force = forceRequested
            forceRequested = false
            guard networkAvailable != false else {
                state = overlay.pendingCount > 0 ? .waitingForNetwork : .idle
                return
            }
            guard let accountID = currentAccountID() else {
                overlay = .empty
                state = .idle
                continue
            }
            state = .syncing
            do {
                let report = try await flushOutbox(accountID: accountID, force: force)
                guard currentAccountID() == accountID else {
                    await refreshOverlayForCurrentAccount()
                    deliveryRequested = true
                    continue
                }
                lastDeliveries = report.delivered
                overlay = try await outbox.overlay(accountID: accountID)
                if report.stoppedBy == nil, report.readyCount > 0 {
                    deliveryRequested = true
                    state = .syncing
                } else if let retryAt = report.earliestRetryAt {
                    scheduleRetry(at: retryAt, accountID: accountID)
                    state = .waitingForRetry(retryAt)
                } else if report.remainingCount > 0,
                          report.stoppedBy == .connectivity {
                    state = .waitingForNetwork
                } else if report.remainingCount > 0 {
                    state = .failed("部分点赞或收藏尚未同步，请稍后重试")
                } else {
                    state = .idle
                }
            } catch is CancellationError {
                return
            } catch {
                state = .failed("离线操作同步暂时失败")
            }
        }
    }

    private func flushOutbox(
        accountID: String,
        force: Bool
    ) async throws -> OfflineInteractionFlushReport {
        deliveryAccountID = accountID
        defer { deliveryAccountID = nil }
        return try await outbox.flush(accountID: accountID, force: force)
    }

    private func scheduleRetry(at date: Date, accountID: String) {
        retryTask?.cancel()
        retryAccountID = accountID
        let delay = max(0, date.timeIntervalSinceNow)
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.retryAccountID = nil
            self?.requestDelivery(force: false)
        }
    }
}
