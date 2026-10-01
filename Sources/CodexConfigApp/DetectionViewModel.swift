import SwiftUI
import os
import CodexConfigCore

private let detectionLog = Logger(subsystem: "CodexConfig", category: "detection")

/// How the endpoint is checked: meowllm.top runs a remote job with the key, or the app sends
/// ModelTrace number challenges to the endpoint itself and attributes the answers locally.
enum DetectionMode: String, CaseIterable, Identifiable {
    case website = "网站检测（meowllm）"
    case local = "本地指纹（ModelTrace）"
    var id: String { rawValue }
}

@MainActor
final class DetectionViewModel: ObservableObject, Identifiable {
    typealias Phase = DetectionPhase
    /// Picker entry that reveals a free-form model name field in local mode.
    static let customCandidate = DetectionCandidate("custom", name: "自定义模型名…")
    static let localChallengeCount = 3

    let id = UUID()
    let baseURL: String
    let profileName: String
    let isDemo: Bool
    private let apiKey: String
    private let client: MeowDetecting
    private let bankLoader: ModelTraceBankLoader
    private let traceRequester: ModelTraceRequesting
    @Published var mode: DetectionMode = .website {
        didSet { if mode != oldValue { modeChanged() } }
    }
    // nil until the model list has been synced from the site's bootstrap (or the bank has loaded).
    @Published var candidate: DetectionCandidate?
    @Published var consent = false
    @Published var phase: Phase = .connecting
    @Published var bootstrap: DetectionBootstrap?
    @Published var report: DetectionReport?
    @Published var testedCandidate: DetectionCandidate?
    @Published var demoOutcome: DemonstrationOutcome = .match
    @Published var message = "正在读取网站的低档检测计划…"
    @Published var showConfirmation = false
    // Local ModelTrace state.
    @Published var bank: ModelTraceBank?
    @Published var bankSource: ModelTraceBankSource?
    @Published var customModel = ""
    @Published var localProgress: ModelTraceProgress?
    @Published var localCollection: ModelTraceCollection?
    @Published var localResult: ModelTraceResult?
    @Published var localStopped = false
    /// Bank id the finished local run was compared against; nil for a custom name outside the bank.
    @Published var localClaimed: String?
    private var runID: String?
    private var work: Task<Void, Never>?
    private var refreshWork: Task<Void, Never>?

    var isLocal: Bool { mode == .local }
    /// Picker options: the live site list, or the reference bank plus a custom entry.
    var candidates: [DetectionCandidate] {
        if isLocal {
            guard let bank else { return [] }
            return bank.models.map { DetectionCandidate($0.id, name: $0.display_name) } + [Self.customCandidate]
        }
        return bootstrap?.candidates ?? []
    }
    var plan: DetectionPlan? { isLocal ? nil : candidate.flatMap { try? bootstrap?.plan(for: $0) } }
    var isCustomModel: Bool { isLocal && candidate == Self.customCandidate }
    /// The `model` sent to the endpoint in local mode.
    var requestModel: String {
        isCustomModel ? customModel.trimmingCharacters(in: .whitespaces) : candidate?.rawValue ?? ""
    }
    /// Bank model a request name refers to: an exact id, ignoring case and a `provider/` prefix.
    var claimedBankModel: String? {
        let name = requestModel.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return bank?.models.first { $0.id.lowercased() == name }?.id
    }
    var canStart: Bool {
        guard [.ready, .finished, .failed].contains(phase), consent else { return false }
        return isLocal ? bank != nil && !requestModel.isEmpty : plan != nil
    }
    /// Local runs live in this process only; cancelling them needs no remote confirmation.
    var remoteMayBeActive: Bool { !isLocal && [.submitting, .running, .paused, .stopping, .uncertain].contains(phase) }
    var hasKnownActiveRun: Bool {
        isLocal ? [.submitting, .running].contains(phase) : runID != nil && [.running, .paused, .stopping].contains(phase)
    }
    var canDismiss: Bool { !remoteMayBeActive || phase == .uncertain }
    var isWorking: Bool { [.connecting, .submitting, .running, .stopping].contains(phase) }
    var localProgressFraction: Double {
        guard let progress = localProgress, progress.planned > 0 else { return 0 }
        return Double(progress.completed) / Double(progress.planned)
    }
    var scene: InvestigationScene {
        isLocal ? InvestigationScene(phase: phase, localResult: localResult, claimed: localClaimed,
                                     progress: localProgressFraction, stopped: localStopped)
            : InvestigationScene(phase: phase, report: report)
    }
    var hasCompletedReport: Bool { isLocal ? phase == .finished : report?.isTerminal == true }
    var reportCandidate: DetectionCandidate? { testedCandidate ?? candidate }

