import SwiftUI
import CodexConfigCore

@MainActor
final class DetectionViewModel: ObservableObject, Identifiable {
    typealias Phase = DetectionPhase
    let id = UUID()
    let baseURL: String
    let profileName: String
    let isDemo: Bool
    private let apiKey: String
    private let client: MeowDetecting
    @Published var candidate: DetectionCandidate = .astra
    @Published var consent = false
    @Published var phase: Phase = .connecting
    @Published var bootstrap: DetectionBootstrap?
    @Published var report: DetectionReport?
    @Published var testedCandidate: DetectionCandidate?
    @Published var demoOutcome: DemonstrationOutcome = .match
    @Published var message = "正在读取网站的低档检测计划…"
    @Published var showConfirmation = false
    private var runID: String?
    private var work: Task<Void, Never>?

    var plan: DetectionPlan? { try? bootstrap?.plan(for: candidate) }
    var canStart: Bool { [.ready, .finished, .failed].contains(phase) && plan != nil && consent }
    var remoteMayBeActive: Bool { [.submitting, .running, .paused, .stopping, .uncertain].contains(phase) }
    var hasKnownActiveRun: Bool { runID != nil && [.running, .paused, .stopping].contains(phase) }
    var canDismiss: Bool { !remoteMayBeActive || phase == .uncertain }
    var isWorking: Bool { [.connecting, .submitting, .running, .stopping].contains(phase) }
    var scene: InvestigationScene { InvestigationScene(phase: phase, report: report) }
    var hasCompletedReport: Bool { report?.isTerminal == true }
    var reportCandidate: DetectionCandidate { testedCandidate ?? candidate }

    init(baseURL: String, apiKey: String, profileName: String, isDemo: Bool) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.profileName = profileName; self.isDemo = isDemo
        client = isDemo ? DemoDetectionClient() : MeowDetectionClient()
        if isDemo, let i = CommandLine.arguments.firstIndex(of: "--demo-outcome"),
           CommandLine.arguments.indices.contains(i + 1),
           let outcome = DemonstrationOutcome(rawValue: CommandLine.arguments[i + 1]) { demoOutcome = outcome }
    }

    func connect() {
        guard !remoteMayBeActive else { return }
        work?.cancel()
        phase = .connecting
        work = Task { [weak self] in
            guard let self else { return }
            do {
                self.bootstrap = try await self.client.prepare()
                _ = try self.bootstrap?.plan(for: self.candidate)
                self.phase = .ready
                self.message = self.isDemo ? "演示模式：模拟检测，不联网、不计费。" : "已连接 meowllm.top；尚未提交地址或 API Key。"
            } catch {
                self.phase = .failed
                self.message = self.describe(error)
            }
        }
    }

    func confirmStart() {
        guard canStart, let plan else { return }
        let input = DetectionInput(baseURL: baseURL, apiKey: apiKey, candidate: candidate, publicConsent: consent)
        do { try input.validate() }
        catch { message = describe(error); return }
        phase = .submitting
        consent = false
        report = nil
        testedCandidate = candidate
        runID = nil
        message = "正在提交低档检测；请勿重复提交…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if let demo = self.client as? DemoDetectionClient { await demo.setOutcome(self.demoOutcome) }
                self.runID = try await self.client.start(input, reviewedPlan: plan)
                self.phase = .running
                self.message = "网站正在检测；关闭本地程序不会自动停止服务器上的任务。"
                await self.poll()
            } catch DetectionError.submissionUncertain {
                self.phase = .uncertain
                self.message = DetectionError.submissionUncertain.localizedDescription
            } catch {
                self.phase = .failed
                self.message = self.describe(error)
            }
        }
    }

    func resumePolling() {
        guard phase == .paused, runID != nil else { return }
        work?.cancel()
        phase = .running
        message = "继续查询同一份报告，不重新提交检测。"
        work = Task { [weak self] in await self?.poll() }
    }

    func stop() {
        guard hasKnownActiveRun, phase != .stopping, let runID else { return }
        work?.cancel()
        phase = .stopping
        message = "正在请求网站停止；收到终态报告前不能确认已停止计费请求。"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.stop(id: runID)
                await self.poll()
            } catch {
                self.phase = .paused
                self.message = "未确认远端任务停止。" + self.describe(error)
            }
        }
    }

    private func poll() async {
        guard let runID else { return }
        let deadline = ContinuousClock().now.advanced(by: .seconds(16 * 60))
        var failures = 0
        while !Task.isCancelled {
            do {
                let report = try await client.report(id: runID)
                guard !Task.isCancelled else { return }
                self.report = report
                failures = 0
                if report.isTerminal {
                    phase = .finished
                    message = isDemo ? "这是模拟结果，不代表任何真实端点的模型身份。" : "检测结束。匹配度不是身份概率，仅供参考；Codex 配置未修改。"
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                message = describe(error)
                if failures >= 3 {
                    phase = .paused
                    message = "连续查询失败，远端任务可能仍在运行。可继续查询或尝试停止，不会重复提交。"
                    return
                }
            }
            if ContinuousClock().now >= deadline {
                phase = .paused
                message = "本地跟踪超时，但未确认远端停止。可继续查询或请求停止检测。"
                return
            }
            do { try await Task.sleep(for: isDemo ? .milliseconds(800) : .seconds(3)) }
            catch { return }
        }
    }

    func close() { work?.cancel(); work = nil }
    private func describe(_ error: Error) -> String {
        if let known = error as? DetectionError { return known.localizedDescription }
        if let known = error as? ConfigError { return known.message }
        return "检测连接失败，请检查网络；未显示可能含敏感信息的原始错误。"
    }
}

