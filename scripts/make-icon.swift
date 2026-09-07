import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(red: 0.09, green: 0.13, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 210, yRadius: 210).fill()
    NSColor(red: 0.36, green: 0.79, blue: 0.61, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 195, y: 220, width: 305, height: 584), xRadius: 40, yRadius: 40).fill()
    NSColor(red: 0.24, green: 0.43, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 535, y: 529, width: 294, height: 275), xRadius: 40, yRadius: 40).fill()
    NSColor(red: 0.20, green: 0.33, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 535, y: 220, width: 294, height: 274), xRadius: 40, yRadius: 40).fill()
    NSColor(red: 0.09, green: 0.20, blue: 0.15, alpha: 1).setStroke()
    let chevron = NSBezierPath(); chevron.lineWidth = 26; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 268, y: 609)); chevron.line(to: NSPoint(x: 327, y: 555)); chevron.line(to: NSPoint(x: 268, y: 501)); chevron.stroke()
    let line = NSBezierPath(); line.lineWidth = 26; line.lineCapStyle = .round
    line.move(to: NSPoint(x: 356, y: 501)); line.line(to: NSPoint(x: 414, y: 501)); line.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
