import Foundation

/// Wire formats tried, in order, against the user's own endpoint.
public enum ModelTraceAPIFormat: String, CaseIterable, Sendable {
    case chatCompletions = "OpenAI Chat Completions"
    case responses = "OpenAI Responses"
    case anthropicMessages = "Anthropic Messages"

    var path: String {
        switch self {
        case .chatCompletions: return "chat/completions"
        case .responses: return "responses"
        case .anthropicMessages: return "messages"
        }
    }
}

/// What the local ModelTrace mode needs; the key is only ever sent to `baseURL`.
public struct ModelTraceInput: Sendable {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }

    public func validate() throws {
        try ConfigDocument.validateURL(baseURL)
        try AuthDocument.validateKey(apiKey)
        guard !model.isEmpty, model.utf8.count <= 200, model == model.trimmingCharacters(in: .whitespaces),
              !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DetectionError.message("请求模型名不能为空、过长或包含控制字符。")
        }
        guard !model.contains(apiKey), !baseURL.contains(apiKey) else {
            throw DetectionError.message("模型名或接口地址中不能包含 API Key。")
        }
    }

    /// Codex-style base URLs already end in a version segment (`…/v1`), so the route is appended
    /// directly; a bare host gets `/v1` first, as in ModelTrace `enrollment.py`.
    func endpoint(_ format: ModelTraceAPIFormat) -> URL? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let path = URLComponents(string: base)?.path ?? ""
        let prefix = path.isEmpty ? "/v1/" : "/"
        return URL(string: base + prefix + format.path)
    }
}

public struct ModelTraceProgress: Sendable, Equatable {
    public let planned: Int
    public let completed: Int
    public let valid: Int
    public let attempts: Int
    public init(planned: Int, completed: Int, valid: Int, attempts: Int) {
        self.planned = planned; self.completed = completed; self.valid = valid; self.attempts = attempts
    }
}

public struct ModelTraceCollection: Sendable {
    /// One entry per challenge, in order; failed challenges carry empty text so diagnostics stay aligned.
    public let outputs: [ModelTraceOutput]
    public let format: ModelTraceAPIFormat?
    public let attempts: Int
    public let failures: [String: Int]
    public init(outputs: [ModelTraceOutput], format: ModelTraceAPIFormat?, attempts: Int, failures: [String: Int]) {
        self.outputs = outputs; self.format = format; self.attempts = attempts; self.failures = failures
    }
}

public protocol ModelTraceRequesting: Sendable {
    func collect(_ challenges: [ModelTraceChallenge], input: ModelTraceInput,
                 progress: @escaping @Sendable (ModelTraceProgress) async -> Void) async throws -> ModelTraceCollection
}

/// Sends ModelTrace challenges straight to the configured endpoint. Each challenge gets at most one
/// retry, so a run costs at most `2 × challenges` billable requests plus format probes the endpoint rejects.
public final class ModelTraceClient: ModelTraceRequesting, @unchecked Sendable {
    public static let maxOutputTokens = 4096
    public static let retriesPerChallenge = 1
    private let transport: DetectionTransport

    public init() { transport = ModelTraceHTTPTransport() }
    init(transport: DetectionTransport) { self.transport = transport }

    enum Attempt: Equatable {
        case text(String)
        /// The route or body shape is not this format; try the next one (only while detecting).
        case formatMismatch
        case failure(String)
    }

    public func collect(_ challenges: [ModelTraceChallenge], input: ModelTraceInput,
                        progress: @escaping @Sendable (ModelTraceProgress) async -> Void) async throws -> ModelTraceCollection {
        try input.validate()
        guard !challenges.isEmpty else { throw DetectionError.message("没有可发送的挑战。") }
        var texts = [String](repeating: "", count: challenges.count)
        var done = [Bool](repeating: false, count: challenges.count)
        var valid = [Bool](repeating: false, count: challenges.count)
        var attemptsLeft = [Int](repeating: 1 + Self.retriesPerChallenge, count: challenges.count)
        var attempts = 0
        var failures: [String: Int] = [:]
        func report() async {
            await progress(ModelTraceProgress(planned: challenges.count, completed: done.filter { $0 }.count,
                                              valid: valid.filter { $0 }.count, attempts: attempts))
        }
        func record(_ index: Int, _ result: Attempt) {
            attemptsLeft[index] -= 1
            switch result {
            case .text(let text):
                texts[index] = text
                if Self.isUsable(text, expected: challenges[index].expectedCount) { valid[index] = true; done[index] = true }
                else { failures["invalid_answer", default: 0] += 1 }
            case .failure(let code): failures[code, default: 0] += 1
            case .formatMismatch: failures["format_mismatch", default: 0] += 1
            }
            if attemptsLeft[index] == 0 { done[index] = true }
        }

        // Detect the format with the first challenge; a probe the endpoint rejects as unknown is not billed.
        var format: ModelTraceAPIFormat?
        await report()
        for candidate in ModelTraceAPIFormat.allCases {
            try Task.checkCancellation()
            attempts += 1
            let result = await attempt(challenges[0], format: candidate, input: input)
            if result == .formatMismatch { failures["format_mismatch", default: 0] += 1; continue }
            if result == .failure("auth") { throw DetectionError.message(Self.explanation("auth")) }
            format = candidate
            record(0, result)
            break
        }
        try Task.checkCancellation()
        guard let format else {
            throw DetectionError.message("接口不接受 Chat Completions、Responses 或 Messages 任一格式，或拒绝了该模型名（HTTP 4xx）。")
        }
        await report()

        // Remaining challenges (and a retry of the first, if needed) run concurrently, one round per retry.
        while true {
            let pending = challenges.indices.filter { !done[$0] && attemptsLeft[$0] > 0 }
            if pending.isEmpty { break }
            try await withThrowingTaskGroup(of: (Int, Attempt).self) { group in
                for index in pending {
                    group.addTask { (index, await self.attempt(challenges[index], format: format, input: input)) }
                }
                for try await (index, result) in group {
                    attempts += 1
                    if result == .failure("auth") {
                        group.cancelAll()
                        throw DetectionError.message(Self.explanation("auth"))
                    }
                    record(index, result == .formatMismatch ? .failure("http_error") : result)
                    await report()
                }
            }
            try Task.checkCancellation()
        }
        return ModelTraceCollection(
            outputs: challenges.indices.map { ModelTraceOutput(text: texts[$0], expectedCount: challenges[$0].expectedCount) },
            format: format, attempts: attempts, failures: failures)
    }

