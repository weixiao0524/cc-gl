import SwiftUI
import AppKit
import CodexConfigCore

struct DetectionView: View {
    @ObservedObject var model: DetectionViewModel
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var detailsExpanded = false
    private var accent: Color { DetectiveStyle.accent(model.scene, dark: colorScheme == .dark) }
    private var panelHeight: CGFloat { min(735, max(480, (NSScreen.main?.visibleFrame.height ?? 820) - 70)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 17) {
                    if model.hasCompletedReport {
                        resultSummary
                    } else {
                        configuration
                        story
                    }
                    if let stage = model.scene.stage { steps(stage) }
                    if model.phase == .running && model.isLocal {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: model.localProgressFraction)
                            if let progress = model.localProgress {
                                Text("已收到 \(progress.completed) / \(progress.planned) 份回答 · 有效 \(progress.valid) · 已发请求 \(progress.attempts) 次")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    } else if model.phase == .running {
                        VStack(alignment: .leading, spacing: 6) {
                            if let report = model.report {
                                ProgressView(value: InvestigationScene.progress(report))
                                Text("已查看 \(report.completed) / \(report.planned) 份回复")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Text("正在等待第一份回复，不用反复点击。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(model.message)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DetectiveAnimation(scene: model.scene,
                                       motionDisabled: model.isDemo && CommandLine.arguments.contains("--demo-reduce-motion"),
                                       height: model.hasCompletedReport ? 120 : 160)
                    if model.hasCompletedReport { configuration }
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        technicalDetails.padding(.top, 10)
                    } label: {
                        Label("查看详细报告与检测说明", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(13)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            if !model.remoteMayBeActive {
                consent.padding(.horizontal, 24).padding(.vertical, 12)
            }
            Divider()
            actions
        }
        .frame(width: 650, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .interactiveDismissDisabled(model.remoteMayBeActive)
        .task { model.connect() }
        .onDisappear { if !model.remoteMayBeActive { model.close() } }
        .onChange(of: model.candidate) { _ in model.consent = false }
        .alert(model.isDemo ? "让小侦探演练一次？" : "确认委托小侦探？", isPresented: $model.showConfirmation) {
            Button("再想想", role: .cancel) {}
            Button(model.isDemo ? "开始演练" : "确认，开始检查") { model.confirmStart() }
        } message: {
            Text("检查模型：\(model.isLocal ? model.requestModel : model.candidate?.rawValue ?? "—")\n接口地址：\(model.baseURL)\n\n" +
                 (model.isDemo ? "仅播放模拟查案过程，不联网、不收费，也不修改配置。" : model.isLocal ? localCostNotice + "\n\n本工具不会修改 Codex 配置。" :
                    "检测由 meowllm.top 执行，需要向它提交此接口的 API Key。地址和结果会公开。低档最多发起 \(model.plan?.maximum ?? 0) 次 API 请求，费用从对应 API 账户扣除。\n\n本工具不会修改 Codex 配置。"))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型侦探社").font(.system(size: 21, weight: .bold, design: .rounded))
            }
            Spacer()
            Picker("检测方式", selection: $model.mode) {
                ForEach(DetectionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(model.remoteMayBeActive || model.hasKnownActiveRun)
            .accessibilityLabel("检测方式").accessibilityIdentifier("detection-mode")
            Label(model.isDemo ? "模拟演练" : model.isLocal ? "本地鉴定" : "轻量检查",
                  systemImage: model.isDemo ? "theatermasks" : model.isLocal ? "lock.shield" : "leaf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(accent.opacity(0.09), in: Capsule())
        }
        .padding(24).padding(.bottom, -7)
    }

    private var story: some View {
        VStack(spacing: 8) {
            Text(model.scene.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .accessibilityIdentifier("detective-story-title")
            Text(model.scene.explanation(local: model.isLocal))
                .font(.system(size: 13)).lineSpacing(4)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if model.isDemo {
                Text("演示画面与结果均为模拟，不代表真实模型身份。")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测结果").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LabeledContent("检测对象", value: model.reportCandidate?.rawValue ?? "—")
                .font(.system(size: 13, design: .monospaced))
            Text(model.baseURL).font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Label(model.scene.title, systemImage: model.scene.symbol)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
                .accessibilityIdentifier("detective-story-title")
            if model.isLocal {
                localSummaryMetrics
            } else if let report = model.report {
                HStack(spacing: 24) {
                    resultMetric("有效样本", value: "\(report.valid ?? 0)")
                    resultMetric("已处理", value: "\(report.completed) / \(report.planned)")
                    resultMetric("尝试次数", value: "\(report.attempts ?? 0)")
                }
                .padding(.vertical, 4)
            }
            Text(model.scene.explanation(local: model.isLocal)).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.isDemo ? "模拟结果，不代表真实模型身份。" : model.isLocal ?
                 "ModelTrace 闭集指纹推断：只在候选库内归因，库外模型也会被归到最接近的候选，不构成真实性保证。" :
                 "第三方指纹推断，匹配度不是身份概率，不构成真实性保证。")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("detection-result-summary")
    }

    private func resultMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func steps(_ current: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(["接下委托", "收集线索", "查看结论"].enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.inset.filled" : "circle")
                    Text(name)
                }
                .font(.system(size: 11, weight: index == current ? .semibold : .regular))
                .foregroundStyle(index <= current ? accent : .secondary)
                if index < 2 { Rectangle().fill(.primary.opacity(0.12)).frame(width: 23, height: 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("调查步骤：\(["接下委托", "收集线索", "查看结论"][current])")
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.hasCompletedReport ? "再次检测" : "检测对象").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.remoteMayBeActive || (model.isLocal && model.hasKnownActiveRun) {
                    Text(model.reportCandidate?.rawValue ?? "—")
                        .font(.system(size: 13, design: .monospaced))
                } else if model.candidates.isEmpty {
                    // Options come from the site's bootstrap; nothing is selectable until it syncs.
                    Text(model.phase == .connecting ? (model.isLocal ? "正在载入指纹库…" : "正在同步模型列表…") : "暂无可检测模型")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("detection-model")
                } else {
                    Picker("检查模型", selection: $model.candidate) {
                        ForEach(model.candidates) { Text($0.name).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(width: 215)
                    .accessibilityLabel("检查模型").accessibilityIdentifier("detection-model")
                }
            }
            if model.isCustomModel && !model.hasKnownActiveRun {
                TextField("请求时使用的模型名，例如 openai/gpt-5.5", text: $model.customModel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .accessibilityIdentifier("detection-custom-model")
                Text(model.claimedBankModel.map { "将按候选库中的 \($0) 判断是否一致。" } ?? "不在候选库内的名称只给出最接近的候选，不判断一致与否。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("接口：\(model.baseURL)")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if let tested = model.testedCandidate, model.report?.isTerminal == true {
                Text("上方结论对应：\(tested.rawValue)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
            }
            if model.isLocal, !model.hasKnownActiveRun {
                Text("本地鉴定：\(DetectionViewModel.localChallengeCount) 道数字题，最多 \(DetectionViewModel.localChallengeCount * (1 + ModelTraceClient.retriesPerChallenge)) 次计费请求（含重试）。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let plan = model.plan, !model.remoteMayBeActive {
                Text("使用低档检查，最多 \(plan.maximum) 次 API 请求（含失败重试）。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isDemo {
                Text(model.isLocal ? "演练不联网、不收费。真实的本地鉴定会直接向当前接口发起请求，并消耗 API 账户余额。" :
                        "演练不联网、不收费。真实检查会提交密钥、公开地址和结果，并消耗 API 账户余额。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if model.isLocal {
                Text("开始前说明：" + localCostNotice)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("开始前说明：API Key 会发送给 meowllm.top（经 Cloudflare 代理）；接口地址和结果会公开，检查会产生 API 调用费用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Toggle(model.isDemo ? "我已了解，开始模拟演练" : model.isLocal ? "我已了解，并承担这些请求的调用费用" :
                    "我同意发送密钥、公开地址和结果，并承担调用费用", isOn: $model.consent)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .accessibilityIdentifier("detection-consent")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Label("不改动现有配置", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.phase == .failed && (model.isLocal ? model.bank == nil : model.bootstrap == nil) {
                Button("重新连接") { model.connect() }
            }
            if model.phase == .paused {
                Button("重新联络") { model.resumePolling() }
            }
            if model.hasKnownActiveRun {
                Button(model.phase == .stopping ? "等待收工确认" : "结束调查") { model.stop() }
                    .disabled(model.phase == .stopping)
            }
            Button("关闭") { model.close(); dismiss() }.disabled(!model.canDismiss)
                .help(model.isLocal && model.hasKnownActiveRun ? "关闭会取消尚未完成的本地请求" : "")
            if !model.remoteMayBeActive {
                Button(model.report?.isTerminal == true ? "再查一次" : "开始查案") { model.showConfirmation = true }
                    .buttonStyle(.borderedProminent).disabled(!model.canStart)
                    .foregroundStyle(model.canStart ? (colorScheme == .dark ? Color.black : Color.white) : Color.secondary)
                    .accessibilityIdentifier("detective-start")
            }
        }
        .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 17)
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isLocal {
                localDetails
            } else if let report = model.report {
                Text("网站原始结论：\(report.verdict)")
                Text("已处理 \(report.completed)/\(report.planned) · 有效样本 \(report.valid ?? 0) · 尝试 \(report.attempts ?? 0) 次 · 重试 \(report.retries_used ?? 0) 次")
                if let fingerprint = report.fingerprint, (report.valid ?? 0) > 0, let bootstrap = model.bootstrap {
                    // Only keys the synced benchmark declares are shown; arbitrary server keys are ignored.
                    ForEach(bootstrap.fingerprintModelIDs.filter { fingerprint.matches[$0] != nil }, id: \.self) { key in
                        if let score = fingerprint.matches[key], score.isFinite, (0...1).contains(score) {
                            HStack {
                                Text(bootstrap.displayName(for: key))
                                Spacer()
                                Text(String(format: "匹配度 %.3f%%", score * 100))
                            }
                        }
                    }
                }
                if let failure = report.failure { Text(DetectionError.explanation(failure)) }
                if let errors = report.errors {
                    ForEach(errors.keys.sorted(), id: \.self) { code in
                        Text("\(DetectionError.explanation(code)) × \(errors[code] ?? 0)")
                    }
                }
            }
            if !model.isLocal {
                Text("匹配度不是身份概率，低档结果仅供参考。动画只是状态说明，不提供额外证据，也不控制检测进度。")
                if let plan = model.plan { Text("低档计划：\(plan.requests) 次请求 + 最多 \(plan.retries) 次重试；并发 3。") }
                Text("网站称不长期保存 Key，本工具无法独立保证其服务器行为。退出不会自动停止远端任务。")
                Link("前往 meowllm.top 查看网站", destination: MeowDetectionClient.website)
            }
            if model.isDemo {
                Picker("演练结局", selection: $model.demoOutcome) {
                    ForEach(DemonstrationOutcome.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.remoteMayBeActive)
                .accessibilityIdentifier("demo-outcome")
                Text("此选项只在隔离演示中出现，用来检查不同动画，不会影响真实检测。")
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Local ModelTrace mode

    private var localCostNotice: String {
        "API Key 只发送到当前接口地址，不经过任何第三方。将直接发起 \(DetectionViewModel.localChallengeCount) 次请求" +
        "（失败最多各重试 \(ModelTraceClient.retriesPerChallenge) 次，另有自动识别接口格式时被拒绝的探测），" +
        "每次最多输出 \(ModelTraceClient.maxOutputTokens) tokens，费用由该 API 账户承担。"
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    @ViewBuilder private var localSummaryMetrics: some View {
        if let result = model.localResult {
            HStack(spacing: 24) {
                resultMetric("最可能", value: result.top.displayName)
                resultMetric("概率", value: percent(result.top.probability))
                resultMetric("家族", value: "\(result.topFamily.displayName) \(percent(result.topFamily.probability))")
            }
            .padding(.vertical, 4)
            if let claimed = model.localClaimed, claimed != result.top.model,
               let row = result.results.first(where: { $0.model == claimed }) {
                Text("申报模型 \(row.displayName) 的概率：\(percent(row.probability))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 24) {
            resultMetric("有效回答", value: "\(model.localResult?.usedOutputs ?? 0) / \(model.localProgress?.planned ?? DetectionViewModel.localChallengeCount)")
            resultMetric("请求次数", value: "\(model.localCollection?.attempts ?? model.localProgress?.attempts ?? 0)")
            resultMetric("接口格式", value: model.localCollection?.format?.rawValue ?? "—")
        }
    }

    @ViewBuilder private var localDetails: some View {
        if let result = model.localResult {
            Text("全部候选（概率 · 同家族内概率 · 分布相似度）")
            ForEach(result.results) { row in
                HStack {
                    Text(row.displayName).fontWeight(row.model == model.localClaimed ? .semibold : .regular)
                    Spacer()
                    Text("\(percent(row.probability)) · \(percent(row.conditionalProbability)) · \(String(format: "%.3f", row.profileSimilarity))")
                        .monospacedDigit()
                }
            }
            ForEach(result.diagnostics, id: \.index) { item in
                Text("回答 \(item.index + 1)：解析 \(item.parsedNumbers) 个数字，需 ≥ \(item.minimumNumbers)，\(item.accepted ? "计入" : "不计入")")
            }
            Text("校准：\(result.calibrationQueries) 份回答，β = \(String(format: "%.2f", result.beta))" +
                 (result.cvAccuracy.map { "，交叉验证准确率 \(percent($0))" } ?? ""))
        }
        if let failures = model.localCollection?.failures, !failures.isEmpty {
            ForEach(failures.keys.sorted(), id: \.self) { code in
                Text("\(ModelTraceClient.explanation(code)) × \(failures[code] ?? 0)")
            }
        }
        if let bank = model.bank {
            Text("指纹库：\(model.bankSource?.rawValue ?? "—") · \(bank.models.count) 个模型 · 构建于 \(bank.built_at ?? "未知")")
        }
        Text("原理：让模型写 3 串 1–355 的整数，比较数字分布（Hellinger，去除环境方向）与分段顺序特征，再按校准温度换算为候选库内概率。概率高不等于身份保证；库外模型同样会被归到最接近的候选。")
        Text("回答被截断、拒答、调用工具或回显 Key 时不计入。动画只是状态说明，不提供额外证据。")
        Link("ModelTrace 项目（MIT）", destination: URL(string: "https://github.com/xqy2006/ModelTrace")!)
    }
}
