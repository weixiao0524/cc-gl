import Foundation
import CryptoKit
import CommonCrypto
import Security

public struct SyncItem: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public init(id: UUID, name: String, baseURL: String, apiKey: String) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.apiKey = apiKey
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 1024 else {
            throw ConfigError("同步收藏名称无效。")
        }
        try ConfigDocument.validateURL(baseURL)
        try AuthDocument.validateKey(apiKey)
    }
    var digest: String {
        // IDs can change when a concurrent branch becomes a conflict copy.
        let values = [name, baseURL, apiKey]
        return SHA256.hash(data: try! JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SyncEvent: Codable {
    var id: UUID
    var entity: UUID
    var parents: [UUID]
    var item: SyncItem?
}

struct SyncBinding: Codable {
    var entity: UUID
    var revision: UUID
    var digest: String
}

struct SyncState: Codable {
    var bindings: [UUID: SyncBinding] = [:]
}

public enum SyncCrypto {
    private struct Header: Codable {
        var version: Int
        var salt: Data
        var rounds: UInt32
        var check: Data
    }
    public static func create(password: String) throws -> (header: Data, key: Data) {
        guard password.count >= 12, password.utf8.count <= 1024 else {
            throw ConfigError("同步密码需为 12–1024 个 UTF-8 字节，且至少 12 个字符。")
        }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ConfigError("无法生成加密随机数。") }
        let key = try derive(password, salt: salt, rounds: 600_000)
        let header = Header(version: 1, salt: salt, rounds: 600_000,
                            check: try seal(Data("CodexConfig Sync v1".utf8), key: key))
        return (try JSONEncoder().encode(header), key)
    }
    public static func unlock(header data: Data, password: String) throws -> Data {
        guard data.count < 4096, password.utf8.count <= 1024,
              let header = try? JSONDecoder().decode(Header.self, from: data),
              header.version == 1, header.salt.count == 32, header.rounds == 600_000 else {
            throw ConfigError("同步空间格式不受支持或已损坏。")
        }
        let key = try derive(password, salt: header.salt, rounds: header.rounds)
        guard let check = try? open(header.check, key: key), check == Data("CodexConfig Sync v1".utf8) else {
            throw ConfigError("同步密码不正确，或同步空间已损坏。")
        }
        return key
    }
    static func validateHeader(_ data: Data, key: Data) throws {
        guard data.count < 4096, let header = try? JSONDecoder().decode(Header.self, from: data),
              header.version == 1, header.salt.count == 32, header.rounds == 600_000,
              (try? open(header.check, key: key)) == Data("CodexConfig Sync v1".utf8) else {
            throw ConfigError("同步空间已变化或无法解锁，请重新连接。")
        }
    }
    private static func derive(_ password: String, salt: Data, rounds: UInt32) throws -> Data {
        var output = Data(count: 32)
        let bytes = Array(password.utf8)
        let result = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                bytes.withUnsafeBytes { pass in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        pass.bindMemory(to: Int8.self).baseAddress, bytes.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                        out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard result == kCCSuccess else { throw ConfigError("同步密钥生成失败。") }
        return output
    }
    public static func seal(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw ConfigError("同步密钥无效。") }
        return try AES.GCM.seal(data, using: SymmetricKey(data: key),
                                authenticating: Data("CodexConfig/events/v1".utf8)).combined!
    }
    public static func open(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw ConfigError("同步密钥无效。") }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
                                    authenticating: Data("CodexConfig/events/v1".utf8))
        } catch { throw ConfigError("同步文件解密失败：密钥不匹配或文件已损坏。") }
    }
}

// Immutable, encrypted events avoid last-writer-wins loss when two Macs work offline.
// Parents express causality; concurrent live heads remain separate editable copies.
public final class CloudSyncEngine: @unchecked Sendable {
    public let folder: URL
    private let key: Data
    private let stateURL: URL
    private let store: ProfileStore
    public init(folder: URL, key: Data, stateDirectory: URL, store: ProfileStore) {
        self.folder = folder; self.key = key; self.store = store
        self.stateURL = stateDirectory.appendingPathComponent("sync-state-\(SHA256.hash(data: key).prefix(12).map { String(format: "%02x", $0) }.joined()).json")
    }

    public static func connect(folder: URL, password: String, create: Bool) throws -> Data {
        let headerURL = folder.appendingPathComponent("vault.json")
        if create {
            let generated = try SyncCrypto.create(password: password)
            var failure: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { url in
                do {
                    let existing = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    guard existing.filter({ $0 != ".DS_Store" }).isEmpty else {
                        throw ConfigError("新建同步空间需要空文件夹。已有空间请选择「连接已有」。")
                    }
                    try generated.header.write(to: url.appendingPathComponent("vault.json"), options: .withoutOverwriting)
                } catch { failure = error }
            }
            if let failure { throw failure }
            if let coordinationError { throw coordinationError }
            return generated.key
        }
        return try SyncCrypto.unlock(header: coordinatedRead(headerURL), password: password)
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error>?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { actual in
            result = Result { try SecureFile.read(actual).0 }
        }
        if let failure { throw failure }
        guard let result else { throw ConfigError("同步文件暂不可用，等待 iCloud 下载后重试。") }
        return try result.get()
    }

