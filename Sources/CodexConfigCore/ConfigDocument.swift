import Foundation
import CTOMLPatch

public struct ConfigError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ConfigDocument {
    public let data: Data
    public let provider: String
    public let baseURL: String
    private let valueRange: Range<Int>

    public init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ConfigError("config.toml 不是有效的 UTF-8 文件。")
        }
        let result = data.withUnsafeBytes { bytes in
            cgl_inspect(bytes.bindMemory(to: CChar.self).baseAddress, data.count)
        }
        defer { cgl_free(result) }
        if let error = result.error { throw ConfigError(String(cString: error)) }
        guard let provider = result.provider, let base = result.base_url,
              result.start < result.end, result.end <= data.count else {
            throw ConfigError("无法唯一定位 base_url，未修改文件。")
        }
        self.data = data
        self.provider = String(cString: provider)
        self.baseURL = String(cString: base)
        valueRange = Int(result.start)..<Int(result.end)
    }

    public func replacingBaseURL(_ value: String) throws -> Data {
        try Self.validateURL(value)
        var result = data
        // Only the parsed value's exact byte range is replaced. Never serialize the document.
        result.replaceSubrange(valueRange, with: try encodedString(value))
        let verified = try ConfigDocument(data: result)
        guard verified.baseURL == value, verified.provider == provider else {
            throw ConfigError("修改后校验失败，未写入文件。")
        }
        return result
    }

    public var yoloEnabled: Bool {
        (try? permission("approval_policy").value) == "never" &&
        (try? permission("sandbox_mode").value) == "danger-full-access"
    }

    private func permission(_ key: String) throws -> (value: String?, range: Range<Int>) {
        let result = data.withUnsafeBytes { bytes in
            cgl_permission(bytes.bindMemory(to: CChar.self).baseAddress, data.count, key)
        }
        defer { cgl_free(result) }
        if let error = result.error { throw ConfigError(String(cString: error)) }
        return (result.base_url.map { String(cString: $0) }, Int(result.start)..<Int(result.end))
    }

    public func replacingYOLO(_ enabled: Bool) throws -> Data {
        let values = [("approval_policy", enabled ? "never" : "on-request"),
                      ("sandbox_mode", enabled ? "danger-full-access" : "workspace-write")]
        var edits: [(Range<Int>, Data)] = []
        var prefix = ""
        let newline = String(decoding: data, as: UTF8.self).contains("\r\n") ? "\r\n" : "\n"
        for (key, value) in values {
            let field = try permission(key)
            if field.value == value { continue }
            if field.value != nil { edits.append((field.range, try encodedString(value))) }
            else { prefix += "\(key) = \"\(value)\"\(newline)" }
        }
        var output = data
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            output.replaceSubrange(range, with: replacement)
        }
        let start = output.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        output.insert(contentsOf: prefix.utf8, at: start)
        let verified = try ConfigDocument(data: output)
        for (key, value) in values {
            guard try verified.permission(key).value == value else { throw ConfigError("权限配置校验失败。") }
        }
        return output
    }

    public static func validateURL(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.query == nil, parts.url != nil else {
            throw ConfigError("Base URL 必须是完整的 http(s) 地址，不能包含空白、账号密码、查询参数或片段。")
        }
    }
}

func encodedString(_ value: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
}

public struct AuthDocument {
    public let data: Data
    public let apiKey: String
    private let valueRange: Range<Int>

