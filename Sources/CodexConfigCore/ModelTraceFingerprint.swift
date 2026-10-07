import Foundation

/// One collected answer to a ModelTrace challenge.
public struct ModelTraceOutput: Sendable {
    public let text: String
    public let expectedCount: Int
    public init(text: String, expectedCount: Int) { self.text = text; self.expectedCount = expectedCount }
}

public struct ModelTraceResult: Sendable {
    public struct Candidate: Sendable, Identifiable {
        public let model: String
        public let displayName: String
        public let family: String
        public let familyName: String
        public let probability: Double
        /// Probability within its own family.
        public let conditionalProbability: Double
        /// 1 − Jensen–Shannon distance between the pooled answer histogram and the model's reference histogram.
        public let profileSimilarity: Double
        public let score: Double
        public var id: String { model }
    }
    public struct Family: Sendable, Identifiable {
        public let family: String
        public let displayName: String
        public let probability: Double
        public var id: String { family }
    }
    public struct Diagnostic: Sendable {
        public let index: Int
        public let parsedNumbers: Int
        public let minimumNumbers: Int
        public let accepted: Bool
    }
    public let results: [Candidate]
    public let families: [Family]
    public let diagnostics: [Diagnostic]
    public let usedOutputs: Int
    public let calibrationQueries: Int
    public let beta: Double
    public let cvAccuracy: Double?

    public var top: Candidate { results[0] }
    public var topFamily: Family { families.max { $0.probability < $1.probability } ?? families[0] }
}

/// Swift port of ModelTrace `static/fingerprint-core.js` ("统一全局稳健数字指纹"). Keep it numerically
/// identical to upstream: `ModelTraceTests` pins results produced by the JS implementation.
public enum ModelTraceFingerprint {
    public static let valueMin = 1
    public static let valueMax = 355
    public static let dimension = valueMax - valueMin + 1
    public static let orderedDimension = 4 * 16 + 10
    static let alpha = 0.5

    /// Longest run of in-range integers; a separator containing a letter starts a new run.
    public static func parseNumbers(_ text: String) -> [Int] {
        var runs: [[Int]] = []
        var current: [Int] = []
        var separatorHasLetter = false
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            if !current.isEmpty && separatorHasLetter { runs.append(current); current = [] }
            separatorHasLetter = false
            // Equivalent to JS Number(): leading zeros are ignored, anything over three digits is > 355.
            let significant = digits.drop { $0 == 48 }
            if significant.count <= 3 {
                let value = significant.reduce(0) { $0 * 10 + Int($1 - 48) }
                if value >= valueMin && value <= valueMax { current.append(value) }
            }
            digits.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57 {
                digits.append(UInt8(scalar.value))
            } else {
                flushDigits()
                if isLetter(scalar) { separatorHasLetter = true }
            }
        }
        flushDigits()
        if !current.isEmpty { runs.append(current) }
        return runs.reduce([]) { $1.count > $0.count ? $1 : $0 }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// A response counts only with at least this many parsed integers.
    public static func minimumNumbers(expected: Int) -> Int {
        expected > 0 ? max(80, Int((Double(expected) * 0.55).rounded(.up))) : 80
    }

    static func countNumbers(_ numbers: [Int]) -> [Double] {
        var counts = [Double](repeating: 0, count: dimension)
        for number in numbers { counts[number - valueMin] += 1 }
        return counts
    }

