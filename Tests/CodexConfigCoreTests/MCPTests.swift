import XCTest
@testable import CodexConfigCore

final class MCPTests: XCTestCase {
    private let provider = "model_provider='custom'\n[model_providers.custom]\nrequires_openai_auth=true\nbase_url='https://example.com/v1'\n"

    func testServiceSwitchPreservesOtherBytes() throws {
        let source = provider + "[mcp_servers.\"中文.test\"] # header\ncommand='node'\n# keep\n[mcp_servers.remote]\nurl='https://example.com/mcp'\nenabled = false # keep too\n"
        let doc = try ConfigDocument(data: Data(source.utf8))
        XCTAssertEqual(try doc.mcpServers().count, 2)
        let disabled = try doc.replacingMCP("中文.test", enabled: false)
        XCTAssertEqual(String(decoding: disabled, as: UTF8.self), source.replacingOccurrences(of: "# header\n", with: "# header\nenabled = false\n"))
        let on = try ConfigDocument(data: disabled).replacingMCP("remote", enabled: true)
        XCTAssertTrue(String(decoding: on, as: UTF8.self).contains("enabled = true # keep too"))
        XCTAssertEqual(try ConfigDocument(data: on).replacingMCP("remote", enabled: true), on)
        XCTAssertThrowsError(try doc.replacingMCP("missing", enabled: false))
    }

    func testInlineAndCRLF() throws {
        for mcp in ["mcp_servers = { test = { command = 'node' } }\n", "[mcp_servers.test]\ncommand='node'\n"] {
            let input = mcp.hasPrefix("[") ? provider + mcp : mcp + provider
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(input.replacingOccurrences(of: "\n", with: "\r\n").utf8)
            let output = try ConfigDocument(data: data).replacingMCP("test", enabled: false)
            XCTAssertTrue(output.starts(with: [0xEF, 0xBB, 0xBF]))
            XCTAssertFalse(try XCTUnwrap(ConfigDocument(data: output).mcpServers().first).enabled)
        }
    }

    func testBackupRestoreAndStaleSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((provider + "[mcp_servers.test]\ncommand='node'\n").utf8).write(to: root.appendingPathComponent("config.toml"))
        try Data("{\"OPENAI_API_KEY\":\"test-key\"}".utf8).write(to: root.appendingPathComponent("auth.json"))
        let service = ConfigurationService(codexDirectory: root, supportDirectory: root.appendingPathComponent("support"))
        let before = try service.load()
        try service.setMCP("test", enabled: false, expected: before.snapshot)
        XCTAssertFalse(service.needsRecovery)
        XCTAssertEqual(try service.load().snapshot.auth, before.snapshot.auth)
        XCTAssertThrowsError(try service.setMCP("test", enabled: true, expected: before.snapshot))
        try service.restore()
        XCTAssertEqual(try service.load().snapshot, before.snapshot)
    }
}