enum DemonstrationOutcome: String, CaseIterable, Identifiable {
    case match = "线索一致", mismatch = "发现差异", inconclusive = "证据不足", noEvidence = "没有有效回复"
    case failed = "检测失败", paused = "中途断线", uncertain = "提交结果未知"
    var id: String { rawValue }
}

// Deterministic, fake reports for native UI verification; this actor never creates a URLSession.
private actor DemoDetectionClient: MeowDetecting {
    private var candidate = DetectionCandidate.astra
    private var progress = 0
    private var stopped = false
    private var outcome: DemonstrationOutcome = .match
    private var failuresLeft = 3
    func setOutcome(_ value: DemonstrationOutcome) { outcome = value }
    func prepare() async throws -> DetectionBootstrap {
        try JSONDecoder().decode(DetectionBootstrap.self, from: Data("""
        {"csrf":"demo-only","public_site":true,"benchmarks":[{"id":"demo","version":"demo","mode":"gpt",
        "models":[{"id":"gpt-6-astra","name":"gpt-6-astra"},{"id":"gpt-5.6-sol","name":"gpt-5.6-sol"}],"tiers":{"low":20}}]}
        """.utf8))
    }
    func start(_ input: DetectionInput, reviewedPlan: DetectionPlan) async throws -> String {
        try input.validate()
        try await Task.sleep(for: .milliseconds(600))
        if outcome == .uncertain { throw DetectionError.submissionUncertain }
        candidate = input.candidate; progress = 0; stopped = false
        failuresLeft = 3
        return "demo-report"
    }
    func report(id: String) async throws -> DetectionReport {
        if outcome == .paused, progress >= 6, failuresLeft > 0, !stopped {
            failuresLeft -= 1
            throw DetectionError.message("模拟：网络暂时中断。")
        }
        if !stopped { progress = min(20, progress + 2) }
        let status = stopped ? "cancelled" : progress == 20 ? (outcome == .failed ? "error" : "complete") : "running"
        let strongest = outcome == .mismatch ? (candidate == .astra ? DetectionCandidate.sol : .astra) : candidate
        let scores: [String: Double] = [DetectionCandidate.astra.rawValue: strongest == .astra ? 0.94 : 0.03,
                                        DetectionCandidate.sol.rawValue: strongest == .sol ? 0.94 : 0.03,
                                        "other_known_external": 0.03]
        let object: [String: Any] = ["id": id, "status": status, "planned": 20, "completed": progress,
            "valid": outcome == .noEvidence ? 0 : progress, "attempts": progress, "retries_used": 0, "can_stop": status == "running",
            "fingerprint": ["color": outcome == .mismatch ? "red" : "green", "model": strongest.rawValue,
                "quality_status": outcome == .inconclusive ? "cell_samples_incomplete" : "sufficient",
                "partial": outcome == .inconclusive, "matches": scores, "thresholds": [candidate.rawValue: 0.87]]]
        return try JSONDecoder().decode(DetectionReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func stop(id: String) async throws { stopped = true }
}
