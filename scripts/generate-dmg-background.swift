import AppKit

// Draws the DMG window background at 1x and 2x. Layout constants must match the Finder script in
// build-app.sh: a 660×400 window with the app icon centred at (170, 200) and Applications at (490, 200).
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let width: CGFloat = 660, height: CGFloat = 400
let iconY: CGFloat = 200, leftX: CGFloat = 170, rightX: CGFloat = 490
let teal = NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.38, alpha: 1)

func centered(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let lineHeight = string.size().height
    string.draw(in: NSRect(x: 0, y: height - top - lineHeight, width: width, height: lineHeight))
}

func draw(scale: CGFloat, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Light mint ground, matching the detective panel.
    NSGradient(starting: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.96, alpha: 1),
               ending: NSColor(calibratedRed: 0.89, green: 0.94, blue: 0.91, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Soft discs behind the two icon slots.
    for x in [leftX, rightX] {
        NSColor(calibratedWhite: 1, alpha: 0.65).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 78, y: height - iconY - 78, width: 156, height: 156)).fill()
    }

    // Dashed arrow from the app to Applications.
    let y = height - iconY
    let line = NSBezierPath()
    line.move(to: NSPoint(x: leftX + 92, y: y))
    line.line(to: NSPoint(x: rightX - 104, y: y))
    line.lineWidth = 4
    line.lineCapStyle = .round
    line.setLineDash([2, 11], count: 2, phase: 0)
    teal.withAlphaComponent(0.75).setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: rightX - 112, y: y + 13))
    head.line(to: NSPoint(x: rightX - 96, y: y))
    head.line(to: NSPoint(x: rightX - 112, y: y - 13))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    centered("Codex 配置", size: 26, weight: .bold, color: teal, top: 34)
    centered("将左侧应用拖到「应用程序」文件夹即可完成安装", size: 13, weight: .regular,
             color: NSColor(calibratedWhite: 0.30, alpha: 1), top: 74)
    centered("首次打开若被系统拦截：在「应用程序」中右键点按 CodexConfig，选择「打开」", size: 11, weight: .regular,
             color: NSColor(calibratedWhite: 0.42, alpha: 1), top: 352)

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

try draw(scale: 1, to: directory.appendingPathComponent("background.png"))
try draw(scale: 2, to: directory.appendingPathComponent("background@2x.png"))
