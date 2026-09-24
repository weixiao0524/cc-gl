import Foundation
import Security
import LocalAuthentication
import os

private let keychainLog = Logger(subsystem: "CodexConfig", category: "keychain")

/// Minimal generic-password operations, abstracted so the vault logic can be tested without the
/// real login keychain.
protocol KeychainBackend: AnyObject {
    func read(service: String, account: String) -> (OSStatus, Data?)
    /// Adds the item, or replaces its data when it already exists.
    func write(_ data: Data, service: String, account: String, label: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
    /// Lists account names only (attributes, never secret data), so it does not trigger a password prompt.
    func accounts(service: String) -> (OSStatus, [String])
}

final class SystemKeychainBackend: KeychainBackend {
    private let authContext = LAContext()

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authContext
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func write(_ data: Data, service: String, account: String, label: String) -> OSStatus {
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = label
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        return SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service, account) as CFDictionary)
    }

    func accounts(service: String) -> (OSStatus, [String]) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let names = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        return (status, names)
    }
}

/// All secrets (profile API keys and the cloud-sync key) live in ONE keychain item.
///
/// The legacy login keychain authorises access per item, and an ad-hoc signed build counts as a new
/// app after every update. With one item per profile that meant one password prompt per profile;
/// with a single vault item the user unlocks everything with one prompt, loaded once per process.
///
/// Items written by older versions (one per secret under `legacyService`) are migrated into the vault
/// the first time it loads. Each legacy item may prompt once during that migration; that is a
/// system limitation because those items still carry their old per-item access lists.
final class KeychainVault {
    static let shared = KeychainVault(backend: SystemKeychainBackend())
    static let service = "local.cc-gl.CodexConfig.vault"
    static let account = "secrets"
    static let legacyService = "local.cc-gl.CodexConfig.profiles"
    private static let label = "Codex 配置 · 密钥库"

    private let backend: KeychainBackend
    private let lock = NSLock()
    // nil until the vault has been read successfully; failures are never cached so a cancelled
    // prompt can be retried on the next access.
    private var cache: [String: String]?

    init(backend: KeychainBackend) { self.backend = backend }

    func read(_ id: UUID) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var secrets = try loadLocked()
        if let key = secrets[id.uuidString] { return key }
        // A legacy item that could not be migrated during load (e.g. its prompt was cancelled) is
        // retried on demand, so this profile still works in the current session.
        guard let key = readLegacy(id.uuidString) else {
            throw ConfigError("钥匙串中找不到此密钥。可重新输入密钥后保存。")
        }
        secrets[id.uuidString] = key
        try persistLocked(secrets)
        _ = backend.delete(service: Self.legacyService, account: id.uuidString)
        keychainLog.info("Migrated one legacy keychain item on demand")
        return key
    }

    func write(_ value: String, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var secrets = try loadLocked()
        secrets[id.uuidString] = value
        try persistLocked(secrets)
    }

    func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var secrets = try loadLocked()
        // Also remove a leftover legacy copy (best effort) so a deleted key does not linger.
        _ = backend.delete(service: Self.legacyService, account: id.uuidString)
        guard secrets.removeValue(forKey: id.uuidString) != nil else { return }
        try persistLocked(secrets)
    }

    /// Loads the vault once per process, migrating legacy per-secret items on the first load.
    private func loadLocked() throws -> [String: String] {
        if let cache { return cache }
        var secrets: [String: String] = [:]
        let (status, data) = backend.read(service: Self.service, account: Self.account)
        switch status {
        case errSecSuccess:
            guard let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                keychainLog.error("Keychain vault content is unreadable")
                throw ConfigError("钥匙串中的密钥库格式异常；为避免覆盖，未做任何修改。")
            }
            secrets = decoded
        case errSecItemNotFound:
            break
        default:
            keychainLog.error("Keychain vault read failed, status \(status, privacy: .public)")
            throw ConfigError("无法读取钥匙串中的密钥库（状态 \(status)）。请在弹窗中输入登录密码并选择「始终允许」。")
        }

        // Migration: listing accounts returns attributes only, so it never prompts.
        let legacy = backend.accounts(service: Self.legacyService).1.filter { UUID(uuidString: $0) != nil }
        var migrated: [String] = []
        for account in legacy where secrets[account] == nil {
            guard let key = readLegacy(account) else { continue }  // retried on demand in read(_:)
            secrets[account] = key
            migrated.append(account)
        }
        if !migrated.isEmpty {
            // Persist before deleting anything, so a failed write never loses a key.
            try persistLocked(secrets)
            keychainLog.info("Migrated \(migrated.count, privacy: .public) legacy keychain items into the vault")
        }
        // Delete legacy copies that are safely in the vault (including leftovers from an earlier run).
        for account in legacy where secrets[account] != nil {
            let deleted = backend.delete(service: Self.legacyService, account: account)
            if deleted != errSecSuccess && deleted != errSecItemNotFound {
                keychainLog.notice("Could not delete a legacy keychain item, status \(deleted, privacy: .public)")
            }
        }
        cache = secrets
        keychainLog.info("Keychain vault loaded with \(secrets.count, privacy: .public) secrets")
        return secrets
    }

    private func readLegacy(_ account: String) -> String? {
        let (status, data) = backend.read(service: Self.legacyService, account: account)
        guard status == errSecSuccess, let data, let key = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                keychainLog.notice("Legacy keychain item not migrated, status \(status, privacy: .public)")
            }
            return nil
        }
        return key
    }

    /// Writes the whole vault; the in-memory cache only changes after the keychain accepted it.
    private func persistLocked(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let status = backend.write(data, service: Self.service, account: Self.account, label: Self.label)
        guard status == errSecSuccess else {
            keychainLog.error("Keychain vault write failed, status \(status, privacy: .public)")
            throw ConfigError("密钥保存到钥匙串失败（状态 \(status)）。")
        }
        cache = secrets
    }
}
