import AppKit

// Renders the Termsie app icon (rounded dark tile, split-pane grid, prompt glyph) into an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Termsie.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: path, angle: -90)
    NSColor(srgbRed: 0.31, green: 0.61, blue: 1, alpha: 0.9).setStroke()
    path.lineWidth = s * 0.012
    path.stroke()

    // Split-pane grid: left column, right column split in two.
    let grid = NSBezierPath()
    grid.lineWidth = s * 0.03
    grid.lineCapStyle = .round
    grid.move(to: NSPoint(x: s * 0.5, y: s * 0.18)); grid.line(to: NSPoint(x: s * 0.5, y: s * 0.82))
    grid.move(to: NSPoint(x: s * 0.5, y: s * 0.5)); grid.line(to: NSPoint(x: s * 0.82, y: s * 0.5))
    NSColor(srgbRed: 0.31, green: 0.61, blue: 1, alpha: 1).setStroke()
    grid.stroke()

    // Prompt glyph in the left pane.
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.2, weight: .bold)
    let prompt = NSAttributedString(string: ">_", attributes: [
        .font: font, .foregroundColor: NSColor(srgbRed: 0.6, green: 0.78, blue: 0.47, alpha: 1)])
    let size = prompt.size()
    prompt.draw(at: NSPoint(x: s * 0.32 - size.width / 2, y: s * 0.5 - size.height / 2 + s * 0.02))

    // Small "output lines" in the right panes.
    NSColor(white: 1, alpha: 0.35).setFill()
    for (i, w) in [(0, 0.18), (1, 0.12), (2, 0.2)].map({ ($0.0, CGFloat($0.1)) }) {
        NSRect(x: s * 0.56, y: s * 0.72 - CGFloat(i) * s * 0.06, width: s * w, height: s * 0.025).fill()
        NSRect(x: s * 0.56, y: s * 0.40 - CGFloat(i) * s * 0.06, width: s * (w + 0.04), height: s * 0.025).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
