import Foundation
import CodexConfigCore

/// Monotonic playback time. Repeated inactive notifications must not overwrite the pause point.
struct DetectivePlayback {
    static let endingDuration = 2.6
    private(set) var scene: InvestigationScene
    private(set) var accumulated: TimeInterval = 0
    private(set) var resumedAt: TimeInterval?

    var isRunning: Bool { resumedAt != nil }

    func time(at now: TimeInterval) -> TimeInterval {
        let elapsed = accumulated + (resumedAt.map { max(0, now - $0) } ?? 0)
        return scene.loops ? elapsed : min(Self.endingDuration, elapsed)
    }

    mutating func reset(to scene: InvestigationScene) {
        self.scene = scene
        accumulated = 0
        resumedAt = nil
    }

    mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        if running {
            guard resumedAt == nil, scene.loops || (scene.hasEndingAnimation && accumulated < Self.endingDuration) else { return }
            resumedAt = now
        } else if resumedAt != nil {
            accumulated = time(at: now)
            resumedAt = nil
        }
    }
}

/// One deterministic pose drives the gaze, sleeve, paw and lens so held tools never detach.
struct DetectivePose: Equatable {
    let bodyY: Double
    let bodyAngle: Double
    let headAngle: Double
    let gazeX: Double
    let gazeY: Double
    let eyeOpen: Double
    let tailAngle: Double
    let stride: Double
    let hand: CGPoint
    let lensAngle: Double
    let reveal: Double
    let scan: Double
    let folderClosed: Double

    var lens: CGPoint {
        let angle = lensAngle * .pi / 180
        return CGPoint(x: hand.x + sin(angle) * 42, y: hand.y - cos(angle) * 42)
    }

    init(scene: InvestigationScene, time: TimeInterval, motionEnabled: Bool = true) {
        let elapsed = time.isFinite ? max(0, time) : 0
        let t = motionEnabled ? (scene.loops ? elapsed : min(DetectivePlayback.endingDuration, elapsed)) : DetectivePlayback.endingDuration
        let looping = scene.loops && motionEnabled
        let settle = Self.ease(t / 0.75)
        let transient = motionEnabled && scene.hasEndingAnimation ? pow(max(0, 1 - t / 1.8), 2) : 0
        let search = looping && scene == .searching ? sin(t * 1.65) : 0
        let compare = looping && scene == .comparing ? sin(t * 1.4) : 0
        let walking = looping && scene == .dispatching
        let pondering = [.inconclusive, .noEvidence, .uncertain].contains(scene)

        stride = walking ? sin(t * 5.2) * 4 : 0
        bodyY = walking ? -abs(sin(t * 5.2)) * 2 : looping ? sin(t * 2.1) * 0.8 : 0
        bodyAngle = walking ? sin(t * 2.6) * 1.2 : search * 1.2
        headAngle = pondering ? -9 * settle : scene == .mismatch ? -7 * settle + sin(t * 8) * transient * 3 :
            scene == .match ? sin(t * 8) * transient * 8 : search * 3 + compare * 2
        gazeX = pondering ? -1.5 : [.connectionLost, .failed, .uncertain].contains(scene) ? 2 : 1.5 + search * 1.8 + compare * 2
        gazeY = pondering ? -1 : scene == .searching ? 0.8 : 0
        // Smooth eyelid closure, with an occasional second blink, only while work is active.
        let cycle = t.truncatingRemainder(dividingBy: 5.8)
        let blink = max(Self.blink(cycle, center: 4.5), Self.blink(cycle, center: 4.86) * 0.8)
        eyeOpen = looping ? 1 - blink * 0.94 : 1
        tailAngle = looping ? sin(t * 1.8 - 0.7) * 5 : pondering ? -7 * settle : 0
        let lowered = scene == .match ? 17 * settle : [.stopping, .stopped].contains(scene) ? 24 * settle : 0
        hand = CGPoint(x: 48 + search * 7 + compare * 3, y: 20 + lowered + search * 4)
        lensAngle = 24 + search * 12 - compare * 7
        reveal = Self.ease((t - 0.16) / 0.5)
        scan = looping ? (sin(t * 1.4) + 1) / 2 : 0.5
        folderClosed = [.stopping, .stopped].contains(scene) ? Self.ease(t / 0.65) : 0
    }

    static func ease(_ value: Double) -> Double {
        let p = min(1, max(0, value))
        return p * p * (3 - 2 * p)
    }

    private static func blink(_ time: Double, center: Double) -> Double {
        let distance = abs(time - center) / 0.13
        return distance < 1 ? (1 + cos(distance * .pi)) / 2 : 0
    }
}
