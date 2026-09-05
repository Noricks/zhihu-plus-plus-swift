import CryptoKit
import Foundation

enum ZhihuAPICachePolicy: Sendable {
    case disabled
    case offlineFallback
    case cacheFirst
    case cacheOnly
    case offlinePackWarm

    var allowsConnectivityFallback: Bool {
        switch self {
        case .offlineFallback, .cacheFirst:
            return true
        case .disabled, .cacheOnly, .offlinePackWarm:
            return false
        }
    }
}

struct ZhihuAPIResponseCacheRequest: Equatable, Hashable, Sendable {
    let accountID: String
    let url: URL
}

protocol ZhihuAPIResponseCaching: Sendable {
    func response(for request: ZhihuAPIResponseCacheRequest) async -> Data?
    @discardableResult
    func store(_ data: Data, for request: ZhihuAPIResponseCacheRequest) async -> Bool
    @discardableResult
    func store(
        _ data: Data,
        for request: ZhihuAPIResponseCacheRequest,
        ifGenerationMatches generation: UInt64
    ) async -> Bool
    func generation(forAccountID accountID: String) async -> UInt64
    func removeResponse(for request: ZhihuAPIResponseCacheRequest) async throws
    func removeResponses(forAccountID accountID: String) async throws
}

extension ZhihuAPIResponseCaching {
    func store(
        _ data: Data,
        for request: ZhihuAPIResponseCacheRequest,
        ifGenerationMatches generation: UInt64
    ) async -> Bool {
        await store(data, for: request)
    }

    func generation(forAccountID accountID: String) async -> UInt64 { 0 }
}

struct DisabledZhihuAPIResponseCache: ZhihuAPIResponseCaching {
    func response(for request: ZhihuAPIResponseCacheRequest) async -> Data? { nil }
    func store(_ data: Data, for request: ZhihuAPIResponseCacheRequest) async -> Bool { false }
    func removeResponse(for request: ZhihuAPIResponseCacheRequest) async throws {}
    func removeResponses(forAccountID accountID: String) async throws {}
}

enum ZhihuAPIOfflineCacheEligibility {
    static func allows(method: String, url: URL) -> Bool {
        guard method.uppercased() == "GET",
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let host = url.host?.lowercased()
        else { return false }

        let components = url.path.split(separator: "/").map(String.init)
        switch host {
        case "zhihu.com", "www.zhihu.com":
            return allowsWebAPIPath(components)
        case "api.zhihu.com":
            return allowsCollectionMembershipPath(components)
        default:
            return false
        }
    }

    private static func allowsWebAPIPath(_ components: [String]) -> Bool {
        guard components.count >= 4,
              components[0] == "api",
              components[1] == "v4"
        else { return false }

        switch components[2] {
        case "questions":
            guard isNumericIdentifier(components[3]) else { return false }
            return components.count == 4 || (components.count == 5 && components[4] == "feeds")
        case "answers", "articles":
            return components.count == 4 && isNumericIdentifier(components[3])
        default:
            return false
        }
    }