    public static func analyze(_ outputs: [ModelTraceOutput], bank: ModelTraceBank) throws -> ModelTraceResult {
        var valid: [(counts: [Double], scores: [Double])] = []
        var diagnostics: [ModelTraceResult.Diagnostic] = []
        for (index, item) in outputs.enumerated() {
            let numbers = parseNumbers(item.text)
            let minimum = minimumNumbers(expected: item.expectedCount)
            let accepted = numbers.count >= minimum
            diagnostics.append(.init(index: index, parsedNumbers: numbers.count, minimumNumbers: minimum, accepted: accepted))
            if accepted { valid.append((countNumbers(numbers), robustScoreNumbers(numbers, bank: bank))) }
        }
        guard !valid.isEmpty else {
            throw DetectionError.message("没有可用回答：拒答或严重截断的回答不会计入。")
        }
        let models = bank.models
        let combined = models.indices.map { modelIndex in mean(valid.map { $0.scores[modelIndex] }) }
        let queries = min(valid.count, 3)
        let calibration = bank.calibration[String(queries)]!
        let probabilities = softmax(combined.map { calibration.beta * $0 })
        let pooled = (0..<dimension).map { index in valid.reduce(0) { $0 + $1.counts[index] } }

        var familyOrder: [String] = []
        for model in models where !familyOrder.contains(model.familyID) { familyOrder.append(model.familyID) }
        let familyNames = Dictionary(uniqueKeysWithValues: familyOrder.map { family in
            (family, models.first { $0.familyID == family }?.family_name ?? family)
        })
        var familyProbability: [String: Double] = [:]
        for (index, model) in models.enumerated() { familyProbability[model.familyID, default: 0] += probabilities[index] }

        // JS Array.sort is stable; break ties by bank order to match it.
        let order = models.indices.sorted { probabilities[$0] != probabilities[$1] ? probabilities[$0] > probabilities[$1] : $0 < $1 }
        let results = order.map { index -> ModelTraceResult.Candidate in
            let model = models[index]
            return .init(model: model.id, displayName: model.display_name, family: model.familyID,
                         familyName: familyNames[model.familyID] ?? model.familyID, probability: probabilities[index],
                         conditionalProbability: probabilities[index] / familyProbability[model.familyID]!,
                         profileSimilarity: jsSimilarity(pooled, model.counts), score: combined[index])
        }
        return ModelTraceResult(
            results: results,
            families: familyOrder.map { .init(family: $0, displayName: familyNames[$0] ?? $0, probability: familyProbability[$0]!) },
            diagnostics: diagnostics, usedOutputs: valid.count, calibrationQueries: queries,
            beta: calibration.beta, cvAccuracy: calibration.cv_accuracy)
    }

    // MARK: - Scoring (mirrors fingerprint-core.js)

    static func robustScoreNumbers(_ numbers: [Int], bank: ModelTraceBank) -> [Double] {
        let marginal = robustScoreCounts(countNumbers(numbers), bank: bank)
        guard let artifact = bank.robust.ordered_blocks, let weight = artifact.weight, weight != 0 else { return marginal }
        let ordered = orderedBlockScores(numbers, artifact: artifact)
        return marginal.indices.map { (1 - weight) * marginal[$0] + weight * ordered[$0] }
    }

    private static func robustScoreCounts(_ counts: [Double], bank: ModelTraceBank) -> [Double] {
        let artifact = bank.robust.hellinger
        let feature = hellingerFeature(counts)
        var projected = feature.indices.map { (feature[$0] - artifact.feature_mean[$0]) / artifact.feature_scale[$0] }
        projected = normalized(subtractBasis(projected, artifact.nuisance_basis))
        return standardize(artifact.centroids.map { dot(projected, $0) })
    }

    private static func orderedBlockScores(_ numbers: [Int], artifact: ModelTraceBank.OrderedBlocks) -> [Double] {
        let feature = orderedBlockFeature(numbers)
        let standardized = feature.indices.map { (feature[$0] - artifact.feature_mean[$0]) / artifact.feature_scale[$0] }
        let unit = normalized(standardized)
        let environmentScores = artifact.environment_centroids.map { $0.map { dot(unit, $0) } }
        let template = standardize(artifact.centroids.indices.map { modelIndex in
            environmentScores.map { $0[modelIndex] }.max()!
        })
        let projected = normalized(subtractBasis(standardized, artifact.nuisance_basis))
        let nuisance = standardize(artifact.centroids.map { dot(projected, $0) })
        return standardize(template.indices.map { 0.5 * template[$0] + 0.5 * nuisance[$0] })
    }

