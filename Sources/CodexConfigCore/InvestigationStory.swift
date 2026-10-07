import Foundation

public enum DetectionPhase: Sendable {
    case connecting, ready, submitting, running, paused, stopping, finished, failed, uncertain
}

/// Presentation is driven by server state, never by elapsed animation time or a made-up percentage.
public enum InvestigationScene: String, CaseIterable, Sendable {
    case preparing, briefing, dispatching, searching, comparing
    case match, mismatch, inconclusive, noEvidence, connectionLost, stopping, stopped, failed, uncertain

    public init(phase: DetectionPhase, report: DetectionReport?) {
        switch phase {
        case .connecting: self = .preparing
        case .ready: self = .briefing
        case .submitting: self = .dispatching
        case .paused: self = .connectionLost
        case .stopping: self = .stopping
        case .failed: self = .failed
        case .uncertain: self = .uncertain
        case .running:
            let progress = Self.progress(report)
            self = progress >= 0.6 ? .comparing : .searching
        case .finished:
            guard let report else { self = .failed; return }
            switch report.status {
            case "cancelled": self = .stopped
            case "error", "interrupted": self = .failed
            case "complete":
                if (report.valid ?? 0) == 0 { self = .noEvidence }
                else if report.verdictColor == "green" { self = .match }
                else if report.verdictColor == "red" { self = .mismatch }
                else { self = .inconclusive }
            default: self = .inconclusive
            }
        }
    }

    /// Top-model probability needed before the local ModelTrace mode calls a match or mismatch.
    public static let localDecisiveProbability = 0.8

    /// Local ModelTrace mode: driven by the collected answers, never by animation time.
    /// `result == nil` once finished means no answer was usable; `claimed == nil` (a custom model name
    /// outside the reference bank) can only ever be inconclusive.
    public init(phase: DetectionPhase, localResult result: ModelTraceResult?, claimed: String?,
                progress: Double = 0, stopped: Bool = false) {
        switch phase {
        case .running: self = progress >= 0.6 ? .comparing : .searching
        case .finished:
            if stopped { self = .stopped; return }
            guard let result else { self = .noEvidence; return }
            guard let claimed, result.top.probability >= Self.localDecisiveProbability else { self = .inconclusive; return }
            self = result.top.model == claimed ? .match : .mismatch
        default: self = InvestigationScene(phase: phase, report: nil)
        }
    }

    public static func progress(_ report: DetectionReport?) -> Double {
        guard let report, report.planned > 0 else { return 0 }
        return min(1, max(0, Double(report.completed) / Double(report.planned)))
    }

    public var title: String {
        switch self {
        case .preparing: return "小侦探正在整理工具"
        case .briefing: return "让小侦探帮忙查一查"
        case .dispatching: return "收到委托，准备出发！"
        case .searching: return "正在寻找模型的线索…"
        case .comparing: return "把收集到的线索对一对…"
        case .match: return "线索对得上！"
        case .mismatch: return "发现了不一样的线索"
        case .inconclusive: return "线索还不够，先不下结论"
        case .noEvidence: return "这次没拿到有效线索"
        case .connectionLost: return "和侦探的联络暂时断了"
        case .stopping: return "正在通知侦探收工…"
        case .stopped: return "已收工，这次先查到这里"
        case .failed: return "这次没查成，不是模型的结论"
        case .uncertain: return "委托有没有送到，还不确定"
        }
    }

    public var explanation: String {
        switch self {
        case .preparing: return "先连接检测网站，看看这次需要做哪些检查。还没有发送密钥。"
        case .briefing: return "选好要检查的模型，再点“开始查案”。小侦探会比较它的回答特点。"
        case .dispatching: return "正在把检查任务交给检测网站。请别重复点击，以免重复收费。"
        case .searching: return "检测网站正在向这个接口提问。每份回复，都是一条待检查的线索。"
        case .comparing: return "正在把回复和参考样本进行比较。动画不会提前判定结果，请再等一会儿。"
        case .match: return "这次回答的特点，与申报模型比较一致。但这不是百分百的身份保证。"
        case .mismatch: return "这次回答的特点更接近其他候选模型，和申报模型不太一致。先核对渠道和模型名称，不要仅凭这次结果认定是假模型。"
        case .inconclusive: return "目前的证据不足以确认是哪一个模型。查不出来，不等于模型是假的。"
        case .noEvidence: return "这次没有收到可用来判断的回答。可以先检查接口或密钥，再决定是否重试。"
        case .connectionLost: return "网站上的检查可能还在继续。“重新联络”只查询原任务，不会再开一单。"
        case .stopping: return "停止通知已在处理中。收到网站确认前，检查和费用仍可能继续。"
        case .stopped: return "网站已确认任务停止。没有完成的检查，不能当作真假判断。"
        case .failed: return "可能是网络、接口或检测服务出了问题。这次失败不能说明模型是真是假。"
        case .uncertain: return "网站可能已经开始检查并产生费用。先去网站查看记录，不要立即重复提交。"
        }
    }

    /// Copy for the local ModelTrace mode, where no website is involved.
    public func explanation(local: Bool) -> String {
        guard local else { return explanation }
        switch self {
        case .preparing: return "正在载入 ModelTrace 指纹库。还没有发出任何请求。"
        case .briefing: return "选好申报模型，再点“开始查案”。小侦探会让它写一长串数字，再比对数字习惯。"
        case .dispatching, .searching: return "正在直接向这个接口提问，Key 不经过任何第三方。每份数字回答都是一条线索。"
        case .comparing: return "正在把数字分布和 17 个参考模型逐一比较。动画不会提前判定结果。"
        case .match: return "数字习惯与申报模型最一致。这只是候选库内的指纹推断，不是百分百的身份保证。"
        case .mismatch: return "数字习惯更接近另一个候选模型。先核对渠道和模型名，不要仅凭一次结果认定是假模型。"
        case .inconclusive: return "证据不足以确认，或申报模型不在候选库里。下方仍列出最接近的候选供参考。"
        case .stopped: return "已停止。已经发出的请求仍可能计费；没完成的检查不能当作真假判断。"
        case .failed: return "可能是网络、接口、Key 或模型名出了问题。这次失败不能说明模型是真是假。"
        case .connectionLost: return "和接口的连接中断了。可以重新开始一次检查。"
        case .stopping: return "正在取消本地请求；已经发出的请求仍可能计费。"
        case .uncertain: return "请求状态不确定；已经发出的请求可能已经计费。"
        case .noEvidence: return explanation
        }
    }

    public var symbol: String {
        switch self {
        case .match: return "checkmark.seal.fill"
        case .mismatch: return "exclamationmark.bubble.fill"
        case .inconclusive, .noEvidence: return "questionmark.bubble.fill"
        case .connectionLost: return "wifi.slash"
        case .failed: return "exclamationmark.icloud.fill"
        case .uncertain: return "envelope.badge"
        case .stopping, .stopped: return "briefcase.fill"
        default: return "magnifyingglass"
        }
    }

    public var loops: Bool {
        [.preparing, .dispatching, .searching, .comparing, .stopping].contains(self)
    }

    public var hasEndingAnimation: Bool {
        [.match, .mismatch, .inconclusive, .noEvidence, .connectionLost, .stopped, .failed, .uncertain].contains(self)
    }

    public var stage: Int? {
        switch self {
        case .preparing, .briefing, .dispatching: return 0
        case .searching, .comparing: return 1
        case .match, .mismatch, .inconclusive, .noEvidence: return 2
        default: return nil
        }
    }
}