    public init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError("auth.json 不是合法的 JSON 对象。")
        }
        if let tokens = object["tokens"], !(tokens is NSNull) {
            throw ConfigError("auth.json 包含账号登录令牌，本版本不会覆盖或删除这些令牌。")
        }
        if let mode = object["auth_mode"], !(mode is NSNull), (mode as? String) != "apikey" {
            throw ConfigError("auth.json 当前不是 API Key 登录模式；不会更改登录模式。")
        }
        guard let key = object["OPENAI_API_KEY"] as? String else {
            throw ConfigError("auth.json 缺少字符串类型的 OPENAI_API_KEY；本版本只更新已有密钥字段。")
        }
        self.data = data
        apiKey = key
        valueRange = try Self.findKeyRange(data)
    }

    public func replacingAPIKey(_ value: String) throws -> Data {
        try Self.validateKey(value)
        var result = data
        result.replaceSubrange(valueRange, with: try encodedString(value))
        guard try AuthDocument(data: result).apiKey == value else {
            throw ConfigError("认证文件校验失败。")
        }
        return result
    }

    public static func validateKey(_ value: String) throws {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { throw ConfigError("API Key 不能为空，也不能包含空白或控制字符。") }
    }

    // JSON validity is checked above. Walk tokens to distinguish root keys from nested keys,
    // escaped names, or key-looking text inside a string; reject duplicate root fields.
    private static func findKeyRange(_ data: Data) throws -> Range<Int> {
        let b = Array(data)
        var i = 0, depth = 0
        var names = Set<String>()
        var result: Range<Int>?
        while i < b.count {
            if b[i] == 34 {
                let start = i
                i += 1
                while i < b.count {
                    if b[i] == 92 { i += 2; continue }
                    if b[i] == 34 { i += 1; break }
                    i += 1
                }
                var next = i
                while next < b.count && [9, 10, 13, 32].contains(b[next]) { next += 1 }
                if depth == 1, next < b.count, b[next] == 58 {
                    let name = try JSONSerialization.jsonObject(with: Data(b[start..<i]), options: [.fragmentsAllowed]) as! String
                    guard names.insert(name).inserted else { throw ConfigError("auth.json 存在重复字段，无法安全修改。") }
                    if name == "OPENAI_API_KEY" {
                        next += 1
                        while next < b.count && [9, 10, 13, 32].contains(b[next]) { next += 1 }
                        guard next < b.count, b[next] == 34 else { throw ConfigError("API Key 字段必须是字符串。") }
                        let valueStart = next
                        next += 1
                        while next < b.count {
                            if b[next] == 92 { next += 2; continue }
                            if b[next] == 34 { next += 1; break }
                            next += 1
                        }
                        result = valueStart..<next
                    }
                }
            } else {
                // Foundation tolerates trailing commas; auth.json is strict JSON.
                if b[i] == 44 {
                    var next = i + 1
                    while next < b.count && [9, 10, 13, 32].contains(b[next]) { next += 1 }
                    if next < b.count && (b[next] == 125 || b[next] == 93) {
                        throw ConfigError("auth.json 含有多余的尾逗号，不是严格 JSON。")
                    }
                }
                if b[i] == 123 || b[i] == 91 { depth += 1 }
                if b[i] == 125 || b[i] == 93 { depth -= 1 }
                i += 1
            }
        }
        guard let result else { throw ConfigError("无法定位 API Key 字段。") }
        return result
    }
}

public struct MCPServer: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let enabled: Bool
}

public struct RootChange: Codable, Equatable {
    public let key: String
    public let stringValue: String?
    public let integerValue: Int64?
    public let removed: Bool

    public static func setString(_ key: String, _ value: String) -> RootChange {
        RootChange(key: key, stringValue: value, integerValue: nil, removed: false)
    }

    public static func setInteger(_ key: String, _ value: Int64) -> RootChange {
        RootChange(key: key, stringValue: nil, integerValue: value, removed: false)
    }

    public static func remove(_ key: String) -> RootChange {
        RootChange(key: key, stringValue: nil, integerValue: nil, removed: true)
    }
}

public struct ModelSettings: Equatable {
    public var instructionsFile: String?
    public var contextWindow: Int64?
    public var autoCompactTokenLimit: Int64?
}

extension ConfigDocument {
    public func mcpServers() throws -> [MCPServer] {
        var servers: [MCPServer] = []
        while true {
            let result = data.withUnsafeBytes { cgl_mcp($0.bindMemory(to: CChar.self).baseAddress, data.count, servers.count) }
            defer { cgl_free(result) }
            if let error = result.error { throw ConfigError(String(cString: error)) }
            guard let name = result.provider else { return servers.sorted { $0.name < $1.name } }
            servers.append(MCPServer(name: String(cString: name), enabled: result.start != 0))
        }
    }

    public func replacingMCP(_ name: String, enabled: Bool) throws -> Data {
        guard let server = try mcpServers().first(where: { $0.name == name }) else {
            throw ConfigError("MCP 服务已不存在，请重新读取。")
        }
        if server.enabled == enabled { return data }
        let result = data.withUnsafeBytes {
            cgl_mcp_edit($0.bindMemory(to: CChar.self).baseAddress, data.count, name, enabled ? 1 : 0)
        }
        defer { cgl_free(result) }
        if let error = result.error { throw ConfigError(String(cString: error)) }
        guard let output = result.base_url else { throw ConfigError("MCP 修改失败。") }
        return Data(String(cString: output).utf8)
    }

    public func modelSettings() throws -> ModelSettings {
        ModelSettings(
            instructionsFile: try optionalRootString("model_instructions_file"),
            contextWindow: try optionalRootInteger("model_context_window"),
            autoCompactTokenLimit: try optionalRootInteger("model_auto_compact_token_limit")
        )
    }

    public func replacingRoots(_ edits: [RootChange]) throws -> Data {
        var output = data
        var inserts: [RootChange] = []
        for edit in edits {
            let current = try ConfigDocument(data: output)
            if try current.matches(edit) { continue }
            if !edit.removed, try current.isMissing(edit.key) {
                inserts.append(edit)
                continue
            }
            output = try current.applying(edit)
            guard try ConfigDocument(data: output).matches(edit) else {
                throw ConfigError("模型设置校验失败，未写入文件。")
            }
        }
        for edit in inserts.reversed() {
            output = try ConfigDocument(data: output).applying(edit)
            guard try ConfigDocument(data: output).matches(edit) else {
                throw ConfigError("模型设置校验失败，未写入文件。")
            }
        }
        let settings = try ConfigDocument(data: output).modelSettings()
        if let window = settings.contextWindow, let compact = settings.autoCompactTokenLimit {
            try Self.validateAutoCompact(compact, window: window)
        }
        return output
    }