    init(baseURL: String, apiKey: String, profileName: String, isDemo: Bool, cacheDirectory: URL? = nil) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.profileName = profileName; self.isDemo = isDemo
        client = isDemo ? DemoDetectionClient() : MeowDetectionClient()
        bankLoader = ModelTraceBankLoader(cacheDirectory: isDemo ? nil : cacheDirectory)
        traceRequester = isDemo ? DemoModelTraceRequester() : ModelTraceClient()
        if isDemo, let i = CommandLine.arguments.firstIndex(of: "--demo-outcome"),
           CommandLine.arguments.indices.contains(i + 1),
           let outcome = DemonstrationOutcome(rawValue: CommandLine.arguments[i + 1]) { demoOutcome = outcome }
        if isDemo, CommandLine.arguments.contains("--demo-local") { mode = .local }
    }

    private func modeChanged() {
        work?.cancel(); work = nil
        refreshWork?.cancel(); refreshWork = nil
        candidate = nil; consent = false; report = nil; testedCandidate = nil; runID = nil
        localResult = nil; localCollection = nil; localProgress = nil; localStopped = false; localClaimed = nil
        connect()
    }

    func connect() {
        guard !remoteMayBeActive else { return }
        work?.cancel()
        phase = .connecting
        if isLocal { connectLocal(); return }
        message = "正在读取网站的低档检测计划…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let bootstrap = try await self.client.prepare()
                guard !Task.isCancelled else { return }
                self.bootstrap = bootstrap
                let synced = bootstrap.candidates
                detectionLog.info("Synced detection models: \(synced.map(\.rawValue).joined(separator: ","), privacy: .public)")
                // Keep the user's choice if the site still offers it (re-bound to the synced entry so
                // the Picker tag matches); otherwise fall back to the first remote model so a retired
                // id (e.g. gpt-5.6-sol) is never submitted.
                let previous = self.candidate
                self.candidate = synced.first { $0.rawValue == previous?.rawValue } ?? synced.first
                if let previous, self.candidate?.rawValue != previous.rawValue {
                    detectionLog.notice("Selected model \(previous.rawValue, privacy: .public) no longer offered; reset")
                }
                guard let candidate = self.candidate else {
                    // Clear bootstrap so the "重新连接" action is offered.
                    self.bootstrap = nil
                    throw DetectionError.message("网站当前没有可检测的 GPT 模型，暂时无法检测。")
                }
                _ = try bootstrap.plan(for: candidate)
                self.phase = .ready
                self.message = self.isDemo ? "演示模式：模拟检测，不联网、不计费。" : "已连接 meowllm.top；尚未提交地址或 API Key。"
            } catch {
                guard !Task.isCancelled else { return }
                detectionLog.error("Detection bootstrap failed")
                self.phase = .failed
                self.message = self.describe(error)
            }
        }
    }

    private func connectLocal() {
        message = "正在载入 ModelTrace 指纹库…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let (bank, source) = try await self.bankLoader.load()
                guard !Task.isCancelled else { return }
                self.adopt(bank, source: source)
                self.phase = .ready
                self.message = self.isDemo ? "演示模式：用参考样本模拟回答，不联网、不计费。" : "指纹库已就绪；Key 只会发送到当前接口地址。"
                // The demo never touches the network; otherwise look for a newer upstream bank quietly.
                guard !self.isDemo else { return }
                self.refreshWork?.cancel()
                self.refreshWork = Task { [weak self] in
                    guard let loader = self?.bankLoader,
                          let newer = await loader.refresh(newerThan: bank), !Task.isCancelled,
                          let self, self.isLocal else { return }
                    detectionLog.info("ModelTrace bank updated to \(newer.built_at ?? "?", privacy: .public)")
                    self.adopt(newer, source: .remote)
                }
            } catch {
                guard !Task.isCancelled else { return }
                detectionLog.error("ModelTrace bank failed to load")
                self.phase = .failed
                self.message = self.describe(error)
            }
        }
    }

    /// Swaps in a bank, keeping the picker selection when the new bank still has it.
    private func adopt(_ bank: ModelTraceBank, source: ModelTraceBankSource) {
        self.bank = bank
        bankSource = source
        let previous = candidate
        candidate = candidates.first { $0.rawValue == previous?.rawValue } ?? candidates.first
    }

    func confirmStart() {
        if isLocal { startLocal(); return }
        guard canStart, let plan, let candidate else { return }
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

    private func startLocal() {
        guard canStart, let bank else { return }
        let model = requestModel
        let input = ModelTraceInput(baseURL: baseURL, apiKey: apiKey, model: model)
        do { try input.validate() }
        catch { message = describe(error); return }
        refreshWork?.cancel()
        phase = .running
        consent = false
        localResult = nil; localCollection = nil; localStopped = false
        localClaimed = claimedBankModel
        testedCandidate = DetectionCandidate(model, name: model)
        let challenges = ModelTraceChallenge.generate(count: Self.localChallengeCount)
        localProgress = ModelTraceProgress(planned: challenges.count, completed: 0, valid: 0, attempts: 0)
        message = "正在直接向接口发送 \(challenges.count) 道数字题，长回答可能需要几分钟…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if let demo = self.traceRequester as? DemoModelTraceRequester {
                    await demo.configure(outcome: self.demoOutcome, bank: bank, claimed: self.localClaimed)
                }
                let collection = try await self.traceRequester.collect(challenges, input: input) { [weak self] progress in
                    await self?.updateProgress(progress)
                }
                try Task.checkCancellation()
                self.localCollection = collection
                // No usable answer is a finished run without evidence, not a failure of the endpoint.
                self.localResult = try? ModelTraceFingerprint.analyze(collection.outputs, bank: bank)
                self.phase = .finished
                self.message = self.isDemo ? "这是模拟结果，不代表任何真实端点的模型身份。"
                    : "检测结束。概率只在候选库内归因，仅供参考；Codex 配置未修改。"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self.localStopped = true
                    self.phase = .finished
                    self.message = "已停止。已经发出的请求仍可能计费。"
                } else {
                    self.phase = .failed
                    self.message = self.describe(error)
                }
            }
        }
    }

    private func updateProgress(_ progress: ModelTraceProgress) {
        guard isLocal, phase == .running else { return }
        localProgress = progress
    }

    func resumePolling() {
        guard !isLocal, phase == .paused, runID != nil else { return }
        work?.cancel()
        phase = .running
        message = "继续查询同一份报告，不重新提交检测。"
        work = Task { [weak self] in await self?.poll() }
    }

    func stop() {
        if isLocal {
            guard hasKnownActiveRun else { return }
            message = "正在取消本地请求…"
            work?.cancel()
            return
        }
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

    func close() { work?.cancel(); work = nil; refreshWork?.cancel(); refreshWork = nil }
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
    private var candidate: DetectionCandidate?
    private var candidates: [DetectionCandidate] = []
    private var progress = 0
    private var stopped = false
    private var outcome: DemonstrationOutcome = .match
    private var failuresLeft = 3
    func setOutcome(_ value: DemonstrationOutcome) { outcome = value }
    // Mirrors the live bootstrap shape, including the reference-only "other" bucket.
    func prepare() async throws -> DetectionBootstrap {
        let bootstrap = try JSONDecoder().decode(DetectionBootstrap.self, from: Data("""
        {"csrf":"demo-only","public_site":true,"benchmarks":[{"id":"demo","version":"demo","mode":"gpt",
        "models":[{"id":"gpt-6-astra","name":"gpt-6-astra","reference_only":false},
        {"id":"gpt-6-sol","name":"gpt-6-sol","reference_only":false},
        {"id":"gpt-5.6-terra","name":"gpt-5.6-terra","reference_only":false},
        {"id":"gpt-6-luna","name":"gpt-6-luna","reference_only":false},
        {"id":"other_known_external","name":"other","reference_only":true}],"tiers":{"low":20}}]}
        """.utf8))
        candidates = bootstrap.candidates
        return bootstrap
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
        let claimed = candidate?.rawValue ?? ""
        // A mismatch points at the first other synced model; every other bucket gets a low score.
        let strongest = outcome == .mismatch ? (candidates.first { $0.rawValue != claimed }?.rawValue ?? "other_known_external") : claimed
        var scores = Dictionary(uniqueKeysWithValues: (candidates.map(\.rawValue) + ["other_known_external"]).map { ($0, 0.03) })
        scores[strongest] = 0.94
        let object: [String: Any] = ["id": id, "status": status, "planned": 20, "completed": progress,
            "valid": outcome == .noEvidence ? 0 : progress, "attempts": progress, "retries_used": 0, "can_stop": status == "running",
            "fingerprint": ["color": outcome == .mismatch ? "red" : "green", "model": strongest,
                "quality_status": outcome == .inconclusive ? "cell_samples_incomplete" : "sufficient",
                "partial": outcome == .inconclusive, "matches": scores, "thresholds": [claimed: 0.87]]]
        return try JSONDecoder().decode(DetectionReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func stop(id: String) async throws { stopped = true }
}

/// Offline stand-in for `ModelTraceClient`: answers are sampled from reference histograms in the bank,
/// so the real attribution code runs on them without any network request.
private actor DemoModelTraceRequester: ModelTraceRequesting {
    private var outcome: DemonstrationOutcome = .match
    private var bank: ModelTraceBank?
    private var claimed: String?
    func configure(outcome: DemonstrationOutcome, bank: ModelTraceBank, claimed: String?) {
        self.outcome = outcome; self.bank = bank; self.claimed = claimed
    }

    func collect(_ challenges: [ModelTraceChallenge], input: ModelTraceInput,
                 progress: @escaping @Sendable (ModelTraceProgress) async -> Void) async throws -> ModelTraceCollection {
        try input.validate()
        guard let bank else { throw DetectionError.message("模拟：指纹库未载入。") }
        let claimedModel = bank.models.first { $0.id == claimed } ?? bank.models[0]
        // Mismatch answers come from the other family; inconclusive splits two families evenly enough
        // that no candidate reaches the decisive probability (pinned by InvestigationStoryTests).
        // Fixed 320-number samples keep the demo deterministic regardless of the random challenge lengths.
        let other = [bank.model("gpt-5.5"), bank.model("claude-opus-4-7")].compactMap { $0 }
            .first { $0.familyID != claimedModel.familyID } ?? claimedModel
        let split = [bank.model("gpt-5.5"), bank.model("claude-sonnet-5-5")]
        var outputs: [ModelTraceOutput] = []
        for (index, challenge) in challenges.enumerated() {
            try await Task.sleep(for: .milliseconds(900))
            if outcome == .failed && index == 1 { throw DetectionError.message("模拟：接口返回了错误响应。") }
            let text: String
            switch outcome {
            case .noEvidence: text = "抱歉，我无法完成这个任务。"
            case .mismatch: text = other.syntheticAnswer(count: 320, seed: UInt64(index + 1))
            case .inconclusive:
                text = index < 2 ? (split[index] ?? claimedModel).syntheticAnswer(count: index == 0 ? 200 : 330, seed: index == 0 ? 11 : 5)
                    : "抱歉，我无法完成这个任务。"
            default: text = claimedModel.syntheticAnswer(count: 320, seed: UInt64(index + 1))
            }
            outputs.append(ModelTraceOutput(text: text, expectedCount: challenge.expectedCount))
            await progress(ModelTraceProgress(planned: challenges.count, completed: index + 1,
                                              valid: outputs.filter { ModelTraceClient.isUsable($0.text, expected: $0.expectedCount) }.count,
                                              attempts: index + 1))
        }
        return ModelTraceCollection(outputs: outputs, format: .chatCompletions, attempts: challenges.count, failures: [:])
    }
}
