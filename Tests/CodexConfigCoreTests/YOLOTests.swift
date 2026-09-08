import XCTest
@testable import CodexConfigCore

final class YOLOTests: XCTestCase {
    private let provider = "model_provider='custom'\n[model_providers.custom]\nrequires_openai_auth=true\nbase_url='https://example.com/v1'\n"

    func testMissingRootFieldsAndExactRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data(provider.utf8).write(to: codex.appendingPathComponent("config.toml"))
        try Data("{\"OPENAI_API_KEY\":\"test-key\"}".utf8).write(to: codex.appendingPathComponent("auth.json"))
        let service = ConfigurationService(codexDirectory: codex, supportDirectory: root.appendingPathComponent("support"))
        let before = try service.load()
        XCTAssertFalse(before.config.yoloEnabled)
        try service.setYOLO(true, expected: before.snapshot)
        let enabled = try service.load()
        XCTAssertTrue(enabled.config.yoloEnabled)
        XCTAssertEqual(enabled.snapshot.auth, before.snapshot.auth)
        XCTAssertFalse(service.needsRecovery)
        try service.setYOLO(true, expected: enabled.snapshot)
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, before.snapshot)
        try service.setYOLO(true, expected: before.snapshot)
        let on = try service.load().snapshot
        try service.setYOLO(false, expected: on)
        let off = try service.load()
        XCTAssertFalse(off.config.yoloEnabled)
        XCTAssertTrue(String(decoding: off.snapshot.config, as: UTF8.self).contains("sandbox_mode = \"workspace-write\""))
        XCTAssertThrowsError(try service.setYOLO(true, expected: on))
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, on)
    }

    func testExactValuePatchingWithUnicodeCommentsAndNestedKeys() throws {
        let input = "# 中文 🐈\napproval_policy = 'on-request' # approval\n\"sandbox_mode\" = 'read-only' # sandbox\n" + provider + "[other]\napproval_policy='untrusted'\nsandbox_mode='read-only'\n"
        let document = try ConfigDocument(data: Data(input.utf8))
        let output = try document.replacingYOLO(true)
        let expected = input.replacingOccurrences(of: "approval_policy = 'on-request'", with: "approval_policy = \"never\"")
            .replacingOccurrences(of: "\"sandbox_mode\" = 'read-only'", with: "\"sandbox_mode\" = \"danger-full-access\"")
        XCTAssertEqual(output, Data(expected.utf8))
        XCTAssertTrue(try ConfigDocument(data: output).yoloEnabled)
        XCTAssertEqual(try ConfigDocument(data: output).replacingYOLO(true), output)
    }

    func testBOMAndCRLFPreservedWhenInserting() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(provider.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let result = try ConfigDocument(data: original).replacingYOLO(true)
        let expected = Data([0xEF, 0xBB, 0xBF]) + Data("approval_policy = \"never\"\r\nsandbox_mode = \"danger-full-access\"\r\n".utf8) + original.dropFirst(3)
        XCTAssertEqual(result, expected)
    }

    func testPartialModeAndInvalidTypes() throws {
        let partial = try ConfigDocument(data: Data(("approval_policy='never'\n" + provider).utf8))
        XCTAssertFalse(partial.yoloEnabled)
        XCTAssertTrue(try ConfigDocument(data: partial.replacingYOLO(true)).yoloEnabled)
        let malformed = try ConfigDocument(data: Data(("approval_policy=true\n" + provider).utf8))
        XCTAssertThrowsError(try malformed.replacingYOLO(true))
    }
}
