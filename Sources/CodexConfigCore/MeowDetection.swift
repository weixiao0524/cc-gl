import Foundation

public enum DetectionCandidate: String, CaseIterable, Identifiable, Sendable {
    case astra = "gpt-6-astra"
    case sol = "gpt-5.6-sol"
    public var id: String { rawValue }
}

public struct DetectionBootstrap: Decodable, Sendable {
    public struct Benchmark: Decodable, Sendable {
        public struct Model: Decodable, Sendable { public let id: String; public let name: String }
        public let id: String
        public let version: String
        public let mode: String
        public let models: [Model]
        public let tiers: [String: Int]
    }
    public let csrf: String
    public let benchmarks: [Benchmark]
    public let public_site: Bool

    public func plan(for candidate: DetectionCandidate) throws -> DetectionPlan {
        guard !csrf.isEmpty, public_site,
              let benchmark = benchmarks.first(where: { $0.mode == "gpt" }),
              benchmark.models.contains(where: { $0.id == candidate.rawValue }),
              let count = benchmark.tiers["low"], (1...120).contains(count) else {
            throw DetectionError.message("网站当前基准不支持所选模型或低档，未发起检测。")
        }
        return DetectionPlan(requests: count, retries: (count + 1) / 2)
    }
}

public struct DetectionPlan: Equatable, Sendable {
    public let requests: Int
    public let retries: Int
    public var maximum: Int { requests + retries }
}

public struct DetectionInput: Sendable {
    public let baseURL: String
    public let apiKey: String
    public let candidate: DetectionCandidate
    public let publicConsent: Bool

    public init(baseURL: String, apiKey: String, candidate: DetectionCandidate, publicConsent: Bool) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.candidate = candidate; self.publicConsent = publicConsent
    }

    public func validate() throws {
        try ConfigDocument.validateURL(baseURL)
        try AuthDocument.validateKey(apiKey)
        guard let parts = URLComponents(string: baseURL), parts.scheme?.lowercased() == "https",
              parts.port == nil || parts.port == 443 else {
            throw DetectionError.message("网站检测仅支持公网 HTTPS 地址和默认 443 端口。")
        }
        let host = (parts.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = octets.count == 4 && (octets[0] == 0 || octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 169 && octets[1] == 254) || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) || (octets[0] == 100 && (64...127).contains(octets[1])) || octets[0] >= 224)
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              host != "::", host != "::1",
              !(host.contains(":") && (["fc", "fd", "fe8", "fe9", "fea", "feb"].contains(where: host.hasPrefix))),
              !privateIPv4, baseURL.count <= 2048 else {
            throw DetectionError.message("网站无法检测本机或内网地址。公网可达性还会由检测网站验证。")
        }
        guard (8...4096).contains(apiKey.count), !baseURL.contains(apiKey),
              !candidate.rawValue.contains(apiKey) else {
            throw DetectionError.message("检测 Key 长度须为 8–4096，且不能出现在公开的地址或模型名称中。")
        }
        guard publicConsent else {
            throw DetectionError.message("请先确认向检测网站提交 Key、公开地址和结果，并承担 API 请求费用。")
        }
    }
}

public struct DetectionReport: Decodable, Sendable {
    public struct Fingerprint: Decodable, Sendable {
        public let color: String?
        public let model: String?
        public let matches: [String: Double]
        public let thresholds: [String: Double]?
        public let quality_status: String?
        public let partial: Bool?
        public let reasons: [String]?
    }
    public let id: String
    public let status: String
    public let planned: Int
    public let completed: Int
    public let valid: Int?
    public let attempts: Int?
    public let retries_used: Int?
    public let failure: String?
    public let quality_status: String?
    public let fingerprint: Fingerprint?
    public let errors: [String: Int]?
    public let can_stop: Bool?
    public var isTerminal: Bool { ["complete", "cancelled", "interrupted", "error"].contains(status) }
    public var verdictColor: String {
        guard status == "complete", (valid ?? 0) > 0, fingerprint?.partial != true,
              (quality_status ?? fingerprint?.quality_status) == "sufficient" else { return "yellow" }
        return ["green", "red"].contains(fingerprint?.color ?? "") ? fingerprint!.color! : "yellow"
    }
    public var verdict: String {
        switch status {
        case "running": return "检测中"
        case "cancelled": return "已停止检测"
        case "interrupted": return "检测已中断"
        case "error": return "检测失败"
        case "complete":
            if (valid ?? 0) == 0 { return "没有有效样本，无法判断" }
            if verdictColor == "green" { return "强指向申报模型" }
            if verdictColor == "red" { return "强指向其他候选模型" }
            return "证据不足，无法确认"
        default: return "网站返回未知状态"
        }
    }
}

