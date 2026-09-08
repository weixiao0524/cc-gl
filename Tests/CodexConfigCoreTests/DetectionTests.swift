import XCTest
@testable import CodexConfigCore

private actor MockDetectionTransport: DetectionTransport {
    enum Reply { case json(Int, String); case timeout }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .timeout: throw URLError(.timedOut)
        case .json(let status, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    func captured() -> [URLRequest] { requests }
}

final class DetectionTests: XCTestCase {
    private let bootstrapJSON = """
    {"csrf":"test-csrf-token","public_site":true,"benchmarks":[{"id":"test","version":"1","mode":"gpt",
    "models":[{"id":"gpt-6-astra","name":"gpt-6-astra"},{"id":"gpt-5.6-sol","name":"gpt-5.6-sol"}],
    "tiers":{"low":20,"medium":40,"high":60}}]}
    """
    private func input(_ candidate: DetectionCandidate = .astra, consent: Bool = true,
                       url: String = "https://api.example.com/v1", key: String = "dummy-test-key") -> DetectionInput {
        DetectionInput(baseURL: url, apiKey: key, candidate: candidate, publicConsent: consent)
    }

    func testExactlyTwoCandidatesAndLowPlan() throws {
        XCTAssertEqual(DetectionCandidate.allCases.map(\.rawValue), ["gpt-6-astra", "gpt-5.6-sol"])
        let bootstrap = try JSONDecoder().decode(DetectionBootstrap.self, from: Data(bootstrapJSON.utf8))
        for model in DetectionCandidate.allCases {
            let plan = try bootstrap.plan(for: model)
            XCTAssertEqual(plan.requests, 20)
            XCTAssertEqual(plan.retries, 10)
            XCTAssertEqual(plan.maximum, 30)
        }
    }

    func testLiveMetadataChangesFailClosed() throws {
        for source in [bootstrapJSON.replacingOccurrences(of: "\"low\":20", with: "\"low\":999"),
                       bootstrapJSON.replacingOccurrences(of: "\"public_site\":true", with: "\"public_site\":false"),
                       bootstrapJSON.replacingOccurrences(of: "gpt-6-astra", with: "missing-model")] {
            let bootstrap = try JSONDecoder().decode(DetectionBootstrap.self, from: Data(source.utf8))
            XCTAssertThrowsError(try bootstrap.plan(for: .astra))
        }
    }

    func testInputRequiresConsentPublicHTTPSAndValidKey() throws {
        try input().validate()
        for url in ["http://api.example.com/v1", "https://localhost/v1", "https://127.0.0.1/v1",
                    "https://10.1.2.3", "https://192.168.1.2", "https://172.16.1.2", "https://[::1]", "https://[fd12::1]",
                    "https://example.com:8443", "https://example.com/?key=foo", "https://dummy-test-key.example.com"] {
            XCTAssertThrowsError(try input(url: url).validate(), url)
        }
        XCTAssertThrowsError(try input(consent: false).validate())
        XCTAssertThrowsError(try input(key: "short").validate())
        XCTAssertThrowsError(try input(key: "contains space").validate())
    }

    func testRequestContractAndNoKeyInURLOrBootstrap() async throws {
        let transport = MockDetectionTransport([.json(200, bootstrapJSON), .json(200, #"{"id":"run_123"}"#)])
        let client = MeowDetectionClient(transport: transport)
        let bootstrap = try await client.prepare()
        let id = try await client.start(input(.sol), reviewedPlan: bootstrap.plan(for: .sol))
        XCTAssertEqual(id, "run_123")
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://meowllm.top/api/bootstrap")
        XCTAssertNil(requests[0].httpBody)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Meow-Token"))
        let post = requests[1]
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.absoluteString, "https://meowllm.top/api/runs")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Origin"), "https://meowllm.top")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Meow-Token"), "test-csrf-token")
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as! [String: Any]
        XCTAssertEqual(payload["claimed_model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(payload["request_model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(payload["tier"] as? String, "low")
        XCTAssertEqual(payload["workers"] as? Int, 3)
        XCTAssertEqual(payload["retry_budget"] as? Int, 10)
        XCTAssertEqual(payload["site_group"] as? String, "")
        XCTAssertEqual(payload["public_report"] as? Bool, true)
        XCTAssertEqual(payload["key"] as? String, "dummy-test-key")
        XCTAssertFalse(post.url!.absoluteString.contains("dummy-test-key"))
    }

    func testMissingConsentDoesNotSubmit() async throws {
        let transport = MockDetectionTransport([.json(200, bootstrapJSON)])
        let client = MeowDetectionClient(transport: transport)
        let bootstrap = try await client.prepare()
        do {
            _ = try await client.start(input(consent: false), reviewedPlan: bootstrap.plan(for: .astra))
            XCTFail("Must reject missing consent")
        } catch {}
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testChangedReviewedBudgetDoesNotSubmit() async throws {
        let transport = MockDetectionTransport([.json(200, bootstrapJSON)])
        let client = MeowDetectionClient(transport: transport)
        _ = try await client.prepare()
        do {
            _ = try await client.start(input(), reviewedPlan: DetectionPlan(requests: 10, retries: 0))
            XCTFail("Must reject changed budget")
        } catch {}
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testAmbiguousSubmissionIsNeverAutomaticallyRetried() async throws {
        for reply in [MockDetectionTransport.Reply.timeout, .json(503, "temporary error"),
                      .json(200, #"{"unexpected":"shape"}"#), .json(302, "redirect")] {
            let transport = MockDetectionTransport([.json(200, bootstrapJSON), reply])
            let client = MeowDetectionClient(transport: transport)
            let bootstrap = try await client.prepare()
            do {
                _ = try await client.start(input(), reviewedPlan: bootstrap.plan(for: .astra))
                XCTFail("Must report uncertain submission")
            } catch DetectionError.submissionUncertain {} catch { XCTFail("Wrong error: \(error)") }
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testServerErrorsDoNotEchoSecretResponse() async throws {
        let secret = "pretend-secret-do-not-display"
        let transport = MockDetectionTransport([.json(200, bootstrapJSON),
            .json(403, "{\"error\":{\"code\":\"\(secret)\",\"message\":\"\(secret)\"}}")])
        let client = MeowDetectionClient(transport: transport)
        let bootstrap = try await client.prepare()
        do {
            _ = try await client.start(input(), reviewedPlan: bootstrap.plan(for: .astra))
            XCTFail("Must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains(secret)) }
    }

    func testReportDecodingAndConservativeVerdicts() throws {
        let json = #"{"id":"run","status":"complete","planned":20,"completed":20,"valid":20,"fingerprint":{"color":"green","matches":{"gpt-6-astra":0.97},"quality_status":"sufficient","partial":false}}"#
        let good = try JSONDecoder().decode(DetectionReport.self, from: Data(json.utf8))
        XCTAssertTrue(good.isTerminal)
        XCTAssertEqual(good.verdictColor, "green")
        for source in [json.replacingOccurrences(of: "\"partial\":false", with: "\"partial\":true"),
                       json.replacingOccurrences(of: "sufficient", with: "cell_samples_incomplete"),
                       json.replacingOccurrences(of: "\"valid\":20", with: "\"valid\":0"),
                       json.replacingOccurrences(of: "\"status\":\"complete\"", with: "\"status\":\"interrupted\"")] {
            let uncertain = try JSONDecoder().decode(DetectionReport.self, from: Data(source.utf8))
            XCTAssertEqual(uncertain.verdictColor, "yellow")
        }
    }

    func testPollingAndStopUseSameRunWithoutKeyResubmission() async throws {
        let reportJSON = #"{"id":"run_123","status":"cancelled","planned":20,"completed":5,"valid":3}"#
        let transport = MockDetectionTransport([.json(200, bootstrapJSON), .json(200, "{}"), .json(200, reportJSON)])
        let client = MeowDetectionClient(transport: transport)
        _ = try await client.prepare()
        try await client.stop(id: "run_123")
        let report = try await client.report(id: "run_123")
        XCTAssertEqual(report.status, "cancelled")
        let requests = await transport.captured()
        XCTAssertEqual(requests[1].url?.path, "/api/runs/run_123/stop")
        XCTAssertEqual(requests[1].httpBody, Data("{}".utf8))
        XCTAssertEqual(requests[2].url?.path, "/api/reports/run_123")
        XCTAssertNil(requests[2].httpBody)
        XCTAssertFalse(requests.contains { ($0.url?.absoluteString ?? "").contains("dummy-test-key") })
    }

    func testUnsafeReportIDsNeverMakeRequests() async throws {
        let transport = MockDetectionTransport([])
        let client = MeowDetectionClient(transport: transport)
        for id in ["", "../runs", "https://evil.example", "run?key=secret", "run/id", String(repeating: "a", count: 101)] {
            do { _ = try await client.report(id: id); XCTFail("Unsafe id") } catch {}
        }
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationBeforeSubmissionDoesNotSendKey() async throws {
        let transport = MockDetectionTransport([.json(200, bootstrapJSON)])
        let client = MeowDetectionClient(transport: transport, minimumSessionAge: .seconds(10))
        let bootstrap = try await client.prepare()
        let payload = input()
        let task = Task { try await client.start(payload, reviewedPlan: bootstrap.plan(for: .astra)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch is CancellationError {}
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testOptInLiveSessionWithoutCredentials() async throws {
        guard ProcessInfo.processInfo.environment["MEOW_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in: reads public metadata and submits only an empty invalid object; never sends a key.")
        }
        let transport = MeowHTTPTransport()
        let (data, response) = try await transport.send(URLRequest(url: MeowDetectionClient.website.appendingPathComponent("api/bootstrap")))
        XCTAssertEqual(response.statusCode, 200)
        guard response.statusCode == 200 else { return }
        let bootstrap = try JSONDecoder().decode(DetectionBootstrap.self, from: data)
        XCTAssertGreaterThan(try bootstrap.plan(for: .astra).requests, 0)
        try await Task.sleep(for: .milliseconds(2200))
        var request = URLRequest(url: MeowDetectionClient.website.appendingPathComponent("api/runs"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bootstrap.csrf, forHTTPHeaderField: "X-Meow-Token")
        request.setValue("https://meowllm.top", forHTTPHeaderField: "Origin")
        request.setValue(MeowDetectionClient.website.absoluteString, forHTTPHeaderField: "Referer")
        let (rejected, rejection) = try await transport.send(request)
        XCTAssertEqual(rejection.statusCode, 400)
        let object = try JSONSerialization.jsonObject(with: rejected) as? [String: Any]
        let detail = object?["error"] as? [String: Any]
        XCTAssertNotNil(detail?["code"] as? String)
        XCTAssertNotEqual(detail?["code"] as? String, "page_expired")
        XCTAssertNil(object?["id"], "An empty object must never create a detection run")
    }
}
