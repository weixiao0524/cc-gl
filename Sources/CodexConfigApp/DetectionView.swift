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
                    DetectiveAnimation(scene: model.scene, motionDisabled: model.isDemo && CommandLine.arguments.contains("--demo-reduce-motion"))
                    story
                    if let stage = model.scene.stage { steps(stage) }
                    if model.phase == .running {
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
                    configuration
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        technicalDetails.padding(.top, 10)
                    } label: {
                        Label("查看详细报告与检测说明", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(13)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
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
            Text("检查模型：\(model.candidate.rawValue)\n接口地址：\(model.baseURL)\n\n" +
                 (model.isDemo ? "仅播放模拟查案过程，不联网、不收费，也不修改配置。" :
                    "检测由 meowllm.top 执行，需要向它提交此接口的 API Key。地址和结果会公开。低档最多发起 \(model.plan?.maximum ?? 0) 次 API 请求，费用从对应 API 账户扣除。\n\n本工具不会修改 Codex 配置。"))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型侦探社").font(.system(size: 21, weight: .bold, design: .rounded))
                Text("让复杂检查，变成一次小小的查案。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.isDemo ? "模拟演练" : "轻量检查", systemImage: model.isDemo ? "theatermasks" : "leaf")
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
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .accessibilityIdentifier("detective-story-title")
            Text(model.scene.explanation)
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
                Text("这次查谁？").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.remoteMayBeActive {
                    Text((model.testedCandidate ?? model.candidate).rawValue)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    Picker("检查模型", selection: $model.candidate) {
                        ForEach(DetectionCandidate.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 215)
                    .accessibilityLabel("检查模型").accessibilityIdentifier("detection-model")
                }
            }
            Text("接口：\(model.baseURL)")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if let tested = model.testedCandidate, model.report?.isTerminal == true {
                Text("上方结论对应：\(tested.rawValue)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
            }
            if let plan = model.plan, !model.remoteMayBeActive {
                Text("使用低档检查，最多 \(plan.maximum) 次 API 请求（含失败重试）。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isDemo {
                Text("演练不联网、不收费。真实检查会提交密钥、公开地址和结果，并消耗 API 账户余额。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("开始前说明：API Key 会发送给 meowllm.top（经 Cloudflare 代理）；接口地址和结果会公开，检查会产生 API 调用费用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Toggle(model.isDemo ? "我已了解，开始模拟演练" : "我同意发送密钥、公开地址和结果，并承担调用费用", isOn: $model.consent)
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
            if model.phase == .failed && model.bootstrap == nil {
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
            Text(model.message).font(.system(size: 12)).textSelection(.enabled)
            if let report = model.report {
                Text("网站原始结论：\(report.verdict)")
                Text("已处理 \(report.completed)/\(report.planned) · 有效样本 \(report.valid ?? 0) · 尝试 \(report.attempts ?? 0) 次 · 重试 \(report.retries_used ?? 0) 次")
                if let fingerprint = report.fingerprint, (report.valid ?? 0) > 0 {
                    ForEach(fingerprint.matches.keys.filter {
                        ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "other_known_external"].contains($0)
                    }.sorted(), id: \.self) { key in
                        if let score = fingerprint.matches[key], score.isFinite, (0...1).contains(score) {
                            HStack {
                                Text(key == "other_known_external" ? "其他候选" : key)
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
            Text("匹配度不是身份概率，低档结果仅供参考。动画只是状态说明，不提供额外证据，也不控制检测进度。")
            if let plan = model.plan { Text("低档计划：\(plan.requests) 次请求 + 最多 \(plan.retries) 次重试；并发 3。") }
            Text("网站称不长期保存 Key，本工具无法独立保证其服务器行为。退出不会自动停止远端任务。")
            Link("前往 meowllm.top 查看网站", destination: MeowDetectionClient.website)
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
}
