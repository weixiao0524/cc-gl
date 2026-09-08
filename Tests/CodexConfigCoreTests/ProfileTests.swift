import XCTest
@testable import CodexConfigCore

private final class MemorySecrets: SecretStorage {
    var values: [UUID: String] = [:]
    var failWrites = false
    func read(_ id: UUID) throws -> String {
        guard let value = values[id] else { throw ConfigError("missing") }
        return value
    }
    func write(_ value: String, id: UUID) throws {
        if failWrites { throw ConfigError("injected keychain failure") }
        values[id] = value
    }
    func delete(_ id: UUID) throws { values.removeValue(forKey: id) }
}

final class ProfileTests: XCTestCase {
    func testCRUDKeepsSecretsOutOfMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cgl-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecrets()
        let store = ProfileStore(directory: root, secrets: secrets)
        XCTAssertEqual(try store.load(), [])
        let first = try store.save(Profile(name: " 日常 ", baseURL: "https://one.example"), key: "secret-one")
        XCTAssertEqual(first.name, "日常")
        XCTAssertEqual(try store.key(for: first), "secret-one")
        let raw = try String(contentsOf: root.appendingPathComponent("profiles.json"))
        XCTAssertFalse(raw.contains("secret-one"))
        var edited = first
        edited.baseURL = "https://two.example"
        secrets.failWrites = true
        XCTAssertThrowsError(try store.save(edited, key: "secret-two"))
        XCTAssertEqual(try store.load(), [first])
        XCTAssertEqual(try store.key(for: first), "secret-one")
        secrets.failWrites = false
        let second = try store.save(edited, key: "secret-two")
        XCTAssertNil(secrets.values[first.secretID])
        XCTAssertEqual(try store.load(), [second])
        try store.delete(second)
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testCorruptedProfileFileIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cgl-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("profiles.json")
        let malformed = Data("broken".utf8)
        try malformed.write(to: url)
        let store = ProfileStore(directory: root, secrets: MemorySecrets())
        XCTAssertThrowsError(try store.save(Profile(name: "test", baseURL: "https://a.example"), key: "secret"))
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }
}
