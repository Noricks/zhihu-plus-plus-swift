import Foundation
import Security

protocol AccountJSONStore {
    func load() throws -> String?
    func save(_ accountJSON: String) throws
    func clear() throws
    func update(_ transform: (String?) throws -> String?) throws
}

struct NativeSavedAccountSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let urlToken: String?
    let avatarURL: URL?
}

struct MultipleAccountJSONSnapshot: Equatable, Sendable {
    let accountID: String?
    let accountJSON: String?
}

private func normalizedMultipleAccountID(_ accountID: String?) -> String? {
    guard let accountID else { return nil }
    let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

protocol MultipleAccountJSONStore: AccountJSONStore {
    func listAccounts() throws -> [NativeSavedAccountSummary]
    func currentAccountID() throws -> String?
    func currentAccountSnapshot() throws -> MultipleAccountJSONSnapshot
    func updateCurrentAccount(
        expectedAccountID: String?,
        _ transform: (String?) throws -> String?
    ) throws
    func switchAccount(to accountID: String) throws
    func deleteAccount(_ accountID: String) throws
    func clearCurrentAccount() throws
}

enum MultipleAccountStoreError: LocalizedError, Equatable {
    case accountNotFound
    case cannotDeleteCurrentAccount
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "找不到要操作的账号"
        case .cannotDeleteCurrentAccount:
            return "不能删除当前正在使用的账号"
        case .accountChanged:
            return "操作期间当前账号已变化"
        }
    }
}

extension MultipleAccountJSONStore {
    func currentAccountSnapshot() throws -> MultipleAccountJSONSnapshot {
        let accountID = try currentAccountID()
        let accountJSON = try load()
        guard try currentAccountID() == accountID else {
            throw MultipleAccountStoreError.accountChanged
        }
        return MultipleAccountJSONSnapshot(accountID: accountID, accountJSON: accountJSON)
    }

    func updateCurrentAccount(
        expectedAccountID: String?,
        _ transform: (String?) throws -> String?
    ) throws {
        guard normalizedMultipleAccountID(try currentAccountID())
            == normalizedMultipleAccountID(expectedAccountID)
        else {
            throw MultipleAccountStoreError.accountChanged
        }
        try update(transform)
        guard normalizedMultipleAccountID(try currentAccountID())
            == normalizedMultipleAccountID(expectedAccountID)
        else {
            throw MultipleAccountStoreError.accountChanged
        }
    }
}

extension AccountJSONStore {
    func update(_ transform: (String?) throws -> String?) throws {
        if let updated = try transform(try load()) {
            try save(updated)
        } else {
            try clear()
        }
    }
}