    static func hellingerFeature(_ counts: [Double]) -> [Double] {
        let total = counts.reduce(0, +) + alpha * Double(dimension)
        return counts.map { (($0 + alpha) / total).squareRoot() }
    }

    static func orderedBlockFeature(_ numbers: [Int]) -> [Double] {
        var pieces: [Double] = []
        for chunk in splitIntoFour(numbers) {
            var bins = [Double](repeating: 0.5, count: 16)
            for value in chunk {
                bins[min(15, Int((Double(value - 1) / 355 * 16).rounded(.down)))] += 1
            }
            let total = bins.reduce(0, +)
            pieces += bins.map { ($0 / total).squareRoot() }
        }
        var lastDigits = [Double](repeating: 0.5, count: 10)
        for value in numbers { lastDigits[value % 10] += 1 }
        let lastTotal = lastDigits.reduce(0, +)
        pieces += lastDigits.map { ($0 / lastTotal).squareRoot() }
        return pieces
    }

    private static func splitIntoFour(_ values: [Int]) -> [ArraySlice<Int>] {
        let base = values.count / 4, remainder = values.count % 4
        var chunks: [ArraySlice<Int>] = []
        var start = 0
        for index in 0..<4 {
            let size = base + (index < remainder ? 1 : 0)
            chunks.append(values[start..<(start + size)])
            start += size
        }
        return chunks
    }

    private static func jsSimilarity(_ left: [Double], _ right: [Double]) -> Double {
        let leftTotal = left.reduce(0, +)
        let rightTotal = right.reduce(0, +) + alpha * Double(dimension)
        let p = left.map { $0 / leftTotal }
        let q = right.map { ($0 + alpha) / rightTotal }
        let midpoint = p.indices.map { (p[$0] + q[$0]) / 2 }
        func divergence(_ values: [Double]) -> Double {
            values.indices.reduce(0) { total, index in
                total + (values[index] != 0 ? values[index] * log(values[index] / midpoint[index]) : 0)
            }
        }
        let js = (divergence(p) + divergence(q)) / 2
        return 1 - (js / log(2)).squareRoot()
    }

    // MARK: - Vector helpers

    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

    private static func standardize(_ values: [Double]) -> [Double] {
        let center = mean(values)
        let variance = mean(values.map { ($0 - center) * ($0 - center) })
        let scale = max(variance.squareRoot(), 1e-12)
        return values.map { ($0 - center) / scale }
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        var value = 0.0
        for index in left.indices { value += left[index] * right[index] }
        return value
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        let scale = max(dot(values, values).squareRoot(), 1e-12)
        return values.map { $0 / scale }
    }

    private static func subtractBasis(_ values: [Double], _ basis: [[Double]]) -> [Double] {
        var output = values
        for vector in basis {
            let projection = dot(output, vector)
            for index in output.indices { output[index] -= projection * vector[index] }
        }
        return output
    }

    private static func softmax(_ values: [Double]) -> [Double] {
        let maximum = values.max()!
        let weights = values.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}

public extension ModelTraceBank.Model {
    /// Deterministic fake answer drawn from this model's reference histogram (PCG-style 64-bit LCG).
    /// Used only by the offline demo and tests; it never touches the network.
    func syntheticAnswer(count: Int, seed: UInt64) -> String {
        let cumulative = counts.reduce(into: [UInt64]()) { $0.append(($0.last ?? 0) + UInt64(max(0, $1))) }
        guard let total = cumulative.last, total > 0 else { return "" }
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = (state >> 33) % total
            let index = cumulative.firstIndex { r < $0 }!
            return String(index + ModelTraceFingerprint.valueMin)
        }.joined(separator: ", ")
    }
}