public enum DetectionError: LocalizedError {
    case message(String)
    case submissionUncertain
    case server(String)
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .submissionUncertain: return "提交结果未知：网站可能已创建计费任务。为避免重复扣费，不会自动重试提交；可前往网站查询公开记录。"
        case .server(let code): return Self.explanation(code)
        }
    }
    public static func explanation(_ code: String) -> String {
        let name = code.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        // Never echo an arbitrary server response, URL, key or raw error body into the UI/logs.
        return [
            "page_expired": "检测会话已过期，请关闭检测面板后重新打开。",
            "public_report_required": "网站要求同意公开地址和检测结果。",
            "site_busy": "检测网站任务已满，请稍后重试。",
            "visitor_busy": "当前网络运行任务已达上限，请稍后重试。",
            "submit_rate_limited": "检测提交过于频繁，请稍后重试。",
            "request_rate_limited": "网站访问频率受限，稍后可继续获取结果。",
            "submit_too_fast": "网站要求稍等两秒后再提交。",
            "invalid_key": "网站拒绝了 Key 格式，请检查密钥。",
            "public_https_required": "网站仅接受公网 HTTPS 地址和默认 443 端口。",
            "invalid_detection_configuration": "网站不支持此检测模型或档位，请重新连接。",
            "report_not_found": "报告不存在或已超过网站保留期限。",
            "not_your_run": "网站无法确认本客户端拥有该任务，不能代为停止。",
            "run_not_active": "任务已结束，请重新获取结果。",
            "credential_echo": "上游回显凭据，网站已停止检测。",
            "credential_in_configuration": "公开配置中包含 Key，网站拒绝检测。",
            "samples_incomplete": "有效样本不足。",
            "no_threshold": "没有候选越过强指向线。",
            "multiple_thresholds": "多个候选同时越线，无法唯一判断。",
            "request_timeout": "上游请求超时。",
            "upstream_http_error": "上游接口返回 HTTP 错误。",
            "invalid_answer": "上游答案无法解析为有效样本。",
            "connection_error": "上游连接失败或不是公网可达地址。",
            "response_token_limit": "上游输出额度耗尽。",
            "user_stopped": "发起者停止了检测。",
            "server_restarted": "网站服务重启，任务已中断。",
            "run_timeout": "任务达到网站的时间限制。",
            "uncalibrated": "基准未通过校准检查。"
        ][name] ?? "检测服务返回异常，未显示原始响应以避免暴露凭据。"
    }
}

public protocol MeowDetecting: Sendable {
    func prepare() async throws -> DetectionBootstrap
    func start(_ input: DetectionInput, reviewedPlan: DetectionPlan) async throws -> String
    func report(id: String) async throws -> DetectionReport
    func stop(id: String) async throws
}

protocol DetectionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class MeowHTTPTransport: DetectionTransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else {
            throw DetectionError.message("检测网站响应无效或过大。")
        }
        return (data, http)
    }
}

public actor MeowDetectionClient: MeowDetecting {
    public static let website = URL(string: "https://meowllm.top/")!
    private let transport: DetectionTransport
    private var bootstrap: DetectionBootstrap?
    private var readyAt: ContinuousClock.Instant?
    private let minimumSessionAge: Duration

    public init() { transport = MeowHTTPTransport(); minimumSessionAge = .milliseconds(2100) }
    init(transport: DetectionTransport, minimumSessionAge: Duration = .zero) {
        self.transport = transport; self.minimumSessionAge = minimumSessionAge
    }

    public func prepare() async throws -> DetectionBootstrap {
        let data = try await request("api/bootstrap")
        guard let value = try? JSONDecoder().decode(DetectionBootstrap.self, from: data) else {
            throw DetectionError.message("检测网站接口结构发生变化，暂时无法连接。")
        }
        bootstrap = value
        readyAt = ContinuousClock().now.advanced(by: minimumSessionAge)
        return value
    }

    public func start(_ input: DetectionInput, reviewedPlan: DetectionPlan) async throws -> String {
        try input.validate()
        guard let bootstrap, let readyAt else { throw DetectionError.message("请先连接检测网站。") }
        guard try bootstrap.plan(for: input.candidate) == reviewedPlan else {
            throw DetectionError.message("网站请求预算发生变化，请重新确认后再检测。")
        }
        try await ContinuousClock().sleep(until: readyAt)
        try Task.checkCancellation()
        let body: [String: Any] = [
            "mode": "gpt", "claimed_model": input.candidate.rawValue, "request_model": input.candidate.rawValue,
            "base_url": input.baseURL, "site_group": "", "key": input.apiKey,
            "tier": "low", "workers": 3, "retry_budget": reviewedPlan.retries, "public_report": true
        ]
        let data = try await request("api/runs", body: JSONSerialization.data(withJSONObject: body), submission: true)
        struct Created: Decodable { let id: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data), Self.validID(created.id) else {
            throw DetectionError.submissionUncertain
        }
        return created.id
    }

    public func report(id: String) async throws -> DetectionReport {
        guard Self.validID(id) else { throw DetectionError.message("报告 ID 无效。") }
        let data = try await request("api/reports/\(id)")
        guard let report = try? JSONDecoder().decode(DetectionReport.self, from: data), report.id == id,
              report.planned > 0, report.completed >= 0, report.completed <= report.planned,
              ["running", "complete", "cancelled", "interrupted", "error"].contains(report.status) else {
            throw DetectionError.message("报告格式或状态异常；无法确认远端任务是否停止。")
        }
        return report
    }

    public func stop(id: String) async throws {
        guard Self.validID(id) else { throw DetectionError.message("报告 ID 无效。") }
        _ = try await request("api/runs/\(id)/stop", body: Data("{}".utf8))
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func request(_ path: String, body: Data? = nil, submission: Bool = false) async throws -> Data {
        var request = URLRequest(url: Self.website.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard let token = bootstrap?.csrf, !token.isEmpty else { throw DetectionError.message("检测会话未建立。") }
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "X-Meow-Token")
            request.setValue("https://meowllm.top", forHTTPHeaderField: "Origin")
            request.setValue(Self.website.absoluteString, forHTTPHeaderField: "Referer")
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch {
            if submission { throw DetectionError.submissionUncertain }
            if Task.isCancelled { throw CancellationError() }
            throw DetectionError.message("无法连接检测网站。网络恢复后可继续获取结果，不会重新提交计费任务。")
        }
        guard (200..<300).contains(response.statusCode) else {
            if submission && !(400..<500).contains(response.statusCode) { throw DetectionError.submissionUncertain }
            struct Envelope: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) { throw DetectionError.server(envelope.error.code) }
            throw DetectionError.message("检测网站返回 HTTP \(response.statusCode)，未显示原始内容。")
        }
        return data
    }
}
