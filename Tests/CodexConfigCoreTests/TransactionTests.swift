import XCTest
@testable import CodexConfigCore

final class TransactionTests: XCTestCase {
    private var root: URL!
    private var codex: URL!
    private var support: URL!
    private var service: ConfigurationService!
    private var config: URL { codex.appendingPathComponent("config.toml") }
    private var auth: URL { codex.appendingPathComponent("auth.json") }
    private let originalConfig = Data("# keep\nmodel_provider='custom'\n[model_providers.custom]\nrequires_openai_auth=true\nbase_url = 'https://old.example/v1' # keep too\n".utf8)
    private let originalAuth = Data("{\n  \"OPENAI_API_KEY\" : \"original-key\", \"unknown\": 42\n}\n".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cgl-tests-\(UUID().uuidString)")
        codex = root.appendingPathComponent("codex")
        support = root.appendingPathComponent("manager")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try originalConfig.write(to: config)
        try originalAuth.write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        service = ConfigurationService(codexDirectory: codex, supportDirectory: support)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testApplyRestoreAndPermissions() throws {
        let sentinel = codex.appendingPathComponent("untouched.json")
        try Data("do not touch".utf8).write(to: sentinel)
        let before = try service.load()
        try service.apply(baseURL: "https://new.example/v1", apiKey: "new-key", expected: before.snapshot)
        let after = try service.load()
        XCTAssertEqual(after.config.baseURL, "https://new.example/v1")
        XCTAssertEqual(after.auth.apiKey, "new-key")
        XCTAssertEqual(after.snapshot.configMode, 0o640)
        XCTAssertEqual(after.snapshot.authMode, 0o600)
        XCTAssertTrue(service.hasBackup)
        XCTAssertFalse(service.needsRecovery)
        XCTAssertEqual(try SecureFile.read(support.appendingPathComponent("last-change.json")).1, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: support.path)[.posixPermissions] as? Int, 0o700)
        try service.restore()
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        XCTAssertEqual(try Data(contentsOf: auth), originalAuth)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("do not touch".utf8))
        XCTAssertFalse(service.hasBackup)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: codex.path).contains { $0.hasPrefix(".cgl-") })
    }

    func testStaleSnapshotRejectsWithoutBackupOrChanges() throws {
        let old = try service.load().snapshot
        let external = originalConfig + Data("# external edit\n".utf8)
        try external.write(to: config)
        XCTAssertThrowsError(try service.apply(baseURL: "https://new.example", apiKey: "new", expected: old))
        XCTAssertEqual(try Data(contentsOf: config), external)
        XCTAssertEqual(try Data(contentsOf: auth), originalAuth)
        XCTAssertFalse(service.hasBackup)
    }

    func testSecondWriteFailureRollsBackFirst() throws {
        let before = try service.load().snapshot
        service.beforeReplace = { url in
            if url.lastPathComponent == "auth.json" { throw ConfigError("injected failure") }
        }
        XCTAssertThrowsError(try service.apply(baseURL: "https://new.example", apiKey: "new", expected: before))
        XCTAssertEqual(try service.load().snapshot, before)
        XCTAssertFalse(service.hasBackup)
    }

    func testConcurrentExternalWriteIsNeverOverwrittenDuringRollback() throws {
        let before = try service.load().snapshot
        let externalAuth = Data(#"{"OPENAI_API_KEY":"written-by-another-program"}"#.utf8)
        service.beforeReplace = { url in
            if url.lastPathComponent == "auth.json" { try externalAuth.write(to: url) }
        }
        XCTAssertThrowsError(try service.apply(baseURL: "https://new.example", apiKey: "new", expected: before))
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
        XCTAssertTrue(service.hasBackup)
        XCTAssertTrue(service.needsRecovery)
        service.beforeReplace = nil
        XCTAssertThrowsError(try service.restore())
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
    }

    func testRestoreRejectsUnrelatedChanges() throws {
        let before = try service.load().snapshot
        try service.apply(baseURL: "https://new.example", apiKey: "new", expected: before)
        let edited = try Data(contentsOf: config) + Data("# a new unrelated option\n".utf8)
        try edited.write(to: config)
        XCTAssertThrowsError(try service.restore())
        XCTAssertEqual(try Data(contentsOf: config), edited)
        XCTAssertTrue(service.hasBackup)
    }

    func testPendingTransactionCanRecoverAfterRestart() throws {
        let before = try service.load().snapshot
        var authAttempts = 0
        service.beforeReplace = { url in
            if url.lastPathComponent == "auth.json" { authAttempts += 1; throw ConfigError("fail auth") }
            if url.lastPathComponent == "config.toml" && authAttempts > 0 { throw ConfigError("fail rollback") }
        }
        XCTAssertThrowsError(try service.apply(baseURL: "https://new.example", apiKey: "new", expected: before))
        XCTAssertTrue(service.needsRecovery)
        let restarted = ConfigurationService(codexDirectory: codex, supportDirectory: support)
        XCTAssertThrowsError(try restarted.apply(baseURL: "https://third.example", apiKey: "third", expected: restarted.load().snapshot))
        try restarted.restore()
        XCTAssertEqual(try restarted.load().snapshot, before)
        XCTAssertFalse(restarted.hasBackup)
    }

    func testRejectSymlinkInsteadOfFollowingIt() throws {
        let real = codex.appendingPathComponent("real-auth.json")
        try FileManager.default.moveItem(at: auth, to: real)
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: real)
        XCTAssertThrowsError(try service.load())
        XCTAssertEqual(try Data(contentsOf: real), originalAuth)
    }

    func testInvalidInputNeverChangesFiles() throws {
        let before = try service.load().snapshot
        XCTAssertThrowsError(try service.apply(baseURL: "invalid", apiKey: "key", expected: before))
        XCTAssertThrowsError(try service.apply(baseURL: "https://new.example", apiKey: "", expected: before))
        XCTAssertEqual(try service.load().snapshot, before)
        XCTAssertFalse(service.hasBackup)
    }

    func testLatestBackupRestoresOnlyOneStep() throws {
        try service.apply(baseURL: "https://one.example", apiKey: "one", expected: service.load().snapshot)
        let one = try service.load().snapshot
        try service.apply(baseURL: "https://two.example", apiKey: "two", expected: one)
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, one)
    }

    func testSameValuesDoNotReformatFilesOrCreateBackup() throws {
        let before = try service.load()
        try service.apply(baseURL: before.config.baseURL, apiKey: before.auth.apiKey, expected: before.snapshot)
        XCTAssertEqual(try service.load().snapshot, before.snapshot)
        XCTAssertFalse(service.hasBackup)
    }

    func testChangingOnlyKeyLeavesConfigByteIdentical() throws {
        let before = try service.load()
        try service.apply(baseURL: before.config.baseURL, apiKey: "new-key", expected: before.snapshot)
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, before.snapshot)
    }

    func testTamperedBackupCannotRestoreUnrelatedFields() throws {
        try service.apply(baseURL: "https://one.example", apiKey: "one", expected: service.load().snapshot)
        let url = support.appendingPathComponent("last-change.json")
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var before = journal["before"] as! [String: Any]
        before["config"] = (originalConfig + Data("# unrelated injected change\n".utf8)).base64EncodedString()
        journal["before"] = before
        try JSONSerialization.data(withJSONObject: journal).write(to: url)
        let snapshot = try service.load().snapshot
        XCTAssertTrue(service.needsRecovery)
        XCTAssertThrowsError(try service.restore())
        XCTAssertEqual(try service.load().snapshot, snapshot)
    }
}
