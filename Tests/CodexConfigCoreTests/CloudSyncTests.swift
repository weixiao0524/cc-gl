import XCTest
@testable import CodexConfigCore

private final class SyncSecrets: SecretStorage {
    var values: [UUID: String] = [:]
    var fail = false
    func read(_ id: UUID) throws -> String {
        guard let value = values[id] else { throw ConfigError("missing test key") }
        return value
    }
    func write(_ value: String, id: UUID) throws {
        if fail { throw ConfigError("injected failure") }
        values[id] = value
    }
    func delete(_ id: UUID) throws { values.removeValue(forKey: id) }
}

final class CloudSyncTests: XCTestCase {
    var root: URL!
    var cloud: URL!
    var a: ProfileStore!
    var b: ProfileStore!
    var engineA: CloudSyncEngine!
    var engineB: CloudSyncEngine!
    private var secretsB: SyncSecrets!
    var key = Data()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let vault = try SyncCrypto.create(password: "test-sync-password")
        key = vault.key
        try vault.header.write(to: cloud.appendingPathComponent("vault.json"))
        a = ProfileStore(directory: root.appendingPathComponent("a"), secrets: SyncSecrets())
        secretsB = SyncSecrets()
        b = ProfileStore(directory: root.appendingPathComponent("b"), secrets: secretsB)
        engineA = CloudSyncEngine(folder: cloud, key: key, stateDirectory: root.appendingPathComponent("a"), store: a)
        engineB = CloudSyncEngine(folder: cloud, key: key, stateDirectory: root.appendingPathComponent("b"), store: b)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testPasswordEncryptionTamperAndWrongPassword() throws {
        let vault = try SyncCrypto.create(password: "a long test password")
        XCTAssertEqual(try SyncCrypto.unlock(header: vault.header, password: "a long test password"), vault.key)
        XCTAssertThrowsError(try SyncCrypto.unlock(header: vault.header, password: "wrong password"))
        XCTAssertThrowsError(try SyncCrypto.create(password: "short"))
        var encrypted = try SyncCrypto.seal(Data("secret-api-key".utf8), key: vault.key)
        XCTAssertEqual(try SyncCrypto.open(encrypted, key: vault.key), Data("secret-api-key".utf8))
        encrypted[15] ^= 1
        XCTAssertThrowsError(try SyncCrypto.open(encrypted, key: vault.key))
    }

    func testCrossMacCreateUpdateDeleteAndNoPlaintextOnDisk() throws {
        var item = try a.save(Profile(name: "日常", baseURL: "https://one.example"), key: "super-secret-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        XCTAssertEqual(try a.syncItems(), try b.syncItems())
        for url in try FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data("super-secret-key".utf8)))
            XCTAssertNil(bytes.range(of: Data("https://one.example".utf8)))
        }
        let local = try Data(contentsOf: root.appendingPathComponent("b/profiles.json"))
        XCTAssertNil(local.range(of: Data("super-secret-key".utf8)))
        item.name = "修改后"
        _ = try a.save(item, key: "updated-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        XCTAssertEqual(try b.syncItems().first?.apiKey, "updated-key")
        try b.delete(b.load()[0])
        _ = try engineB.sync(); _ = try engineA.sync()
        XCTAssertTrue(try a.load().isEmpty)
        _ = try engineB.sync()
        XCTAssertTrue(try b.load().isEmpty)
    }

    func testConcurrentEditsConvergeAndConflictCanBeDeleted() throws {
        _ = try a.save(Profile(name: "base", baseURL: "https://one.example"), key: "base-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        var left = try a.load()[0]; left.name = "left"
        var right = try b.load()[0]; right.name = "right"
        _ = try a.save(left, key: "left-key"); _ = try b.save(right, key: "right-key")
        _ = try engineA.sync(); XCTAssertEqual(try engineB.sync(), 1); _ = try engineA.sync()
        XCTAssertEqual(try a.syncItems(), try b.syncItems())
        XCTAssertEqual(Set(try a.syncItems().map(\.apiKey)), Set(["left-key", "right-key"]))
        let conflict = try a.load().first { $0.name.contains("同步冲突") }!
        try a.delete(conflict)
        _ = try engineA.sync(); _ = try engineB.sync()
        XCTAssertEqual(try a.syncItems(), try b.syncItems())
        XCTAssertEqual(try b.load().count, 1)
    }

    func testConcurrentDeleteDoesNotLoseOfflineEdit() throws {
        _ = try a.save(Profile(name: "base", baseURL: "https://one.example"), key: "base-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        try a.delete(a.load()[0])
        var item = try b.load()[0]; item.name = "offline edit"
        _ = try b.save(item, key: "edited-key")
        _ = try engineA.sync(); _ = try engineB.sync(); _ = try engineA.sync()
        XCTAssertEqual(try a.syncItems().first?.apiKey, "edited-key")
        XCTAssertEqual(try a.syncItems(), try b.syncItems())
    }

    func testFailedKeychainImportRetriesWithoutLosingExistingData() throws {
        _ = try a.save(Profile(name: "a", baseURL: "https://one.example"), key: "a-key")
        _ = try b.save(Profile(name: "b", baseURL: "https://two.example"), key: "b-key")
        _ = try engineA.sync()
        let original = try b.syncItems()
        secretsB.fail = true
        XCTAssertThrowsError(try engineB.sync())
        XCTAssertEqual(try b.syncItems(), original)
        secretsB.fail = false
        _ = try engineB.sync(); _ = try engineA.sync()
        XCTAssertEqual(try a.syncItems(), try b.syncItems())
        XCTAssertEqual(try b.load().count, 2)
    }

    func testMissingHistoryAndCorruptedCiphertextNeverOverwriteLocal() throws {
        _ = try a.save(Profile(name: "a", baseURL: "https://one.example"), key: "a-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        let original = try b.syncItems()
        let file = try FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).first { $0.pathExtension == "cglsync" }!
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try engineB.sync())
        XCTAssertEqual(try b.syncItems(), original)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try engineB.sync())
        XCTAssertEqual(try b.syncItems(), original)
        try data.write(to: file)
        _ = try engineB.sync()
        XCTAssertEqual(try b.syncItems(), original)
    }

    func testRepeatedSyncDoesNotCreateNewEventsOrKeychainItems() throws {
        _ = try a.save(Profile(name: "a", baseURL: "https://one.example"), key: "a-key")
        _ = try engineA.sync(); _ = try engineB.sync()
        let original = try b.load()
        for _ in 0..<3 { _ = try engineA.sync(); _ = try engineB.sync() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path).count, 2)
        XCTAssertEqual(try b.load(), original)
    }
}
