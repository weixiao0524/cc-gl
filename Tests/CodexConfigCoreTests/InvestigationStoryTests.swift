import XCTest
@testable import CodexConfigCore

final class InvestigationStoryTests: XCTestCase {
    private func report(status: String = "complete", color: String = "green", valid: Int = 20,
                        completed: Int = 20, partial: Bool = false, quality: String = "sufficient") throws -> DetectionReport {
        let object: [String: Any] = ["id": "demo", "status": status, "planned": 20, "completed": completed,
            "valid": valid, "fingerprint": ["color": color, "matches": [:], "partial": partial, "quality_status": quality]]
        return try JSONDecoder().decode(DetectionReport.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPreparationStatesDoNotImplyAnyVerdict() {
        XCTAssertEqual(InvestigationScene(phase: .connecting, report: nil), .preparing)
        XCTAssertEqual(InvestigationScene(phase: .ready, report: nil), .briefing)
        XCTAssertEqual(InvestigationScene(phase: .submitting, report: nil), .dispatching)
    }

    func testInvestigationProgressComesOnlyFromReports() throws {
        XCTAssertEqual(InvestigationScene(phase: .running, report: nil), .searching)
        XCTAssertEqual(InvestigationScene(phase: .running, report: try report(status: "running", completed: 6)), .searching)
        XCTAssertEqual(InvestigationScene(phase: .running, report: try report(status: "running", completed: 12)), .comparing)
        // Even 100% response collection is not a final verdict until the server finishes.
        XCTAssertEqual(InvestigationScene(phase: .running, report: try report(status: "running")), .comparing)
        XCTAssertEqual(InvestigationScene.progress(try report(completed: 8)), 0.4)
    }

    func testThreeDifferentResultStories() throws {
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report()), .match)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(color: "red")), .mismatch)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(color: "yellow")), .inconclusive)
    }

    func testInsufficientEvidenceNeverGetsSuccessAnimation() throws {
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(partial: true)), .inconclusive)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(quality: "cell_samples_incomplete")), .inconclusive)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(valid: 0)), .noEvidence)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: nil), .failed)
    }

    func testFailureAndCancellationDoNotMeanFakeModel() throws {
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(status: "error")), .failed)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(status: "interrupted")), .failed)
        XCTAssertEqual(InvestigationScene(phase: .finished, report: try report(status: "cancelled")), .stopped)
        XCTAssertEqual(InvestigationScene(phase: .failed, report: nil), .failed)
    }

    func testRemoteUncertaintyOverridesStalePositiveReport() throws {
        let old = try report()
        XCTAssertEqual(InvestigationScene(phase: .paused, report: old), .connectionLost)
        XCTAssertEqual(InvestigationScene(phase: .uncertain, report: old), .uncertain)
        XCTAssertEqual(InvestigationScene(phase: .stopping, report: old), .stopping)
    }

    func testOnlyActiveWorkLoops() {
        for scene in InvestigationScene.allCases {
            XCTAssertFalse(scene.loops && scene.hasEndingAnimation, scene.rawValue)
        }
        XCTAssertFalse(InvestigationScene.briefing.loops)
        XCTAssertFalse(InvestigationScene.match.loops)
        XCTAssertFalse(InvestigationScene.connectionLost.loops)
        XCTAssertTrue(InvestigationScene.searching.loops)
        XCTAssertTrue(InvestigationScene.comparing.loops)
    }

    func testPlainLanguageRetainsImportantLimits() {
        XCTAssertTrue(InvestigationScene.match.explanation.contains("不是百分百"))
        XCTAssertTrue(InvestigationScene.mismatch.explanation.contains("不要仅凭"))
        XCTAssertTrue(InvestigationScene.inconclusive.explanation.contains("不等于"))
        XCTAssertTrue(InvestigationScene.connectionLost.explanation.contains("不会再开一单"))
        XCTAssertTrue(InvestigationScene.stopping.explanation.contains("费用仍可能继续"))
        XCTAssertTrue(InvestigationScene.uncertain.explanation.contains("不要立即重复提交"))
    }
}
