import Foundation

/// Reference fingerprints from ModelTrace (https://github.com/xqy2006/ModelTrace, MIT). Only the fields
/// the attribution algorithm reads are decoded; the bank may come from the network, so `validate()`
/// must pass before it is used.
public struct ModelTraceBank: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public let id: String
        public let display_name: String
        public let family: String?
        public let family_name: String?
        public let counts: [Double]
        public var familyID: String { family ?? "models" }
    }
    public struct Hellinger: Decodable, Sendable {
        public let feature_mean: [Double]
        public let feature_scale: [Double]
        public let nuisance_basis: [[Double]]
        public let centroids: [[Double]]
    }
    public struct OrderedBlocks: Decodable, Sendable {
        public let weight: Double?
        public let feature_mean: [Double]
        public let feature_scale: [Double]
        public let nuisance_basis: [[Double]]
        public let centroids: [[Double]]
        public let environment_centroids: [[[Double]]]
    }
    public struct Robust: Decodable, Sendable {
        public let hellinger: Hellinger
        public let ordered_blocks: OrderedBlocks?
    }
    public struct Calibration: Decodable, Sendable {
        public let beta: Double
        public let cv_accuracy: Double?
    }

    public static let schemaName = "robust-number-fingerprint-bank"
    public let schema: String
    public let built_at: String?
    public let models: [Model]
    public let robust: Robust
    public let calibration: [String: Calibration]

    public func model(_ id: String) -> Model? { models.first { $0.id == id } }

    public func validate() throws {
        let invalid = DetectionError.message("ModelTrace 指纹库格式不符合预期，未使用。")
        let n = models.count
        let h = robust.hellinger
        guard schema == Self.schemaName, (2...200).contains(n),
              Set(models.map(\.id)).count == n,
              models.allSatisfy({ DetectionCandidate.isSafeIdentifier($0.id) && $0.counts.count == ModelTraceFingerprint.dimension &&
                  $0.counts.allSatisfy { $0.isFinite && $0 >= 0 } && $0.display_name.count <= 100 }),
              Self.shape(h.feature_mean, ModelTraceFingerprint.dimension),
              Self.shape(h.feature_scale, ModelTraceFingerprint.dimension), h.feature_scale.allSatisfy({ $0 != 0 }),
              h.nuisance_basis.count <= 16, h.nuisance_basis.allSatisfy({ Self.shape($0, ModelTraceFingerprint.dimension) }),
              h.centroids.count == n, h.centroids.allSatisfy({ Self.shape($0, ModelTraceFingerprint.dimension) }),
              (1...3).allSatisfy({ calibration[String($0)].map { $0.beta.isFinite && $0.beta > 0 && $0.beta < 1000 } ?? false })
        else { throw invalid }
        if let o = robust.ordered_blocks {
            let d = ModelTraceFingerprint.orderedDimension
            guard (o.weight ?? 0).isFinite, (0...1).contains(o.weight ?? 0),
                  Self.shape(o.feature_mean, d), Self.shape(o.feature_scale, d), o.feature_scale.allSatisfy({ $0 != 0 }),
                  o.nuisance_basis.count <= 16, o.nuisance_basis.allSatisfy({ Self.shape($0, d) }),
                  o.centroids.count == n, o.centroids.allSatisfy({ Self.shape($0, d) }),
                  !o.environment_centroids.isEmpty, o.environment_centroids.count <= 64,
                  o.environment_centroids.allSatisfy({ $0.count == n && $0.allSatisfy { Self.shape($0, d) } })
            else { throw invalid }
        }
    }

    private static func shape(_ values: [Double], _ count: Int) -> Bool {
        values.count == count && values.allSatisfy(\.isFinite)
    }
}

/// Where the bank in use came from; shown in the detection details.
public enum ModelTraceBankSource: String, Sendable {
    case builtIn = "内置", cache = "已更新（缓存）", remote = "已更新（GitHub）"
}

/// Loads the bundled bank, prefers a newer validated cached copy, and can refresh from GitHub.
public actor ModelTraceBankLoader {
    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/xqy2006/ModelTrace/main/static/data/unified_bank.json")!
    public static let resourceName = "modeltrace_bank"
    private let cacheURL: URL?
    private let transport: DetectionTransport?

    public init(cacheDirectory: URL?) {
        cacheURL = cacheDirectory?.appendingPathComponent("modeltrace_bank.json")
        transport = nil
    }
    init(cacheDirectory: URL?, transport: DetectionTransport?) {
        cacheURL = cacheDirectory?.appendingPathComponent("modeltrace_bank.json")
        self.transport = transport
    }

    /// Bundled bank, or the cached one when it is valid and at least as new.
    public func load() throws -> (ModelTraceBank, ModelTraceBankSource) {
        let builtIn = try Self.builtIn()
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? Self.decode(data),
           (cached.built_at ?? "") >= (builtIn.built_at ?? "") {
            return (cached, .cache)
        }
        return (builtIn, .builtIn)
    }

    /// Fetches the upstream bank; returns it only when it validates and is newer than `current`.
    public func refresh(newerThan current: ModelTraceBank) async -> ModelTraceBank? {
        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 20
        guard let (data, response) = try? await (transport ?? BankTransport.shared).send(request),
              response.statusCode == 200, data.count <= 4 * 1024 * 1024,
              let bank = try? Self.decode(data), (bank.built_at ?? "") > (current.built_at ?? "") else { return nil }
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return bank
    }

    static func decode(_ data: Data) throws -> ModelTraceBank {
        let bank = try JSONDecoder().decode(ModelTraceBank.self, from: data)
        try bank.validate()
        return bank
    }

    /// The .app copies the JSON into Contents/Resources; `swift test`/`swift run` use the SwiftPM bundle.
    /// `Bundle.module` is only touched when the app copy is absent, because its accessor traps if missing.
    static func builtIn() throws -> ModelTraceBank {
        let url = Bundle.main.url(forResource: resourceName, withExtension: "json")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            throw DetectionError.message("找不到内置的 ModelTrace 指纹库。")
        }
        return try decode(data)
    }
}

private final class BankTransport: DetectionTransport, @unchecked Sendable {
    static let shared = BankTransport()
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
