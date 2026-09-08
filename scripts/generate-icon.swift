import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(size: Int, to url: URL) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    NSColor(calibratedRed: 0.10, green: 0.39, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194).fill()
    NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
    NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816), xRadius: 172, yRadius: 172).fill()
    for (y, knob) in [(CGFloat(700), CGFloat(390)), (CGFloat(512), CGFloat(634)), (CGFloat(324), CGFloat(455))] {
        NSColor(calibratedWhite: 1, alpha: 0.60).setFill()
        NSBezierPath(roundedRect: NSRect(x: 256, y: y - 14, width: 512, height: 28), xRadius: 14, yRadius: 14).fill()
        NSColor(calibratedRed: 0.10, green: 0.39, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: knob - 70, y: y - 70, width: 140, height: 140)).fill()
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: knob - 48, y: y - 48, width: 96, height: 96)).fill()
    }
    image.unlockFocus()
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("Cannot render icon") }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        try drawIcon(size: points * factor, to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
