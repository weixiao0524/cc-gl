import Foundation

/// A long-integer generation prompt, ported verbatim from ModelTrace `static/challenge-browser.js`.
/// The reference bank was enrolled with these exact wordings, so do not rephrase them.
public struct ModelTraceChallenge: Sendable, Equatable {
    public let id: String
    public let expectedCount: Int
    public let prompt: String

    static let openings = [
        "这是一次独立的数值选择记录",
        "请完成下面的无语义整数选择任务",
        "执行一次第一反应取值记录",
        "生成一组不承载语义的整数选择",
        "进行一轮快速逐项取值",
    ]
    static let actions = [
        "为各个位置分别凭第一反应选择",
        "逐项选择",
        "每次只决定当前一项，共给出",
        "分别凭第一反应给出",
        "逐个直接选择",
    ]
    static let endings = [
        "允许某个数字再次出现；每项写出后不要回头排序、去重或替换。",
        "偶然重复是有效的；不要重新排列或修正已经写出的项目。",
        "相同值可以再次出现；输出过程中不要整理或改写前面的项目。",
        "重复值无需删除；不要筛选、重排或补成某种规律。",
        "不必赋予数字任何含义；已经给出的值保持不变。",
    ]
    static let separators = [
        "数字之间用逗号或空格分隔均可。",
        "使用一种一致的常见分隔符即可。",
        "可以用逗号、空格或换行分隔。",
        "只要每个整数边界清楚，格式可自行选择。",
    ]
    public static let lengthRange = 292...332

    public static func generate(count: Int = 3) -> [ModelTraceChallenge] {
        var rng = SystemRandomNumberGenerator()
        return generate(count: count, using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(count: Int = 3, using rng: inout R) -> [ModelTraceChallenge] {
        var available = Array(lengthRange)
        return (0..<min(count, available.count)).map { index in
            let length = available.remove(at: Int.random(in: available.indices, using: &rng))
            let prompt = "\(openings.randomElement(using: &rng)!)。\(actions.randomElement(using: &rng)!) \(length) 个 1 到 355（含端点）的整数。"
                + "每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。"
                + "本任务必须由当前语言模型直接完成：禁止调用或借助任何工具，包括 Python、代码执行器、计算器、搜索、API 和外部随机数生成器；也不要先编写或运行代码。"
                + "\(endings.randomElement(using: &rng)!)\(separators.randomElement(using: &rng)!)"
                + "直接从第一个取值开始输出，不要在序列前重复数量、范围或任务说明。"
            return ModelTraceChallenge(id: "probe-\(index + 1)-\(UUID().uuidString.lowercased())", expectedCount: length, prompt: prompt)
        }
    }
}