    private struct Outbox: Codable {
        var events: [SyncEvent]
        var state: SyncState
    }
    public func sync() throws -> Int {
        // Serialize local cycles, including multiple app instances.
        try SecureFile.locked(in: stateURL.deletingLastPathComponent().appendingPathComponent("sync-lock")) {
            try SyncCrypto.validateHeader(Self.coordinatedRead(folder.appendingPathComponent("vault.json")), key: key)
            let pendingURL = stateURL.appendingPathExtension("pending")
            func flush(_ outbox: Outbox) throws {
                for event in outbox.events { try publish(event) }
                try store.saveSyncState(JSONEncoder().encode(outbox.state), name: stateURL.lastPathComponent)
                try FileManager.default.removeItem(at: pendingURL)
            }
            if FileManager.default.fileExists(atPath: pendingURL.path) {
                let pending = try SyncCrypto.open(SecureFile.read(pendingURL).0, key: key)
                try flush(JSONDecoder().decode(Outbox.self, from: pending))
            }
            let original = try store.syncItems()
            var state = SyncState()
            if let data = try store.syncState(stateURL.lastPathComponent) {
                state = try JSONDecoder().decode(SyncState.self, from: data)
            }
            let directoryItems = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let placeholders = directoryItems.filter { $0.lastPathComponent.hasSuffix(".cglsync.icloud") }
            if !placeholders.isEmpty {
                for placeholder in placeholders {
                    let name = String(placeholder.lastPathComponent.dropFirst().dropLast(7))
                    try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
                }
                throw ConfigError("等待 iCloud 下载同步文件，稍后自动重试。")
            }
            let files = directoryItems.filter { $0.pathExtension == "cglsync" }
            guard files.count <= 20_000 else { throw ConfigError("同步历史过大，请暂停同步并新建同步空间。") }
            var events: [UUID: SyncEvent] = [:]
            var totalBytes = 0
            for file in files {
                let data = try Self.coordinatedRead(file)
                totalBytes += data.count
                guard totalBytes <= 64 * 1024 * 1024 else { throw ConfigError("同步历史超过 64 MB，请新建同步空间。") }
                let event = try JSONDecoder().decode(SyncEvent.self, from: SyncCrypto.open(data, key: key))
                guard event.parents.count <= 100, event.item == nil || event.item?.id == event.entity else {
                    throw ConfigError("同步记录结构无效。")
                }
                try event.item?.validate()
                if let existing = events[event.id] {
                    guard try JSONEncoder.sorted.encode(existing) == JSONEncoder.sorted.encode(event) else {
                        throw ConfigError("同步记录标识冲突，已暂停合并。")
                    }
                }
                events[event.id] = event
            }
            // A partially downloaded graph must never resurrect deleted or superseded values.
            for event in events.values {
                guard event.parents.allSatisfy({ events[$0]?.entity == event.entity }) else {
                    throw ConfigError("等待 iCloud 下载完整同步历史，稍后自动重试。")
                }
            }
            guard state.bindings.values.allSatisfy({ events[$0.revision] != nil }) else {
                throw ConfigError("本机同步历史尚未下载完整，未修改收藏。")
            }
            var outgoing: [SyncEvent] = []
            var acknowledged = state
            for item in original {
                let old = state.bindings[item.id]
                if old?.digest == item.digest { continue }
                var payload = item
                payload.id = old?.entity ?? item.id
                let event = SyncEvent(id: UUID(), entity: payload.id,
                                      parents: old.map { [$0.revision] } ?? [], item: payload)
                events[event.id] = event
                outgoing.append(event)
                acknowledged.bindings[item.id] = SyncBinding(entity: event.entity, revision: event.id, digest: item.digest)
            }
            let present = Set(original.map(\.id))
            for (id, binding) in state.bindings where !present.contains(id) {
                let event = SyncEvent(id: UUID(), entity: binding.entity, parents: [binding.revision], item: nil)
                events[event.id] = event
                outgoing.append(event)
                acknowledged.bindings.removeValue(forKey: id)
            }
            if !outgoing.isEmpty {
                let outbox = Outbox(events: outgoing, state: acknowledged)
                try SecureFile.directory(stateURL.deletingLastPathComponent())
                try SecureFile.write(SyncCrypto.seal(JSONEncoder().encode(outbox), key: key), to: pendingURL)
                try flush(outbox)
            }
            let superseded = Set(events.values.flatMap(\.parents))
            let heads = events.values.filter { !superseded.contains($0.id) && $0.item != nil }
            let groups = Dictionary(grouping: heads, by: \.entity)
            var merged: [SyncItem] = []
            var next = SyncState()
            var conflicts = 0
            for entity in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let branches = groups[entity]!.sorted { $0.id.uuidString < $1.id.uuidString }
                for (index, branch) in branches.enumerated() {
                    var item = branch.item!
                    item.id = index == 0 ? entity : branch.id
                    if index > 0 { item.name += "（同步冲突）"; conflicts += 1 }
                    merged.append(item)
                    next.bindings[item.id] = SyncBinding(entity: entity, revision: branch.id, digest: item.digest)
                }
            }
            try store.replaceSyncedItems(merged, expected: original, state: JSONEncoder().encode(next), stateName: stateURL.lastPathComponent)
            return conflicts
        }
    }

    private func publish(_ event: SyncEvent) throws {
        let encrypted = try SyncCrypto.seal(JSONEncoder().encode(event), key: key)
        let url = folder.appendingPathComponent(event.id.uuidString + ".cglsync")
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    let existing = try JSONDecoder().decode(SyncEvent.self, from: SyncCrypto.open(SecureFile.read(target).0, key: key))
                    guard try JSONEncoder.sorted.encode(existing) == JSONEncoder.sorted.encode(event) else {
                        throw ConfigError("同步记录标识冲突，未覆盖云端文件。")
                    }
                } else {
                    try encrypted.write(to: target, options: [.atomic])
                }
            }
            catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }
}
