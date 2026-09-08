import XCTest
@testable import CodexConfigCore

final class DocumentTests: XCTestCase {
    private let prefix = "model_provider = \"custom\"\n[model_providers.custom]\nrequires_openai_auth = true\n"

    func testOnlyTargetValueChanges() throws {
        let original = """
        # Leave everything alone
        model_provider = "custom"
        model = "keep-model"
        [model_providers.other]
        base_url = "https://other.example/v1"
        [model_providers.custom]
        requires_openai_auth = true
        base_url  = 'https://old.example/v1' # trailing comment
        wire_api = "responses"
        [mcp_servers.test]
        command = "keep-command"

        """
        let result = try ConfigDocument(data: Data(original.utf8)).replacingBaseURL("https://new.example/v1")
        XCTAssertEqual(String(decoding: result, as: UTF8.self),
                       original.replacingOccurrences(of: "'https://old.example/v1'", with: "\"https://new.example/v1\""))
    }

    func testQuotedProviderInlineTableUnicodeAndCRLF() throws {
        let original = "# 中文注释\r\nmodel_provider = '自定义.proxy'\r\n[model_providers]\r\n'自定义.proxy' = { name = '保留', requires_openai_auth = true, base_url = 'https://old.example' }\r\n"
        let result = try ConfigDocument(data: Data(original.utf8)).replacingBaseURL("https://new.example/v1")
        XCTAssertEqual(String(decoding: result, as: UTF8.self),
                       original.replacingOccurrences(of: "'https://old.example'", with: "\"https://new.example/v1\""))
    }

    func testMultilineDecoysAreNotEdited() throws {
        let original = """
        model_provider = "custom"
        instructions = '''
        [model_providers.custom]
        base_url = "do not replace"
        '''
        [model_providers.custom]
        requires_openai_auth = true
        base_url = 
        """ + "\"\"\"https://old.example\"\"\"\n"
        let result = try ConfigDocument(data: Data(original.utf8)).replacingBaseURL("https://new.example")
        XCTAssertEqual(String(decoding: result, as: UTF8.self),
                       original.replacingOccurrences(of: "\"\"\"https://old.example\"\"\"", with: "\"https://new.example\""))
    }

    func testUTF8BOMPreserved() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data((prefix + "base_url = 'https://old.example'\n").utf8)
        let result = try ConfigDocument(data: original).replacingBaseURL("https://new.example")
        XCTAssertEqual(result.prefix(3), Data([0xEF, 0xBB, 0xBF]))
        XCTAssertEqual(try ConfigDocument(data: result).baseURL, "https://new.example")
    }

    func testRejectUnsupportedAndMalformedConfigurations() {
        let samples = [
            "model_provider = 'custom'\nmodel_provider = 'other'",
            "model_provider = 'custom'\n[model_providers.custom]\nbase_url='https://a.example'",
            "cli_auth_credentials_store = 'keyring'\n" + prefix + "base_url='https://a.example'",
            "cli_auth_credentials_store = 'auto'\n" + prefix + "base_url='https://a.example'",
            "profile = 'work'\n" + prefix + "base_url='https://a.example'",
            "forced_login_method = 'chatgpt'\n" + prefix + "base_url='https://a.example'",
            prefix + "base_url = 42",
            prefix + "base_url = 'https://a.example'\nauth = { command = 'custom' }",
            "openai_base_url = 'https://a.example'"
        ]
        for source in samples { XCTAssertThrowsError(try ConfigDocument(data: Data(source.utf8)), source) }
    }

    func testURLValidationDoesNotRewritePath() throws {
        for url in ["https://api.example/v1", "http://localhost:8080/custom/", "http://[::1]:9000/v1"] {
            try ConfigDocument.validateURL(url)
        }
        for url in ["", "ftp://example.com", "https://user:key@example.com/v1", "https://example.com?key=secret", "https://example.com/#x", "https://example.com\n", "not a URL"] {
            XCTAssertThrowsError(try ConfigDocument.validateURL(url), url)
        }
    }

    func testAuthPreservesEveryOtherByteAndEscapes() throws {
        let original = #"{ "nested": {"OPENAI_API_KEY":"keep"}, "OPENAI_API_KEY" : "old", "note": "中文", "tokens":null }"# + "\r\n"
        let result = try AuthDocument(data: Data(original.utf8)).replacingAPIKey(#"new-"quoted\key"#)
        XCTAssertEqual(String(decoding: result, as: UTF8.self),
                       original.replacingOccurrences(of: "\"old\"", with: #""new-\"quoted\\key""#))
        XCTAssertEqual(try AuthDocument(data: result).apiKey, #"new-"quoted\key"#)
    }

    func testEscapedRootJSONKeyAndNestedArray() throws {
        let original = #"{"x":[{"OPENAI_API_KEY":"untouched"}],"OPENAI_API_\u004bEY":"old","auth_mode":"apikey"}"#
        let result = try AuthDocument(data: Data(original.utf8)).replacingAPIKey("new")
        XCTAssertEqual(String(decoding: result, as: UTF8.self), original.replacingOccurrences(of: "\"old\"", with: "\"new\""))
    }

    func testRejectInvalidAmbiguousAndAccountAuth() {
        for source in [
            #"{"OPENAI_API_KEY":"a", "OPENAI_API_KEY":"b"}"#,
            #"{"OPENAI_API_KEY":"a", "OPENAI_API_\u004bEY":"b"}"#,
            #"{"OPENAI_API_KEY":"a", "tokens":{"access_token":"keep"}}"#,
            #"{"OPENAI_API_KEY":"a", "auth_mode":"chatgpt"}"#,
            #"{"OPENAI_API_KEY":null}"#,
            #"{"nested":{"OPENAI_API_KEY":"a"}}"#,
            #"{"OPENAI_API_KEY":"a", "bad":true, "bad":false}"#,
            #"{"OPENAI_API_KEY":"a",}"#,
            "[]"
        ] {
            XCTAssertThrowsError(try AuthDocument(data: Data(source.utf8)), source)
        }
    }

    func testKeyValidation() {
        for key in ["", " leading", "trailing\n", "contains space", "contains\tTab"] {
            XCTAssertThrowsError(try AuthDocument.validateKey(key))
        }
    }
}