    public static func validateInstructionsPath(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              value.hasPrefix("/") else {
            throw ConfigError("指令文件必须是绝对路径，不能包含空白或控制字符。")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &directory), !directory.boolValue else {
            throw ConfigError("指令文件不存在或不是普通文件。")
        }
        let url = URL(fileURLWithPath: value)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConfigError("指令文件必须是普通文件，不能是符号链接。")
        }
        if let size = values.fileSize, size > 1_000_000 {
            throw ConfigError("指令文件不能超过 1 MB。")
        }
    }

    public static func validateContextWindow(_ value: Int64) throws {
        guard (8_000...2_000_000).contains(value) else {
            throw ConfigError("上下文上限必须是 8000 到 2000000 之间的整数。")
        }
    }

    public static func validateAutoCompact(_ value: Int64, window: Int64?) throws {
        guard (1_000...2_000_000).contains(value) else {
            throw ConfigError("自动压缩阈值必须是 1000 到 2000000 之间的整数。")
        }
        if let window, value >= window {
            throw ConfigError("自动压缩阈值必须小于上下文上限。")
        }
    }

    public static func defaultInstructionsText() -> String {
        """
        # Codex 模型指令

        此文件会替换 Codex 内置的模型指令，不是项目里的 AGENTS.md。
        官方不建议轻易覆盖，除非你明确知道影响。

        请在下方编写指令内容。保存文件并重启 Codex 或相关会话后生效。

        """
    }

    private func optionalRootString(_ key: String) throws -> String? {
        switch try rootField(key) {
        case .missing: return nil
        case .string(let value): return value
        case .integer: throw ConfigError("\(key) 必须是字符串路径。")
        }
    }

    private func optionalRootInteger(_ key: String) throws -> Int64? {
        switch try rootField(key) {
        case .missing: return nil
        case .integer(let value): return value
        case .string: throw ConfigError("\(key) 必须是整数。")
        }
    }

    private enum RootField {
        case missing
        case string(String)
        case integer(Int64)
    }

    private func rootField(_ key: String) throws -> RootField {
        let result = data.withUnsafeBytes {
            cgl_root_get($0.bindMemory(to: CChar.self).baseAddress, data.count, key)
        }
        defer { cgl_free(result) }
        if let error = result.error { throw ConfigError(String(cString: error)) }
        guard let value = result.base_url else { return .missing }
        let text = String(cString: value)
        if result.start == 1 { return .string(text) }
        if result.start == 2, let number = Int64(text) { return .integer(number) }
        throw ConfigError("无法读取 \(key)。")
    }

    private func matches(_ edit: RootChange) throws -> Bool {
        let current = try rootField(edit.key)
        if edit.removed { return ifCaseMissing(current) }
        if let value = edit.stringValue {
            if case .string(let current) = current, current == value { return true }
            return false
        }
        if let value = edit.integerValue {
            if case .integer(let current) = current, current == value { return true }
            return false
        }
        throw ConfigError("模型设置不完整。")
    }

    private func isMissing(_ key: String) throws -> Bool {
        if case .missing = try rootField(key) { return true }
        return false
    }

    private func ifCaseMissing(_ field: RootField) -> Bool {
        if case .missing = field { return true }
        return false
    }

    private func applying(_ edit: RootChange) throws -> Data {
        if !edit.removed, let path = edit.stringValue { try Self.validateInstructionsPath(path) }
        if !edit.removed, let window = edit.integerValue, edit.key == "model_context_window" {
            try Self.validateContextWindow(window)
        }
        if !edit.removed, let compact = edit.integerValue, edit.key == "model_auto_compact_token_limit" {
            try Self.validateAutoCompact(compact, window: nil)
        }
        let encoded: String?
        if edit.removed {
            encoded = nil
        } else if let value = edit.stringValue {
            encoded = String(data: try encodedString(value), encoding: .utf8)
        } else if let value = edit.integerValue {
            encoded = String(value)
        } else {
            throw ConfigError("模型设置不完整。")
        }
        let result: CGLInspection = data.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: CChar.self).baseAddress
            return edit.key.withCString { key in
                if let encoded {
                    return encoded.withCString { cgl_root_set(base, data.count, key, $0) }
                }
                return cgl_root_set(base, data.count, key, nil)
            }
        }
        defer { cgl_free(result) }
        if let error = result.error { throw ConfigError(String(cString: error)) }
        guard let output = result.base_url else { throw ConfigError("模型设置修改失败。") }
        return Data(String(cString: output).utf8)
    }
}