    /// Same acceptance rule the attribution applies, so retries are spent only on answers it would drop.
    public static func isUsable(_ text: String, expected: Int) -> Bool {
        ModelTraceFingerprint.parseNumbers(text).count >= ModelTraceFingerprint.minimumNumbers(expected: expected)
    }

    func attempt(_ challenge: ModelTraceChallenge, format: ModelTraceAPIFormat, input: ModelTraceInput) async -> Attempt {
        guard let url = input.endpoint(format) else { return .failure("http_error") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let message: [String: Any] = ["role": "user", "content": challenge.prompt]
        let body: [String: Any]
        switch format {
        case .chatCompletions:
            request.setValue("Bearer \(input.apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": input.model, "messages": [message], "max_tokens": Self.maxOutputTokens, "stream": false]
        case .responses:
            request.setValue("Bearer \(input.apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": input.model, "input": [message], "max_output_tokens": Self.maxOutputTokens, "stream": false]
        case .anthropicMessages:
            request.setValue(input.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": input.model, "messages": [message], "max_tokens": Self.maxOutputTokens]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch {
            if (error as? URLError)?.code == .timedOut { return .failure("timeout") }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .failure("cancelled") }
            return .failure("connection")
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: return .failure("auth")
        case 400, 404, 405, 415, 422: return .formatMismatch
        case 429: return .failure("rate_limited")
        case 500...599: return .failure("server_error")
        default: return .failure("http_error")
        }
        // Raw bodies are never surfaced: they can echo keys or untrusted content.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .formatMismatch }
        if object["error"] != nil { return .failure("http_error") }
        guard let (text, truncated) = Self.extract(object, format: format) else { return .formatMismatch }
        if truncated { return .failure("truncated") }
        if text.contains(input.apiKey) { return .failure("credential_echo") }
        return .text(text)
    }

    /// Answer text and whether it hit the output limit, or nil when the body is not this format.
    static func extract(_ object: [String: Any], format: ModelTraceAPIFormat) -> (String, Bool)? {
        func joined(_ parts: Any?, types: Set<String>) -> String? {
            if let string = parts as? String { return string }
            guard let array = parts as? [[String: Any]] else { return nil }
            return array.compactMap { part in
                guard types.contains(part["type"] as? String ?? "") else { return nil }
                return part["text"] as? String
            }.joined()
        }
        switch format {
        case .chatCompletions:
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { return nil }
            let text = joined(message["content"], types: ["text", "output_text"]) ?? ""
            return (text, choice["finish_reason"] as? String == "length")
        case .responses:
            guard let output = object["output"] as? [[String: Any]] else { return nil }
            let text = output.filter { $0["type"] as? String == "message" }
                .compactMap { joined($0["content"], types: ["output_text", "text"]) }.joined()
            let truncated = object["status"] as? String == "incomplete"
            return (text, truncated)
        case .anthropicMessages:
            guard object["content"] is [[String: Any]] || object["type"] as? String == "message" else { return nil }
            return (joined(object["content"], types: ["text"]) ?? "", object["stop_reason"] as? String == "max_tokens")
        }
    }

    /// Fixed explanations for failure codes; nothing from the response is ever echoed.
    public static func explanation(_ code: String) -> String {
        [
            "auth": "接口拒绝了 API Key（HTTP 401/403），已停止，不再继续请求。",
            "rate_limited": "接口限流（HTTP 429）。",
            "server_error": "接口服务器错误（HTTP 5xx）。",
            "http_error": "接口返回了错误响应。",
            "timeout": "请求超时。",
            "connection": "无法连接接口。",
            "cancelled": "请求已取消。",
            "truncated": "回答被输出上限截断，不计入。",
            "credential_echo": "回答里出现了 API Key，已丢弃。",
            "invalid_answer": "回答中的数字不足（可能拒答、改写任务或调用了工具）。",
            "format_mismatch": "接口不支持某种请求格式，已自动换用下一种。"
        ][code] ?? "未知错误。"
    }
}

final class ModelTraceHTTPTransport: DetectionTransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Long answers (300+ integers) from slow models can take minutes; mirrors ModelTrace's 240 s.
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