    private static func allowsCollectionMembershipPath(_ components: [String]) -> Bool {
        guard components.count == 4,
              components[0] == "collections",
              components[1] == "contents",
              components[2] == "answer" || components[2] == "article"
        else { return false }
        return isNumericIdentifier(components[3])
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

actor FileZhihuAPIResponseCache: ZhihuAPIResponseCaching {
    static let defaultMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let defaultMaximumEntryCount = 1_500
    static let defaultMaximumEntryByteCount = 16 * 1_024 * 1_024
    static let defaultMaximumByteCount = 256 * 1_024 * 1_024

    private let directory: URL
    private let maximumAge: TimeInterval
    private let maximumEntryCount: Int
    private let maximumEntryByteCount: Int
    private let maximumByteCount: Int
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var accountGenerations: [String: UInt64] = [:]

    init(
        directory: URL? = nil,
        maximumAge: TimeInterval = FileZhihuAPIResponseCache.defaultMaximumAge,
        maximumEntryCount: Int = FileZhihuAPIResponseCache.defaultMaximumEntryCount,
        maximumEntryByteCount: Int = FileZhihuAPIResponseCache.defaultMaximumEntryByteCount,
        maximumByteCount: Int = FileZhihuAPIResponseCache.defaultMaximumByteCount,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = applicationSupport.appendingPathComponent(
                "OfflineAPIResponseCache",
                isDirectory: true
            )
        }
        self.maximumAge = max(0, maximumAge)
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumEntryByteCount = max(0, maximumEntryByteCount)
        self.maximumByteCount = max(0, maximumByteCount)
        self.fileManager = fileManager
        self.now = now
    }

    func response(for request: ZhihuAPIResponseCacheRequest) async -> Data? {
        guard maximumAge > 0,
              maximumEntryCount > 0,
              maximumEntryByteCount > 0,
              maximumByteCount > 0,
              valid(request)
        else { return nil }
        let fileURL = fileURL(for: request)
        guard let values = try? fileURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            now().timeIntervalSince(modifiedAt) <= maximumAge,
            let fileSize = values.fileSize,
            fileSize > 0,
            fileSize <= maximumEntryByteCount,
            fileSize <= maximumByteCount,
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
            !data.isEmpty
        else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return data
    }

    func store(_ data: Data, for request: ZhihuAPIResponseCacheRequest) async -> Bool {
        storeData(data, for: request)
    }

    func store(
        _ data: Data,
        for request: ZhihuAPIResponseCacheRequest,
        ifGenerationMatches generation: UInt64
    ) async -> Bool {
        guard accountGenerations[request.accountID, default: 0] == generation else {
            return false
        }
        return storeData(data, for: request)
    }

    func generation(forAccountID accountID: String) async -> UInt64 {
        accountGenerations[accountID, default: 0]
    }

    func removeResponse(for request: ZhihuAPIResponseCacheRequest) async throws {
        guard valid(request) else { return }
        let fileURL = fileURL(for: request)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func removeResponses(forAccountID accountID: String) async throws {
        guard validAccountID(accountID) else { return }
        accountGenerations[accountID, default: 0] &+= 1
        let accountDirectory = accountDirectory(for: accountID)
        guard fileManager.fileExists(atPath: accountDirectory.path) else { return }
        try fileManager.removeItem(at: accountDirectory)
    }

    private func storeData(_ data: Data, for request: ZhihuAPIResponseCacheRequest) -> Bool {
        guard maximumAge > 0,
              maximumEntryCount > 0,
              maximumEntryByteCount > 0,
              maximumByteCount > 0,
              valid(request),
              !data.isEmpty,
              data.count <= maximumEntryByteCount,
              data.count <= maximumByteCount
        else { return false }
        let accountDirectory = accountDirectory(for: request.accountID)
        let fileURL = fileURL(for: request)
        do {
            try createProtectedDirectory(directory)
            try createProtectedDirectory(accountDirectory)
            try data.write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            excludeFromBackup(fileURL)
            pruneIfNeeded(preserving: fileURL)
            return fileManager.fileExists(atPath: fileURL.path)
        } catch {
            // The policy decides whether a failed best-effort cache write is fatal.
            return false
        }
    }

    private func valid(_ request: ZhihuAPIResponseCacheRequest) -> Bool {
        validAccountID(request.accountID)
            && ZhihuAPIOfflineCacheEligibility.allows(method: "GET", url: request.url)
    }

    private func validAccountID(_ accountID: String) -> Bool {
        !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        excludeFromBackup(url)
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func accountDirectory(for accountID: String) -> URL {
        directory.appendingPathComponent(digest("account-v1\u{0}\(accountID)"), isDirectory: true)
    }

    private func fileURL(for request: ZhihuAPIResponseCacheRequest) -> URL {
        accountDirectory(for: request.accountID).appendingPathComponent(
            digest("request-v1\u{0}GET\u{0}\(request.url.absoluteString)"),
            isDirectory: false
        )
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func pruneIfNeeded(preserving storedFileURL: URL) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now().addingTimeInterval(-maximumAge)
        var entries: [Entry] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ]),
                values.isRegularFile == true
            else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if modifiedAt < cutoff {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            entries.append(Entry(
                url: fileURL,
                modifiedAt: modifiedAt,
                byteCount: max(0, values.fileSize ?? 0)
            ))
        }

        entries.sort {
            if $0.url == storedFileURL { return false }
            if $1.url == storedFileURL { return true }
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.absoluteString < $1.url.absoluteString
            }
            return $0.modifiedAt < $1.modifiedAt
        }
        var totalBytes = entries.reduce(0) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
            return overflow ? Int.max : sum
        }
        var entryCount = entries.count
        for entry in entries where entryCount > maximumEntryCount || totalBytes > maximumByteCount {
            guard (try? fileManager.removeItem(at: entry.url)) != nil else { continue }
            entryCount -= 1
            totalBytes = max(0, totalBytes - entry.byteCount)
        }
    }

    private struct Entry {
        let url: URL
        let modifiedAt: Date
        let byteCount: Int
    }
}
