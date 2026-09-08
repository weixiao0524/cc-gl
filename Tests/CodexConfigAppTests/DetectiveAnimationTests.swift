import XCTest
import SwiftUI
import AppKit
import CodexConfigCore
@testable import CodexConfigApp

final class DetectiveAnimationTests: XCTestCase {
    func testLensRemainsAttachedThroughoutSearch() {
        for time in stride(from: 0.0, through: 12, by: 1.0 / 30) {
            let pose = DetectivePose(scene: .searching, time: time)
            XCTAssertEqual(hypot(pose.lens.x - pose.hand.x, pose.lens.y - pose.hand.y), 42, accuracy: 0.001)
            XCTAssertTrue((300...365).contains(254 + pose.lens.x))
        }
    }

    func testReducedMotionUsesStableOpenEyedPoses() {
        for scene in InvestigationScene.allCases {
            let pose = DetectivePose(scene: scene, time: 0, motionEnabled: false)
            XCTAssertEqual(pose, DetectivePose(scene: scene, time: 99, motionEnabled: false), scene.rawValue)
            XCTAssertEqual(pose.eyeOpen, 1)
            XCTAssertEqual(pose.bodyY, 0)
            if scene.hasEndingAnimation { XCTAssertEqual(pose.reveal, 1) }
        }
    }

    func testResultsHaveNoResidualMotion() {
        for scene in InvestigationScene.allCases where scene.hasEndingAnimation {
            XCTAssertEqual(DetectivePose(scene: scene, time: 2.6), DetectivePose(scene: scene, time: 99), scene.rawValue)
        }
    }

    func testWorkingPosesMoveAndBlinkWithoutAbruptJumps() {
        for scene in [InvestigationScene.searching, .comparing, .dispatching] {
            XCTAssertNotEqual(DetectivePose(scene: scene, time: 0), DetectivePose(scene: scene, time: 1))
        }
        XCTAssertLessThan(DetectivePose(scene: .searching, time: 4.5).eyeOpen, 0.1)
        for time in stride(from: 0.0, through: 6, by: 1.0 / 30) {
            let a = DetectivePose(scene: .searching, time: time)
            let b = DetectivePose(scene: .searching, time: time + 1.0 / 30)
            XCTAssertLessThan(hypot(a.lens.x - b.lens.x, a.lens.y - b.lens.y), 1.5)
        }
    }

    func testRepeatedBackgroundEventsPreserveRemainingEnding() {
        var clock = DetectivePlayback(scene: .match)
        clock.setRunning(true, at: 100)
        clock.setRunning(false, at: 101)
        clock.setRunning(false, at: 110)
        XCTAssertEqual(clock.time(at: 120), 1)
        clock.setRunning(true, at: 150)
        XCTAssertEqual(clock.time(at: 151), 2)
        clock.setRunning(false, at: 152)
        XCTAssertEqual(clock.time(at: 999), 2.6)
        clock.setRunning(true, at: 1000)
        XCTAssertFalse(clock.isRunning)
    }

    func testSceneResetDoesNotInheritPreviousResultClock() {
        var clock = DetectivePlayback(scene: .match)
        clock.setRunning(true, at: 100)
        clock.setRunning(false, at: 103)
        clock.reset(to: .mismatch)
        XCTAssertEqual(clock.time(at: 200), 0)
        clock.setRunning(true, at: 200)
        XCTAssertTrue(clock.isRunning)
        clock.reset(to: .briefing)
        clock.setRunning(true, at: 210)
        XCTAssertFalse(clock.isRunning)
    }

    func testLoopResumesWithoutCountingBackgroundTime() {
        var clock = DetectivePlayback(scene: .searching)
        clock.setRunning(true, at: 100)
        clock.setRunning(false, at: 104)
        clock.setRunning(true, at: 200)
        XCTAssertEqual(clock.time(at: 202), 6)
    }

    @MainActor
    func testNativeFramesRenderInBothAppearancesAndNarrowWidths() throws {
        for dark in [false, true] {
            for width in [320.0, 602.0] {
                for scene in InvestigationScene.allCases {
                    let image = try render(scene, time: 2.6, dark: dark, width: width)
                    XCTAssertEqual(image.width, Int(width))
                    XCTAssertEqual(image.height, 210)
                    // A flat/blank canvas has very few colors; sample the actual rendered pixels.
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    var colors = Set<String>()
                    for x in stride(from: 10, to: image.width - 10, by: 7) {
                        for y in stride(from: 10, to: image.height - 10, by: 7) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                            }
                        }
                    }
                    XCTAssertGreaterThan(colors.count, 45, "Blank frame: \(scene), dark=\(dark), width=\(width)")
                }
            }
        }
    }

    @MainActor
    func testRenderedMotionChangesPixelsButReducedMotionDoesNot() throws {
        let first = try png(render(.searching, time: 0))
        XCTAssertNotEqual(first, try png(render(.searching, time: 1)))
        XCTAssertEqual(try png(render(.searching, time: 0, motion: false)), try png(render(.searching, time: 5, motion: false)))
        XCTAssertEqual(try png(render(.match, time: 2.6)), try png(render(.match, time: 20)))
    }

    @MainActor
    func testExportReviewFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["DETECTIVE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set DETECTIVE_SNAPSHOT_DIR to export native review frames.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for scene in InvestigationScene.allCases {
                let image = try render(scene, time: 2.6, dark: dark)
                try png(image).write(to: directory.appendingPathComponent("\(scene.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        for frame in 0..<90 {
            let image = try render(.searching, time: Double(frame) / 30)
            try png(image).write(to: directory.appendingPathComponent(String(format: "search-%03d.png", frame)))
        }
    }

    @MainActor
    private func render(_ scene: InvestigationScene, time: Double, dark: Bool = false, width: Double = 602, motion: Bool = true) throws -> CGImage {
        let renderer = ImageRenderer(content: DetectiveFrame(scene: scene, time: time, dark: dark, motionEnabled: motion)
            .frame(width: width, height: 210)
            .environment(\.colorScheme, dark ? .dark : .light))
        return try XCTUnwrap(renderer.cgImage)
    }

    private func png(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
