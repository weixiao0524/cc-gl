import SwiftUI
import CodexConfigCore

enum DetectiveStyle {
    static let teal = Color(red: 0.10, green: 0.43, blue: 0.38)
    static let amber = Color(red: 0.65, green: 0.35, blue: 0.08)
    static func accent(_ scene: InvestigationScene, dark: Bool) -> Color {
        switch scene {
        case .mismatch, .failed, .uncertain: return dark ? Color(red: 1, green: 0.72, blue: 0.41) : amber
        case .inconclusive, .noEvidence, .connectionLost: return dark ? Color(red: 0.72, green: 0.72, blue: 1) : Color(red: 0.39, green: 0.37, blue: 0.63)
        default: return dark ? Color(red: 0.47, green: 0.83, blue: 0.71) : teal
        }
    }

    static func background(dark: Bool) -> Color {
        dark ? Color(red: 0.115, green: 0.15, blue: 0.15) : Color(red: 0.94, green: 0.96, blue: 0.93)
    }
}

/// A native, bounded canvas. Idle scenes and settled endings do not keep a timer alive.
struct DetectiveAnimation: View {
    let scene: InvestigationScene
    var motionDisabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var appPhase
    @State private var playback = DetectivePlayback(scene: .briefing)
    @State private var visible = false

    private struct PlaybackRequest: Equatable {
        let scene: InvestigationScene
        let enabled: Bool
    }

