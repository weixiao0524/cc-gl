import XCTest
@testable import CodexConfigCore

final class ModelSettingsTests: XCTestCase {
    private let provider = "model_provider='custom'\n[model_providers.custom]\nrequires_openai_auth=true\nbase_url='https://example.com/v1'\n"
    private var root: URL!
    private var instructions: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cgl-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        instructions = root.appendingPathComponent("model_instructions.md")
        try Data("# demo instructions\n".utf8).write(to: instructions)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInsertReplaceAndRemovePreserveOtherBytes() throws {
        let input = "# keep 🐈\n" + provider + "[other]\nmodel_context_window = 1\nmodel_instructions_file = '/nested'\n"
        let document = try ConfigDocument(data: Data(input.utf8))
        XCTAssertNil(try document.modelSettings().instructionsFile)
        XCTAssertNil(try document.modelSettings().contextWindow)

        let inserted = try document.replacingRoots([
            .setString("model_instructions_file", instructions.path),
            .setInteger("model_context_window", 272_000),
            .setInteger("model_auto_compact_token_limit", 240_000)
        ])
        let insertedText = String(decoding: inserted, as: UTF8.self)
        XCTAssertTrue(insertedText.hasPrefix("model_instructions_file = \"\(instructions.path)\"\nmodel_context_window = 272000\nmodel_auto_compact_token_limit = 240000\n# keep 🐈\n"))
        XCTAssertTrue(insertedText.contains("[other]\nmodel_context_window = 1\nmodel_instructions_file = '/nested'\n"))
        let settings = try ConfigDocument(data: inserted).modelSettings()
        XCTAssertEqual(settings.instructionsFile, instructions.path)
        XCTAssertEqual(settings.contextWindow, 272_000)
        XCTAssertEqual(settings.autoCompactTokenLimit, 240_000)
        XCTAssertEqual(try ConfigDocument(data: inserted).replacingRoots([
            .setString("model_instructions_file", instructions.path),
            .setInteger("model_context_window", 272_000),
            .setInteger("model_auto_compact_token_limit", 240_000)
        ]), inserted)

        let other = root.appendingPathComponent("other.md")
        try Data("other\n".utf8).write(to: other)
        let replaced = try ConfigDocument(data: inserted).replacingRoots([
            .setString("model_instructions_file", other.path)
        ])
        XCTAssertTrue(String(decoding: replaced, as: UTF8.self).contains("model_instructions_file = \"\(other.path)\""))
        XCTAssertTrue(String(decoding: replaced, as: UTF8.self).contains("model_context_window = 272000"))

        let cleared = try ConfigDocument(data: replaced).replacingRoots([
            .remove("model_instructions_file"),
            .remove("model_context_window"),
            .remove("model_auto_compact_token_limit")
        ])
        XCTAssertEqual(cleared, Data(input.utf8))
        XCTAssertEqual(try ConfigDocument(data: cleared).modelSettings(), ModelSettings())
    }

    func testBOMCRLFQuotedKeysAndTrailingComments() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data((
            "\"model_context_window\" = 128000 # keep\n" + provider
        ).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let updated = try ConfigDocument(data: original).replacingRoots([
            .setInteger("model_context_window", 272_000),
            .setInteger("model_auto_compact_token_limit", 240_000)
        ])
        XCTAssertTrue(updated.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: updated.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.contains("\"model_context_window\" = 272000 # keep"))
        XCTAssertTrue(text.hasPrefix("model_auto_compact_token_limit = 240000\r\n"))
        let cleared = try ConfigDocument(data: updated).replacingRoots([.remove("model_auto_compact_token_limit")])
        XCTAssertFalse(String(decoding: cleared, as: UTF8.self).contains("model_auto_compact_token_limit"))
        XCTAssertTrue(String(decoding: cleared, as: UTF8.self).contains("\"model_context_window\" = 272000 # keep"))
    }

    func testRejectsWrongTypesAndCompactAtOrAboveWindow() throws {
        let boolWindow = try ConfigDocument(data: Data(("model_context_window = true\n" + provider).utf8))
        XCTAssertThrowsError(try boolWindow.modelSettings())
        XCTAssertThrowsError(try boolWindow.replacingRoots([.setInteger("model_context_window", 128_000)]))
        let document = try ConfigDocument(data: Data(provider.utf8))
        XCTAssertThrowsError(try document.replacingRoots([
            .setInteger("model_context_window", 128_000),
            .setInteger("model_auto_compact_token_limit", 128_000)
        ]))
        XCTAssertThrowsError(try document.replacingRoots([.setInteger("model_context_window", 100)]))
        XCTAssertThrowsError(try document.replacingRoots([.setString("model_instructions_file", "relative.md")]))
        XCTAssertThrowsError(try document.replacingRoots([.setString("model_instructions_file", "/missing/instructions.md")]))
    }

    func testServiceWritesOnlyTargetFieldsAndRestores() throws {
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data(provider.utf8).write(to: codex.appendingPathComponent("config.toml"))
        try Data("{\"OPENAI_API_KEY\":\"test-key\"}".utf8).write(to: codex.appendingPathComponent("auth.json"))
        let service = ConfigurationService(codexDirectory: codex, supportDirectory: root.appendingPathComponent("support"))
        let before = try service.load()
        try service.setRoots([
            .setString("model_instructions_file", instructions.path),
            .setInteger("model_context_window", 272_000),
            .setInteger("model_auto_compact_token_limit", 240_000)
        ], expected: before.snapshot)
        let enabled = try service.load()
        XCTAssertEqual(try enabled.config.modelSettings().instructionsFile, instructions.path)
        XCTAssertEqual(try enabled.config.modelSettings().contextWindow, 272_000)
        XCTAssertEqual(try enabled.config.modelSettings().autoCompactTokenLimit, 240_000)
        XCTAssertEqual(enabled.snapshot.auth, before.snapshot.auth)
        XCTAssertEqual(enabled.config.baseURL, before.config.baseURL)
        XCTAssertFalse(service.needsRecovery)
        XCTAssertThrowsError(try service.setRoots([.remove("model_context_window")], expected: before.snapshot))
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, before.snapshot)
        XCTAssertFalse(String(decoding: try Data(contentsOf: codex.appendingPathComponent("config.toml")), as: UTF8.self).contains("model_context_window"))
    }
}
