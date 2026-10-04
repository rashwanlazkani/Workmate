import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size) / 1024); transform.concat()
    NSColor(srgbRed: 31/255, green: 31/255, blue: 36/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 208, yRadius: 208).fill()
    NSColor(srgbRed: 84/255, green: 130/255, blue: 255/255, alpha: 0.32).setStroke()
    let edge = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
    edge.lineWidth = 12; edge.stroke()
    NSColor(srgbRed: 84/255, green: 130/255, blue: 255/255, alpha: 1).setStroke()
    let mark = NSBezierPath(); mark.lineWidth = 72; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
    mark.move(to: NSPoint(x: 290, y: 716)); mark.line(to: NSPoint(x: 390, y: 324)); mark.line(to: NSPoint(x: 512, y: 605)); mark.line(to: NSPoint(x: 635, y: 324)); mark.line(to: NSPoint(x: 735, y: 716))
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 84/255, green: 130/255, blue: 1, alpha: 0.72)
    glow.shadowOffset = .zero; glow.shadowBlurRadius = CGFloat(size) * 0.052
    glow.set(); mark.stroke()
    NSGraphicsContext.restoreGraphicsState()
    mark.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
