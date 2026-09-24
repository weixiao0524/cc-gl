import Foundation
import Security
import LocalAuthentication

public struct Profile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var secretID: UUID

    public init(id: UUID = UUID(), name: String, baseURL: String, secretID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.secretID = secretID
    }
}

public protocol SecretStorage {
    func read(_ id: UUID) throws -> String
    func write(_ value: String, id: UUID) throws
    func delete(_ id: UUID) throws
}

/// Keychain-backed secrets. Every instance shares the process-wide `KeychainVault`, so profile keys and
/// the cloud-sync key are unlocked together with a single keychain prompt (see `KeychainVault`).
public final class KeychainStorage: SecretStorage {
    private let vault: KeychainVault
    public init() { vault = .shared }
    init(vault: KeychainVault) { self.vault = vault }

    public func read(_ id: UUID) throws -> String { try vault.read(id) }
    public func write(_ value: String, id: UUID) throws { try vault.write(value, id: id) }
    public func delete(_ id: UUID) throws { try vault.delete(id) }
}

public final class ProfileStore {
    private struct Document: Codable {
        var profiles: [Profile]
        var syncStates: [String: Data] = [:]
    }
    private func document() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document(profiles: []) }
        let data = try SecureFile.read(url).0
        if let legacy = try? JSONDecoder().decode([Profile].self, from: data) { return Document(profiles: legacy) }
        guard let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            throw ConfigError("配置收藏文件损坏；不会覆盖原文件。")
        }
        return doc
    }
    public func syncState(_ name: String) throws -> Data? { try document().syncStates[name] }
    public func saveSyncState(_ data: Data, name: String) throws {
        try SecureFile.locked(in: directory) {
            var doc = try document()
            doc.syncStates[name] = data
            try SecureFile.write(JSONEncoder().encode(doc), to: url)
        }
    }

    private let directory: URL
    private var url: URL { directory.appendingPathComponent("profiles.json") }
    private let secrets: SecretStorage

    public init(directory: URL, secrets: SecretStorage = KeychainStorage()) {
        self.directory = directory
        self.secrets = secrets
    }

    public func load() throws -> [Profile] {
        let items = try document().profiles
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.secretID)).count == items.count else {
            throw ConfigError("配置收藏文件损坏；不会覆盖原文件。")
        }
        return items
    }

    public func key(for profile: Profile) throws -> String { try secrets.read(profile.secretID) }

    @discardableResult
    public func save(_ profile: Profile, key: String) throws -> Profile {
        try SecureFile.locked(in: directory) { try saveLocked(profile, key: key) }
    }

    private func saveLocked(_ profile: Profile, key: String) throws -> Profile {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError("请填写配置名称。")
        }
        try ConfigDocument.validateURL(profile.baseURL)
        try AuthDocument.validateKey(key)
        var items = try load()
        let old = items.first { $0.id == profile.id }
        var saved = profile
        saved.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.secretID = UUID()
        // New key first, then metadata commit. A failed metadata write never loses the old key.
        try secrets.write(key, id: saved.secretID)
        if let i = items.firstIndex(where: { $0.id == saved.id }) { items[i] = saved }
        else { items.append(saved) }
        do { try persist(items) }
        catch { try? secrets.delete(saved.secretID); throw error }
        if let old { try? secrets.delete(old.secretID) }
        return saved
    }

    public func delete(_ profile: Profile) throws {
        try SecureFile.locked(in: directory) { try deleteLocked(profile) }
    }

    private func deleteLocked(_ profile: Profile) throws {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == profile.id }) else { return }
        let removed = items.remove(at: index)
        try persist(items)
        try secrets.delete(removed.secretID)
    }

    public func syncItems() throws -> [SyncItem] {
        try SecureFile.locked(in: directory) {
            try load().map { SyncItem(id: $0.id, name: $0.name, baseURL: $0.baseURL, apiKey: try key(for: $0)) }
        }
    }

    public func replaceSyncedItems(_ incoming: [SyncItem], expected: [SyncItem], state: Data? = nil, stateName: String = "") throws {
        try SecureFile.locked(in: directory) {
            let current = try load()
            let actual = try current.map { SyncItem(id: $0.id, name: $0.name, baseURL: $0.baseURL, apiKey: try key(for: $0)) }
            guard actual == expected else { throw ConfigError("收藏在同步期间发生变化，稍后自动重试。") }
            guard Set(incoming.map(\.id)).count == incoming.count else { throw ConfigError("同步收藏存在重复标识。") }
            for item in incoming { try item.validate() }
            var created: [UUID] = []
            var next: [Profile] = []
            do {
                for item in incoming {
                    if let index = actual.firstIndex(of: item) { next.append(current[index]); continue }
                    let profile = Profile(id: item.id, name: item.name, baseURL: item.baseURL)
                    try secrets.write(item.apiKey, id: profile.secretID)
                    created.append(profile.secretID)
                    next.append(profile)
                }
                if next != current || state != nil {
                    var doc = try document()
                    doc.profiles = next
                    if let state { doc.syncStates[stateName] = state }
                    try SecureFile.write(JSONEncoder().encode(doc), to: url)
                }
            } catch {
                for id in created { try? secrets.delete(id) }
                throw error
            }
            let retained = Set(next.map(\.secretID))
            for old in current where !retained.contains(old.secretID) { try? secrets.delete(old.secretID) }
        }
    }

    private func persist(_ profiles: [Profile]) throws {
        try SecureFile.directory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var doc = try document()
        doc.profiles = profiles
        try SecureFile.write(encoder.encode(doc), to: url)
    }
}
