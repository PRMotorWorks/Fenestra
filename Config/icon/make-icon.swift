// Draws Fenestra's app icon (an arched window, Latin "fenestra", over a taskbar sill) and the
// README/social images. Run: swift Config/icon/make-icon.swift <out-dir>
// Writes icon-1024.png; Config/icon/build-icns.sh turns it into Fenestra/Resources/AppIcon.icns.
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(UInt32, CGFloat)], alpha: CGFloat = 1) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { color($0.0, alpha) } as CFArray,
               locations: stops.map { $0.1 })!
}

/// Draws the icon artwork into `ctx`, filling a `size` x `size` square at the origin (y up).
func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // Body: macOS icon grid, 824 pt squircle inset 100 pt, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x0B1E4A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0x0A1A40, 0), (0x16348C, 0.55), (0x2456D6, 1)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Glow behind the window.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x8FC0FF, 0.5), color(0x8FC0FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 460, options: [])

    // Arched window: opening 400 wide, arch top at y 820, sill top at y 300.
    let w: CGFloat = 400, left = 512 - w / 2, sillTop: CGFloat = 300, springLine: CGFloat = 620
    func arch(inset i: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let r = w / 2 - i
        p.move(to: CGPoint(x: left + i, y: sillTop + i))
        p.addLine(to: CGPoint(x: left + i, y: springLine))
        p.addArc(center: CGPoint(x: 512, y: springLine), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: left + w - i, y: sillTop + i))
        p.closeSubpath()
        return p
    }
    // Frame.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.35))
    ctx.addPath(arch(inset: 0)); ctx.setFillColor(color(0xF4F7FF)); ctx.fillPath()
    ctx.restoreGState()
    // Glass: dawn sky through the window.
    ctx.saveGState()
    ctx.addPath(arch(inset: 26)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFC37A, 0), (0xFF9EA8, 0.32), (0x8FB8FF, 0.7), (0x4F7FF0, 1)]),
                           start: CGPoint(x: 512, y: sillTop), end: CGPoint(x: 512, y: 820), options: [])
    // Sun rising behind the sill.
    ctx.drawRadialGradient(gradient([(0xFFF6D8, 0), (0xFFD27A, 0.45), (0xFFB36B, 1)], alpha: 0.95),
                           startCenter: CGPoint(x: 512, y: sillTop + 20), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: sillTop + 20), endRadius: 120, options: [])
    // Glass sheen.
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: left, y: 560)); sheen.addLine(to: CGPoint(x: left + w, y: 720))
    sheen.addLine(to: CGPoint(x: left + w, y: 900)); sheen.addLine(to: CGPoint(x: left, y: 900)); sheen.closeSubpath()
    ctx.addPath(sheen); ctx.setFillColor(color(0xFFFFFF, 0.14)); ctx.fillPath()
    ctx.restoreGState()
    // One vertical mullion: two lights (deliberately not four panes).
    ctx.setFillColor(color(0xF4F7FF))
    ctx.fill(CGRect(x: 512 - 11, y: sillTop + 20, width: 22, height: 820 - sillTop - 40))

    // Sill = taskbar: frosted bar with three app dots, the middle one active.
    let bar = CGRect(x: 232, y: 214, width: 560, height: 96)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.3))
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.setFillColor(color(0xE9EEFA, 0.92)); ctx.fillPath()
    ctx.restoreGState()
    let dot: CGFloat = 46, gap: CGFloat = 34, cy = bar.midY + 6
    let dotColors: [UInt32] = [0xFF8A5B, 0x2F6BEA, 0x1FB5A3]
    for (i, c) in dotColors.enumerated() {
        let cx = 512 + CGFloat(i - 1) * (dot + gap)
        ctx.addPath(CGPath(roundedRect: CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot),
                           cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(color(c)); ctx.fillPath()
    }
    // Active indicator under the middle app.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 512 - 20, y: bar.minY + 12, width: 40, height: 8),
                       cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.setFillColor(color(0x2F6BEA)); ctx.fillPath()

    ctx.restoreGState() // clip
    // Thin inner edge highlight.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()
}

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.cgContext.interpolationQuality = .high
    draw(g.cgContext)
    g.flushGraphics()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let url = URL(fileURLWithPath: out).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

save(render(width: 1024, height: 1024) { drawIcon($0, size: 1024) }, "icon-1024.png")