final class KeychainAccountStore: MultipleAccountJSONStore {
    static let defaultService = "com.github.zly2006.zhplus.ios.account"
    static let defaultAccount = "account-json-v1"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            case .invalidUTF8:
                return "Stored account data is not valid UTF-8"
            }
        }
    }

    let service: String
    let account: String

    private let lock = NSLock()

    init(
        service: String = KeychainAccountStore.defaultService,
        account: String = KeychainAccountStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        try synchronized {
            var vault = try loadVaultUnlocked()
            if vault.requiresPersistence {
                try saveVaultUnlocked(vault.envelope)
                vault.requiresPersistence = false
            }
            return vault.envelope.currentSessionJSON
        }
    }

    func save(_ accountJSON: String) throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            upsert(accountJSON, into: &vault)
            try saveVaultUnlocked(vault)
        }
    }

    func clear() throws {
        try synchronized {
            try clearUnlocked()
        }
    }

    func update(_ transform: (String?) throws -> String?) throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            let current = vault.currentSessionJSON
            if let updated = try transform(current) {
                upsert(updated, into: &vault)
                try saveVaultUnlocked(vault)
            } else {
                try clearCurrentAccountUnlocked(vault: &vault)
            }
        }
    }

    func updateCurrentAccount(
        expectedAccountID: String?,
        _ transform: (String?) throws -> String?
    ) throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            guard normalizedMultipleAccountID(vault.currentAccountID)
                == normalizedMultipleAccountID(expectedAccountID)
            else {
                throw MultipleAccountStoreError.accountChanged
            }
            if let updated = try transform(vault.currentSessionJSON) {
                upsert(updated, into: &vault)
                try saveVaultUnlocked(vault)
            } else {
                try clearCurrentAccountUnlocked(vault: &vault)
            }
        }
    }

    func listAccounts() throws -> [NativeSavedAccountSummary] {
        try synchronized {
            let vault = try loadVaultUnlocked()
            if vault.requiresPersistence {
                try saveVaultUnlocked(vault.envelope)
            }
            return vault.envelope.accounts.values
                .map(\.summary)
                .sorted {
                    let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
        }
    }

    func currentAccountID() throws -> String? {
        try synchronized {
            let vault = try loadVaultUnlocked()
            if vault.requiresPersistence {
                try saveVaultUnlocked(vault.envelope)
            }
            return vault.envelope.currentAccountID
        }
    }

    func currentAccountSnapshot() throws -> MultipleAccountJSONSnapshot {
        try synchronized {
            let vault = try loadVaultUnlocked()
            if vault.requiresPersistence {
                try saveVaultUnlocked(vault.envelope)
            }
            return MultipleAccountJSONSnapshot(
                accountID: vault.envelope.currentAccountID,
                accountJSON: vault.envelope.currentSessionJSON
            )
        }
    }

    func switchAccount(to accountID: String) throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            guard vault.accounts[accountID] != nil else {
                throw MultipleAccountStoreError.accountNotFound
            }
            vault.currentAccountID = accountID
            vault.legacyCurrentJSON = nil
            try saveVaultUnlocked(vault)
        }
    }

    func deleteAccount(_ accountID: String) throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            guard vault.accounts[accountID] != nil else {
                throw MultipleAccountStoreError.accountNotFound
            }
            guard vault.currentAccountID != accountID else {
                throw MultipleAccountStoreError.cannotDeleteCurrentAccount
            }
            vault.accounts.removeValue(forKey: accountID)
            try saveVaultUnlocked(vault)
        }
    }

    func clearCurrentAccount() throws {
        try synchronized {
            var vault = try loadVaultUnlocked().envelope
            try clearCurrentAccountUnlocked(vault: &vault)
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadRawUnlocked() throws -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidUTF8
        }
        return value
    }

    private func saveRawUnlocked(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.keychain(updateStatus)
        }

        var item = itemQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.keychain(addStatus)
        }
    }

    private func clearUnlocked() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func loadVaultUnlocked() throws -> LoadedVault {
        guard let rawValue = try loadRawUnlocked() else {
            return LoadedVault(envelope: .empty, requiresPersistence: false)
        }
        if let data = rawValue.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(AccountVaultEnvelope.self, from: data),
           envelope.format == AccountVaultEnvelope.currentFormat {
            return LoadedVault(envelope: envelope.normalized(), requiresPersistence: false)
        }

        var migrated = AccountVaultEnvelope.empty
        upsert(rawValue, into: &migrated)
        return LoadedVault(envelope: migrated, requiresPersistence: true)
    }

    private func saveVaultUnlocked(_ vault: AccountVaultEnvelope) throws {
        if vault.accounts.isEmpty, vault.legacyCurrentJSON == nil {
            try clearUnlocked()
            return
        }
        let data = try JSONEncoder().encode(vault.normalized())
        guard let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidUTF8
        }
        try saveRawUnlocked(value)
    }

    private func upsert(_ accountJSON: String, into vault: inout AccountVaultEnvelope) {
        guard let summary = Self.summary(in: accountJSON) else {
            vault.currentAccountID = nil
            vault.legacyCurrentJSON = accountJSON
            return
        }
        vault.accounts[summary.id] = AccountVaultRecord(
            summary: summary,
            sessionJSON: accountJSON
        )
        vault.currentAccountID = summary.id
        vault.legacyCurrentJSON = nil
    }

    private func clearCurrentAccountUnlocked(vault: inout AccountVaultEnvelope) throws {
        if let currentAccountID = vault.currentAccountID {
            vault.accounts.removeValue(forKey: currentAccountID)
        }
        vault.currentAccountID = nil
        vault.legacyCurrentJSON = nil
        try saveVaultUnlocked(vault)
    }

    private static func summary(in accountJSON: String) -> NativeSavedAccountSummary? {
        guard let data = accountJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["login"] as? Bool == true,
              let profile = root["profile"] as? [String: Any]
        else { return nil }
        let rawID = (profile["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawToken = (profile["urlToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID: String
        if let rawID, !rawID.isEmpty {
            stableID = rawID
        } else if let rawToken, !rawToken.isEmpty {
            stableID = "url:\(rawToken)"
        } else {
            return nil
        }
        let profileName = (profile["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = (root["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [profileName, username].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "知乎账号"
        let avatarURL = (profile["avatarUrl"] as? String).flatMap(URL.init(string:))
        return NativeSavedAccountSummary(
            id: stableID,
            name: name,
            urlToken: rawToken?.isEmpty == false ? rawToken : nil,
            avatarURL: avatarURL
        )
    }
}

private struct LoadedVault {
    var envelope: AccountVaultEnvelope
    var requiresPersistence: Bool
}

private struct AccountVaultRecord: Codable {
    let summary: NativeSavedAccountSummary
    let sessionJSON: String
}

private struct AccountVaultEnvelope: Codable {
    static let currentFormat = "zhihu-plus-plus-account-vault-v2"
    static let empty = AccountVaultEnvelope(
        format: currentFormat,
        currentAccountID: nil,
        accounts: [:],
        legacyCurrentJSON: nil
    )

    let format: String
    var currentAccountID: String?
    var accounts: [String: AccountVaultRecord]
    var legacyCurrentJSON: String?

    var currentSessionJSON: String? {
        if let currentAccountID {
            return accounts[currentAccountID]?.sessionJSON
        }
        return legacyCurrentJSON
    }

    func normalized() -> AccountVaultEnvelope {
        var result = self
        if let currentAccountID, accounts[currentAccountID] == nil {
            result.currentAccountID = nil
        }
        return result
    }
}