    private var request: PlaybackRequest {
        PlaybackRequest(scene: scene, enabled: visible && !reduceMotion && !motionDisabled && appPhase == .active)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isRunning)) { _ in
            let animated = !reduceMotion && !motionDisabled
            let time = playback.scene == scene ? playback.time(at: ProcessInfo.processInfo.systemUptime) : 0
            DetectiveFrame(scene: scene, time: time, dark: scheme == .dark, motionEnabled: animated)
        }
        .frame(height: 210)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            playback.setRunning(false, at: ProcessInfo.processInfo.systemUptime)
        }
        .task(id: request) {
            if playback.scene != scene { playback.reset(to: scene) }
            let now = ProcessInfo.processInfo.systemUptime
            playback.setRunning(request.enabled, at: now)
            guard playback.isRunning, scene.hasEndingAnimation else { return }
            // Cancellation on backgrounding preserves the remaining foreground playback time.
            let remaining = max(0, DetectivePlayback.endingDuration - playback.time(at: now))
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            playback.setRunning(false, at: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// Shared by live playback and the deterministic native preview renderer.
struct DetectiveFrame: View {
    let scene: InvestigationScene
    let time: TimeInterval
    let dark: Bool
    var motionEnabled = true

    var body: some View {
        Canvas { context, size in
            DetectiveDrawing(scene: scene, time: time, dark: dark, motionEnabled: motionEnabled).draw(in: context, size: size)
        }
        .background(DetectiveStyle.background(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct DetectiveDrawing {
    let scene: InvestigationScene
    let time: Double
    let dark: Bool
    let motionEnabled: Bool
    private var pose: DetectivePose { DetectivePose(scene: scene, time: time, motionEnabled: motionEnabled) }
    private var ink: Color { dark ? Color(red: 0.80, green: 0.85, blue: 0.83) : outline }
    private var paper: Color { dark ? Color(red: 0.23, green: 0.28, blue: 0.27) : .white }
    private var accent: Color { DetectiveStyle.accent(scene, dark: dark) }
    private let outline = Color(red: 0.20, green: 0.25, blue: 0.24)
    private let coat = Color(red: 0.76, green: 0.57, blue: 0.34)
    private let coatLight = Color(red: 0.89, green: 0.73, blue: 0.48)
    private let coatShade = Color(red: 0.63, green: 0.43, blue: 0.25)
    private let fur = Color(red: 0.97, green: 0.87, blue: 0.69)
    private let muzzle = Color(red: 1, green: 0.96, blue: 0.85)
    private let coral = Color(red: 0.87, green: 0.48, blue: 0.42)
    private let scarf = Color(red: 0.16, green: 0.47, blue: 0.43)
    private var pondering: Bool { [.inconclusive, .noEvidence, .uncertain].contains(scene) }

    func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var c = context
        let scale = min(size.width / 600, size.height / 218)
        c.translateBy(x: (size.width - 600 * scale) / 2, y: (size.height - 218 * scale) / 2)
        c.scaleBy(x: scale, y: scale)
        line(&c, [CGPoint(x: 60, y: 199), CGPoint(x: 548, y: 199)], ink.opacity(0.13), 1)
        ellipse(&c, CGRect(x: 185, y: 190, width: 144, height: 13), ink.opacity(0.08))
        ellipse(&c, CGRect(x: 211, y: 193, width: 92, height: 7), ink.opacity(0.07))
        board(&c)
        notebook(&c)

        var character = c
        character.translateBy(x: 254, y: 107 + pose.bodyY)
        character.rotate(by: .degrees(pose.bodyAngle))
        tail(&character)
        body(&character)
        leftArm(&character)
        var head = character
        head.translateBy(x: 0, y: 8)
        head.rotate(by: .degrees(pose.headAngle))
        head.translateBy(x: 0, y: -8)
        face(&head)
        rightArm(&character)
        if pondering { thinkingPaw(&character) }
        ending(&c)
    }

    private func board(_ c: inout GraphicsContext) {
        rounded(&c, CGRect(x: 381, y: 40, width: 164, height: 140), 9, .black.opacity(dark ? 0.14 : 0.035))
        rounded(&c, CGRect(x: 379, y: 35, width: 164, height: 140), 8, dark ? Color(red: 0.20, green: 0.25, blue: 0.24) : Color(red: 0.83, green: 0.88, blue: 0.82))
        rounded(&c, CGRect(x: 386, y: 42, width: 150, height: 126), 4, dark ? Color(red: 0.15, green: 0.19, blue: 0.18) : Color(red: 0.97, green: 0.98, blue: 0.94))
        for x in stride(from: 398, through: 524, by: 14) {
            for y in stride(from: 70, through: 144, by: 14) {
                ellipse(&c, CGRect(x: CGFloat(x), y: CGFloat(y), width: 1.2, height: 1.2), ink.opacity(0.10))
            }
        }
        text(&c, "线索板", at: CGPoint(x: 461, y: 56), size: 11, color: ink.opacity(0.85))
        line(&c, [CGPoint(x: 426, y: 85), CGPoint(x: 453, y: 112), CGPoint(x: 494, y: 86)], coral.opacity(0.65), 1.4)
        for i in 0..<2 {
            var card = c
            card.translateBy(x: 426 + CGFloat(i) * 66, y: 109)
            card.rotate(by: .degrees(i == 0 ? -8 : 7))
            rounded(&card, CGRect(x: -23, y: -31, width: 47, height: 60), 3, .black.opacity(0.04))
            rounded(&card, CGRect(x: -24, y: -33, width: 47, height: 60), 3, paper)
            symbol(&card, i == 0 ? "touchid" : "text.bubble", at: CGPoint(x: 0, y: -7), size: 22, color: accent.opacity(0.8))
            line(&card, [CGPoint(x: -13, y: 12), CGPoint(x: 11, y: 12)], ink.opacity(0.22), 2)
            line(&card, [CGPoint(x: -13, y: 18), CGPoint(x: 4, y: 18)], ink.opacity(0.13), 2)
            ellipse(&card, CGRect(x: -3, y: -37, width: 7, height: 7), coral)
            ellipse(&card, CGRect(x: -2, y: -36, width: 2, height: 2), .white.opacity(0.6))
        }
        if scene == .comparing {
            let y = 78 + pose.scan * 49
            rounded(&c, CGRect(x: 396, y: y - 5, width: 128, height: 10), 4, accent.opacity(0.08))
            line(&c, [CGPoint(x: 396, y: y), CGPoint(x: 524, y: y)], accent.opacity(0.5), 1.5)
        }
        let label: String
        switch scene {
        case .match: label = "线索一致"
        case .mismatch: label = "有待核对"
        case .inconclusive, .noEvidence: label = "证据不足"
        case .connectionLost: label = "联络中断"
        case .failed: label = "检查未完成"
        case .uncertain: label = "等待确认"
        case .stopping: label = "等待收工确认"
        case .stopped: label = "本次收工"
        default: label = "留意每一条线索"
        }
        text(&c, label, at: CGPoint(x: 461, y: 155), size: 10, color: ink.opacity(0.8))
    }

    private func notebook(_ c: inout GraphicsContext) {
        var f = c
        f.translateBy(x: 120, y: 135)
        f.rotate(by: .degrees(-9))
        rounded(&f, CGRect(x: -35, y: -22, width: 65, height: 77), 5, outline.opacity(0.07))
        rounded(&f, CGRect(x: -37, y: -26, width: 65, height: 77), 4, dark ? scarf : Color(red: 0.60, green: 0.75, blue: 0.71))
        rounded(&f, CGRect(x: -30, y: -33, width: 53, height: 74), 3, paper)
        symbol(&f, scene == .noEvidence ? "questionmark" : "doc.text.magnifyingglass", at: CGPoint(x: -3, y: -12), size: 22, color: ink.opacity(0.55))
        let closed = pose.folderClosed
        rounded(&f, CGRect(x: -37, y: 2 - 28 * closed, width: 69, height: 49 + 28 * closed), 4, scarf)
        rounded(&f, CGRect(x: -37, y: 5 - 28 * closed, width: 5, height: 42 + 28 * closed), 2, .black.opacity(0.12))
        line(&f, [CGPoint(x: 19, y: 4 - 28 * closed), CGPoint(x: 19, y: 49)], muzzle.opacity(0.20), 1)
        text(&f, "调查笔记", at: CGPoint(x: -5, y: 23 - 8 * closed), size: 10, color: .white.opacity(0.92))
        line(&f, [CGPoint(x: -17, y: 34 - 8 * closed), CGPoint(x: 6, y: 34 - 8 * closed)], .white.opacity(0.35), 1)
        var pencil = c
        pencil.translateBy(x: 164, y: 145)
        pencil.rotate(by: .degrees(15))
        line(&pencil, [CGPoint(x: 0, y: -17), CGPoint(x: 0, y: 29)], coatLight, 5)
        line(&pencil, [CGPoint(x: 0, y: -19), CGPoint(x: 0, y: -15)], coral, 5)
        polygon(&pencil, [CGPoint(x: -2.5, y: 31), CGPoint(x: 2.5, y: 31), CGPoint(x: 0, y: 38)], outline)
    }

    private func tail(_ c: inout GraphicsContext) {
        var t = c
        t.translateBy(x: -24, y: 63)
        t.rotate(by: .degrees(pose.tailAngle))
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: -37, y: -29), control1: CGPoint(x: -47, y: 18), control2: CGPoint(x: -64, y: -20))
        stroke(&t, path, outline, 13)
        stroke(&t, path, fur, 9)
        var tip = Path()
        tip.move(to: CGPoint(x: -48, y: -23))
        tip.addQuadCurve(to: CGPoint(x: -37, y: -29), control: CGPoint(x: -43, y: -29))
        stroke(&t, tip, coat, 8)
    }

    private func body(_ c: inout GraphicsContext) {
        for side in [-1.0, 1.0] {
            var boot = c
            boot.translateBy(x: side * 19, y: 81 + side * pose.stride)
            rounded(&boot, CGRect(x: -13, y: -3, width: 27, height: 13), 6, outline)
            line(&boot, [CGPoint(x: -8, y: 6), CGPoint(x: 8, y: 6)], .white.opacity(0.15), 1.5)
        }
        var coatPath = Path()
        coatPath.move(to: CGPoint(x: -25, y: 14))
        coatPath.addQuadCurve(to: CGPoint(x: 26, y: 14), control: CGPoint(x: 0, y: 6))
        coatPath.addCurve(to: CGPoint(x: 36, y: 78), control1: CGPoint(x: 31, y: 28), control2: CGPoint(x: 29, y: 62))
        coatPath.addQuadCurve(to: CGPoint(x: -36, y: 78), control: CGPoint(x: 0, y: 90))
        coatPath.addQuadCurve(to: CGPoint(x: -25, y: 14), control: CGPoint(x: -31, y: 37))
        coatPath.closeSubpath()
        shaded(&c, coatPath, coatLight, coat, from: CGPoint(x: -22, y: 15), to: CGPoint(x: 27, y: 85))
        stroke(&c, coatPath, outline, 1.8)
        polygon(&c, [CGPoint(x: -23, y: 17), CGPoint(x: -8, y: 12), CGPoint(x: 0, y: 29), CGPoint(x: -9, y: 44), CGPoint(x: -24, y: 27), CGPoint(x: -18, y: 25)], coatLight, border: coatShade)
        polygon(&c, [CGPoint(x: 22, y: 17), CGPoint(x: 8, y: 12), CGPoint(x: 0, y: 29), CGPoint(x: 10, y: 44), CGPoint(x: 23, y: 27), CGPoint(x: 17, y: 25)], coatLight, border: coatShade)
        polygon(&c, [CGPoint(x: -9, y: 12), CGPoint(x: 10, y: 12), CGPoint(x: 5, y: 31), CGPoint(x: -4, y: 31)], scarf)
        polygon(&c, [CGPoint(x: 4, y: 20), CGPoint(x: 12, y: 26), CGPoint(x: 9, y: 43), CGPoint(x: 2, y: 38)], scarf)
        line(&c, [CGPoint(x: 0, y: 44), CGPoint(x: 0, y: 79)], coatShade.opacity(0.4), 1)
        line(&c, [CGPoint(x: -30, y: 57), CGPoint(x: 30, y: 57)], coatShade, 6)
        rounded(&c, CGRect(x: -7, y: 51, width: 15, height: 12), 2, coatLight)
        rounded(&c, CGRect(x: -4, y: 54, width: 9, height: 6), 1, coatShade)
        line(&c, [CGPoint(x: -1, y: 57), CGPoint(x: 7, y: 57)], coatLight, 1.5)
        for x in [-10.0, 10.0] {
            for y in [45.0, 70.0] { ellipse(&c, CGRect(x: x - 1.5, y: y, width: 3, height: 3), outline.opacity(0.7)) }
        }
        for side in [-1.0, 1.0] {
            line(&c, [CGPoint(x: side * 18, y: 66), CGPoint(x: side * 28, y: 64)], coatShade.opacity(0.8), 1.5)
        }
    }

    private func sleeve(_ c: inout GraphicsContext, from: CGPoint, elbow: CGPoint, to: CGPoint) {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: elbow)
        stroke(&c, path, outline, 16)
        stroke(&c, path, coat, 12.5)
        ellipse(&c, CGRect(x: to.x - 8, y: to.y - 7, width: 16, height: 15), outline)
        ellipse(&c, CGRect(x: to.x - 6.5, y: to.y - 6, width: 13, height: 12), fur)
    }

    private func leftArm(_ c: inout GraphicsContext) {
        guard !pondering else { return }
        let y = scene == .dispatching ? 44 - pose.stride : 47
        sleeve(&c, from: CGPoint(x: -25, y: 24), elbow: CGPoint(x: -38, y: 39), to: CGPoint(x: -41, y: y))
        if scene == .preparing || scene == .dispatching {
            rounded(&c, CGRect(x: -49, y: y - 1, width: 23, height: 27), 3, scarf)
            line(&c, [CGPoint(x: -44, y: y + 6), CGPoint(x: -32, y: y + 6)], muzzle.opacity(0.8), 1.4)
            ellipse(&c, CGRect(x: -47, y: y - 5, width: 11, height: 9), fur)
        }
    }

    private func thinkingPaw(_ c: inout GraphicsContext) {
        sleeve(&c, from: CGPoint(x: -25, y: 27), elbow: CGPoint(x: -47, y: 38), to: CGPoint(x: -26, y: 5))
        line(&c, [CGPoint(x: -28, y: 2), CGPoint(x: -27, y: 6)], coatShade.opacity(0.5), 1)
    }

    private func face(_ c: inout GraphicsContext) {
        for side in [-1.0, 1.0] {
            polygon(&c, [CGPoint(x: side * 18, y: -39), CGPoint(x: side * 40, y: -64), CGPoint(x: side * 42, y: -22)], fur, border: outline)
            polygon(&c, [CGPoint(x: side * 28, y: -39), CGPoint(x: side * 37, y: -53), CGPoint(x: side * 37, y: -32)], coral.opacity(0.55))
        }
        var head = Path()
        head.move(to: CGPoint(x: -39, y: -32))
        head.addCurve(to: CGPoint(x: 39, y: -32), control1: CGPoint(x: -32, y: -65), control2: CGPoint(x: 33, y: -65))
        head.addCurve(to: CGPoint(x: 31, y: 8), control1: CGPoint(x: 48, y: -17), control2: CGPoint(x: 46, y: 0))
        head.addCurve(to: CGPoint(x: -31, y: 8), control1: CGPoint(x: 17, y: 27), control2: CGPoint(x: -19, y: 27))
        head.addCurve(to: CGPoint(x: -39, y: -32), control1: CGPoint(x: -46, y: 1), control2: CGPoint(x: -48, y: -17))
        head.closeSubpath()
        shaded(&c, head, muzzle, fur, from: CGPoint(x: -18, y: -42), to: CGPoint(x: 21, y: 20))
        stroke(&c, head, outline, 1.8)
        ellipse(&c, CGRect(x: -25, y: -4, width: 50, height: 23), muzzle.opacity(0.85))
        for side in [-1.0, 1.0] {
            ellipse(&c, CGRect(x: side * 28 - 7, y: -4, width: 14, height: 7), coral.opacity(0.33))
            for offset in [0.0, 6.0] {
                line(&c, [CGPoint(x: side * 32, y: 1 + offset), CGPoint(x: side * 46, y: -1 + offset * 1.5)], outline.opacity(0.5), 1.1)
            }
        }
        for x in [-16.0, 16.0] {
            if scene == .match || scene == .stopped {
                var eye = Path()
                eye.move(to: CGPoint(x: x - 5, y: -13))
                eye.addQuadCurve(to: CGPoint(x: x + 5, y: -13), control: CGPoint(x: x, y: -21))
                stroke(&c, eye, outline, 2.5)
            } else {
                let height = 10 * pose.eyeOpen
                ellipse(&c, CGRect(x: x - 4 + pose.gazeX, y: -16 + pose.gazeY - height / 2, width: 7.5, height: height), outline)
                if pose.eyeOpen > 0.6 {
                    ellipse(&c, CGRect(x: x - 1.7 + pose.gazeX, y: -19 + pose.gazeY, width: 2.2, height: 2.5), muzzle)
                }
            }
        }
        if scene == .mismatch || pondering || scene == .failed {
            line(&c, [CGPoint(x: -21, y: -29), CGPoint(x: -12, y: -31)], outline.opacity(0.65), 1.8)
            line(&c, [CGPoint(x: 12, y: -29), CGPoint(x: 21, y: -26)], outline.opacity(0.65), 1.8)
        }
        polygon(&c, [CGPoint(x: -4, y: -4), CGPoint(x: 4, y: -4), CGPoint(x: 0, y: 0)], coatShade)
        line(&c, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 4)], outline, 1.5)
        var mouth = Path()
        mouth.move(to: CGPoint(x: -7, y: 5))
        mouth.addQuadCurve(to: CGPoint(x: 0, y: 4), control: CGPoint(x: -3, y: 10))
        mouth.addQuadCurve(to: CGPoint(x: 7, y: 5), control: CGPoint(x: 3, y: 10))
        stroke(&c, mouth, outline, 1.5)
        hat(&c)
    }

    private func hat(_ c: inout GraphicsContext) {
        ellipse(&c, CGRect(x: -37, y: -48, width: 77, height: 10), outline.opacity(0.12))
        var crown = Path()
        crown.move(to: CGPoint(x: -36, y: -49))
        crown.addCurve(to: CGPoint(x: 36, y: -49), control1: CGPoint(x: -32, y: -93), control2: CGPoint(x: 25, y: -95))
        crown.closeSubpath()
        shaded(&c, crown, coatLight, coat, from: CGPoint(x: -22, y: -81), to: CGPoint(x: 27, y: -48))
        stroke(&c, crown, outline, 1.8)
        var fabric = c
        fabric.clip(to: crown)
        for x in stride(from: -40, through: 40, by: 10) {
            line(&fabric, [CGPoint(x: x, y: -91), CGPoint(x: x + 11, y: -44)], coatShade.opacity(0.15), 1)
        }
        for y in stride(from: -82, through: -48, by: 9) {
            line(&fabric, [CGPoint(x: -36, y: y), CGPoint(x: 36, y: y)], coatShade.opacity(0.14), 1)
        }
        var seam = Path()
        seam.move(to: CGPoint(x: -2, y: -81))
        seam.addQuadCurve(to: CGPoint(x: 7, y: -49), control: CGPoint(x: 7, y: -72))
        stroke(&c, seam, coatShade.opacity(0.6), 1.4)
        ellipse(&c, CGRect(x: -6, y: -85, width: 10, height: 5), coatShade)
        var brim = Path()
        brim.move(to: CGPoint(x: -36, y: -52))
        brim.addQuadCurve(to: CGPoint(x: 38, y: -52), control: CGPoint(x: 0, y: -49))
        brim.addCurve(to: CGPoint(x: 49, y: -42), control1: CGPoint(x: 57, y: -57), control2: CGPoint(x: 59, y: -45))
        brim.addQuadCurve(to: CGPoint(x: -47, y: -42), control: CGPoint(x: 0, y: -31))
        brim.addCurve(to: CGPoint(x: -36, y: -52), control1: CGPoint(x: -59, y: -45), control2: CGPoint(x: -53, y: -55))
        brim.closeSubpath()
        shaded(&c, brim, coatLight, coat, from: CGPoint(x: 0, y: -53), to: CGPoint(x: 0, y: -37))
        stroke(&c, brim, outline, 1.6)
    }

    private func rightArm(_ c: inout GraphicsContext) {
        if [.connectionLost, .failed, .uncertain].contains(scene) {
            sleeve(&c, from: CGPoint(x: 27, y: 25), elbow: CGPoint(x: 39, y: 38), to: CGPoint(x: 51, y: 19))
            var radio = c
            radio.translateBy(x: 52, y: 10)
            radio.rotate(by: .degrees(-8))
            rounded(&radio, CGRect(x: -10, y: -18, width: 24, height: 38), 5, outline)
            line(&radio, [CGPoint(x: -5, y: -18), CGPoint(x: -5, y: -31)], outline, 3)
            rounded(&radio, CGRect(x: -6, y: -12, width: 16, height: 15), 2, dark ? paper : Color(red: 0.75, green: 0.86, blue: 0.79))
            symbol(&radio, scene == .uncertain ? "questionmark" : "wifi.slash", at: CGPoint(x: 2, y: -4), size: 10, color: dark ? ink : outline)
            for y in [9.0, 13.0] { line(&radio, [CGPoint(x: -4, y: y), CGPoint(x: 7, y: y)], muzzle.opacity(0.45), 1.3) }
            ellipse(&c, CGRect(x: 42, y: 17, width: 13, height: 12), fur)
        } else if [.stopping, .stopped].contains(scene) {
            sleeve(&c, from: CGPoint(x: 27, y: 25), elbow: CGPoint(x: 43, y: 43), to: CGPoint(x: 47, y: 55))
            let handle = Path(roundedRect: CGRect(x: 39, y: 53, width: 19, height: 13), cornerRadius: 4)
            stroke(&c, handle, outline, 3)
            rounded(&c, CGRect(x: 26, y: 61, width: 47, height: 28), 5, scarf)
            line(&c, [CGPoint(x: 29, y: 71), CGPoint(x: 70, y: 71)], outline.opacity(0.4), 1.5)
            rounded(&c, CGRect(x: 46, y: 68, width: 7, height: 7), 1, coatLight)
        } else {
            let hand = pose.hand
            sleeve(&c, from: CGPoint(x: 27, y: 25), elbow: CGPoint(x: 36, y: 40), to: hand)
            var glass = c
            glass.translateBy(x: hand.x, y: hand.y)
            glass.rotate(by: .degrees(pose.lensAngle))
            line(&glass, [CGPoint(x: 0, y: 9), CGPoint(x: 0, y: -21)], outline, 9)
            line(&glass, [CGPoint(x: -1.5, y: 7), CGPoint(x: -1.5, y: -15)], coatShade, 3)
            line(&glass, [CGPoint(x: 0, y: -18), CGPoint(x: 0, y: -23)], coatLight, 7)
            let lens = Path(ellipseIn: CGRect(x: -25, y: -67, width: 50, height: 50))
            shaded(&glass, lens, .white.opacity(dark ? 0.17 : 0.80), Color(red: 0.49, green: 0.77, blue: 0.77).opacity(0.22), from: CGPoint(x: -18, y: -64), to: CGPoint(x: 20, y: -18))
            stroke(&glass, lens, outline, 5)
            stroke(&glass, Path(ellipseIn: CGRect(x: -22, y: -64, width: 44, height: 44)), dark ? coatLight.opacity(0.75) : scarf.opacity(0.45), 1)
            var shine = Path()
            shine.move(to: CGPoint(x: -15, y: -39))
            shine.addQuadCurve(to: CGPoint(x: -6, y: -58), control: CGPoint(x: -19, y: -52))
            stroke(&glass, shine, .white.opacity(0.85), 3.5)
            ellipse(&glass, CGRect(x: 9, y: -32, width: 4, height: 4), .white.opacity(0.55))
            ellipse(&c, CGRect(x: hand.x - 7, y: hand.y - 5, width: 15, height: 12), fur)
            line(&c, [CGPoint(x: hand.x + 1, y: hand.y - 2), CGPoint(x: hand.x + 3, y: hand.y + 1)], coatShade.opacity(0.45), 1)
        }
    }

    private func ending(_ c: inout GraphicsContext) {
        guard scene.hasEndingAnimation else { return }
        let p = pose.reveal
        var badge = c
        badge.opacity = p
        badge.translateBy(x: 337, y: 36 + (1 - p) * 8)
        let pop = 0.8 + 0.2 * p + sin(p * .pi) * 0.12
        badge.scaleBy(x: pop, y: pop)
        ellipse(&badge, CGRect(x: -22, y: -21, width: 44, height: 44), .black.opacity(0.05))
        ellipse(&badge, CGRect(x: -22, y: -23, width: 44, height: 44), paper)
        stroke(&badge, Path(ellipseIn: CGRect(x: -22, y: -23, width: 44, height: 44)), accent.opacity(0.2), 1)
        symbol(&badge, scene.symbol, at: CGPoint(x: 0, y: -1), size: 24, color: accent)
        if scene == .match {
            for i in 0..<3 {
                let angle = [-2.2, -0.35, 0.8][i]
                let distance = 30 + 6 * p
                let center = CGPoint(x: 337 + cos(angle) * distance, y: 36 + sin(angle) * distance)
                symbol(&c, "sparkle", at: center, size: i == 1 ? 10 : 7, color: accent.opacity(p * 0.7))
            }
        }
    }

    private func rounded(_ c: inout GraphicsContext, _ rect: CGRect, _ radius: CGFloat, _ color: Color) {
        c.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
    }
    private func ellipse(_ c: inout GraphicsContext, _ rect: CGRect, _ color: Color) {
        c.fill(Path(ellipseIn: rect), with: .color(color))
    }
    private func stroke(_ c: inout GraphicsContext, _ path: Path, _ color: Color, _ width: CGFloat) {
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func line(_ c: inout GraphicsContext, _ points: [CGPoint], _ color: Color, _ width: CGFloat) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        stroke(&c, path, color, width)
    }
    private func polygon(_ c: inout GraphicsContext, _ points: [CGPoint], _ color: Color, border: Color? = nil) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        c.fill(path, with: .color(color))
        if let border { stroke(&c, path, border, 1.5) }
    }
    private func shaded(_ c: inout GraphicsContext, _ path: Path, _ top: Color, _ bottom: Color, from: CGPoint, to: CGPoint) {
        c.fill(path, with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: from, endPoint: to))
    }
    private func text(_ c: inout GraphicsContext, _ value: String, at: CGPoint, size: CGFloat, color: Color) {
        c.draw(Text(value).font(.system(size: size, weight: .medium, design: .rounded)).foregroundColor(color), at: at)
    }
    private func symbol(_ c: inout GraphicsContext, _ value: String, at: CGPoint, size: CGFloat, color: Color) {
        c.draw(Text(Image(systemName: value)).font(.system(size: size, weight: .semibold)).foregroundColor(color), at: at)
    }
}
