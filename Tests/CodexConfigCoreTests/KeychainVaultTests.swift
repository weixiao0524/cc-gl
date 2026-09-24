import XCTest
import Security
@testable import CodexConfigCore

/// In-memory keychain that counts secret-data reads, i.e. the operations that would prompt the user.
private final class MemoryKeychain: KeychainBackend {
    var items: [String: [String: Data]] = [:]
    var dataReads: [String] = []
    var failReads: Set<String> = []  // "service/account" pairs that return errSecUserCanceled
    var failWrites = false

    func read(service: String, account: String) -> (OSStatus, Data?) {
        dataReads.append("\(service)/\(account)")
        if failReads.contains("\(service)/\(account)") { return (errSecUserCanceled, nil) }
        guard let data = items[service]?[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func write(_ data: Data, service: String, account: String, label: String) -> OSStatus {
        if failWrites { return errSecAuthFailed }
        items[service, default: [:]][account] = data
        return errSecSuccess
    }
    func delete(service: String, account: String) -> OSStatus {
        items[service]?.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
    func accounts(service: String) -> (OSStatus, [String]) {
        let names = Array(items[service, default: [:]].keys)
        return (names.isEmpty ? errSecItemNotFound : errSecSuccess, names)
    }
    func vault() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self,
                                 from: XCTUnwrap(items[KeychainVault.service]?[KeychainVault.account]))
    }
}

final class KeychainVaultTests: XCTestCase {
    func testManySecretsUnlockWithOneVaultRead() throws {
        let keychain = MemoryKeychain()
        let ids = (0..<5).map { _ in UUID() }
        let writer = KeychainStorage(vault: KeychainVault(backend: keychain))
        for (index, id) in ids.enumerated() { try writer.write("key-\(index)", id: id) }

        // A fresh process: reading every profile must touch the keychain data exactly once.
        keychain.dataReads = []
        let reader = KeychainStorage(vault: KeychainVault(backend: keychain))
        for (index, id) in ids.enumerated() { XCTAssertEqual(try reader.read(id), "key-\(index)") }
        XCTAssertEqual(keychain.dataReads, ["\(KeychainVault.service)/\(KeychainVault.account)"])
    }

    func testInstancesSharingAVaultDoNotOverwriteEachOther() throws {
        let vault = KeychainVault(backend: MemoryKeychain())
        let profiles = KeychainStorage(vault: vault), sync = KeychainStorage(vault: vault)
        let a = UUID(), b = UUID()
        try profiles.write("profile-key", id: a)
        try sync.write("sync-key", id: b)
        XCTAssertEqual(try profiles.read(b), "sync-key")
        XCTAssertEqual(try sync.read(a), "profile-key")
    }

    func testLegacyItemsMigrateOnceAndAreRemoved() throws {
        let keychain = MemoryKeychain()
        let a = UUID(), b = UUID()
        keychain.items[KeychainVault.legacyService] = [a.uuidString: Data("old-a".utf8), b.uuidString: Data("old-b".utf8),
                                                       "not-a-uuid": Data("ignored".utf8)]
        let storage = KeychainStorage(vault: KeychainVault(backend: keychain))
        XCTAssertEqual(try storage.read(a), "old-a")
        XCTAssertEqual(try storage.read(b), "old-b")
        XCTAssertEqual(try keychain.vault(), [a.uuidString: "old-a", b.uuidString: "old-b"])
        XCTAssertEqual(Array(keychain.items[KeychainVault.legacyService, default: [:]].keys), ["not-a-uuid"])

        // Next launch: only the vault is read, no legacy prompts.
        keychain.dataReads = []
        XCTAssertEqual(try KeychainStorage(vault: KeychainVault(backend: keychain)).read(b), "old-b")
        XCTAssertEqual(keychain.dataReads.count, 1)
    }

    func testCancelledLegacyPromptIsRetriedOnDemand() throws {
        let keychain = MemoryKeychain()
        let a = UUID(), b = UUID()
        keychain.items[KeychainVault.legacyService] = [a.uuidString: Data("old-a".utf8), b.uuidString: Data("old-b".utf8)]
        keychain.failReads = ["\(KeychainVault.legacyService)/\(b.uuidString)"]
        let storage = KeychainStorage(vault: KeychainVault(backend: keychain))
        XCTAssertEqual(try storage.read(a), "old-a")
        XCTAssertThrowsError(try storage.read(b))
        XCTAssertNotNil(keychain.items[KeychainVault.legacyService]?[b.uuidString], "Unmigrated key must not be deleted")
        keychain.failReads = []
        XCTAssertEqual(try storage.read(b), "old-b")
        XCTAssertNil(keychain.items[KeychainVault.legacyService]?[b.uuidString])
    }

    func testFailedVaultReadIsNotCached() throws {
        let keychain = MemoryKeychain()
        let id = UUID()
        try KeychainStorage(vault: KeychainVault(backend: keychain)).write("secret", id: id)
        keychain.failReads = ["\(KeychainVault.service)/\(KeychainVault.account)"]
        let storage = KeychainStorage(vault: KeychainVault(backend: keychain))
        XCTAssertThrowsError(try storage.read(id))
        keychain.failReads = []
        XCTAssertEqual(try storage.read(id), "secret")
    }

    func testFailedWriteKeepsPreviousValue() throws {
        let keychain = MemoryKeychain()
        let id = UUID()
        let storage = KeychainStorage(vault: KeychainVault(backend: keychain))
        try storage.write("first", id: id)
        keychain.failWrites = true
        XCTAssertThrowsError(try storage.write("second", id: id))
        XCTAssertThrowsError(try storage.delete(id))
        XCTAssertEqual(try storage.read(id), "first")
        XCTAssertEqual(try keychain.vault()[id.uuidString], "first")
    }

    func testDeleteRemovesSecret() throws {
        let keychain = MemoryKeychain()
        let id = UUID()
        keychain.items[KeychainVault.legacyService] = [:]
        let storage = KeychainStorage(vault: KeychainVault(backend: keychain))
        try storage.write("secret", id: id)
        try storage.delete(id)
        XCTAssertThrowsError(try storage.read(id))
        XCTAssertNil(try keychain.vault()[id.uuidString])
    }
}
