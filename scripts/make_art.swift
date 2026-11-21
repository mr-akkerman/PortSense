// Draws the app icon (1024×1024) and the DMG window background (1320×800 = 660×400 @2x).
// Usage: swiftc -O scripts/make_art.swift -o /tmp/make_art && (cd assets && /tmp/make_art)
import AppKit

func png(_ size: NSSize, _ path: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

/// A USB-C receptacle: rounded shell with the contact tongue.
func connector(_ ctx: CGContext, center: CGPoint, width w: CGFloat, glow: Bool) {
    let h = w * 0.36
    let body = CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h)
    if glow { ctx.setShadow(offset: .zero, blur: w * 0.18, color: c(80, 255, 170, 0.75)) }
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: h/2, cornerHeight: h/2, transform: nil))
    ctx.setFillColor(c(245, 250, 255)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let inner = body.insetBy(dx: w * 0.075, dy: h * 0.2)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: inner.height/2, cornerHeight: inner.height/2, transform: nil))
    ctx.setFillColor(c(18, 32, 58)); ctx.fillPath()
    let tongue = inner.insetBy(dx: inner.width * 0.16, dy: inner.height * 0.34)
    ctx.addPath(CGPath(roundedRect: tongue, cornerWidth: tongue.height/2, cornerHeight: tongue.height/2, transform: nil))
    ctx.setFillColor(c(70, 230, 160)); ctx.fillPath()
}

// Icon: a squircle on the macOS grid (824 of 1024 with margins), gradient, three ports, the middle one active.
png(NSSize(width: 1024, height: 1024), "icon_1024.png") { ctx in
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(c(20, 30, 60)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [c(34, 58, 120), c(14, 22, 48)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let r = CGGradient(colorsSpace: nil, colors: [c(70, 230, 160, 0.35), c(70, 230, 160, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 380, options: [])
    // top highlight
    let hl = CGGradient(colorsSpace: nil, colors: [c(255, 255, 255, 0.16), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(c(255, 255, 255, 0.14)); ctx.setLineWidth(4); ctx.strokePath()

    for (i, y) in [700.0, 512, 324].enumerated() {
        if i == 1 { connector(ctx, center: CGPoint(x: 512, y: y), width: 470, glow: true) }
        else {
            ctx.saveGState(); ctx.setAlpha(0.38)
            connector(ctx, center: CGPoint(x: 512, y: y), width: 360, glow: false)
            ctx.restoreGState()
        }
    }
}

// DMG background: light gradient, a caption and an arrow between the app icon (x=180) and Applications (x=480), y=200 pt.
png(NSSize(width: 1320, height: 800), "dmg_background.png") { ctx in
    let g = CGGradient(colorsSpace: nil, colors: [c(250, 252, 255), c(226, 234, 246)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 800), end: CGPoint(x: 1320, y: 0), options: [])
    let r = CGGradient(colorsSpace: nil, colors: [c(70, 220, 160, 0.16), c(70, 220, 160, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r, startCenter: CGPoint(x: 660, y: 400), startRadius: 0,
                           endCenter: CGPoint(x: 660, y: 400), endRadius: 600, options: [])
    // Arrow (dotted line + head); vertical centre of the window: 800 - 200*2 = 400.
    ctx.setStrokeColor(c(30, 175, 120, 0.9)); ctx.setLineWidth(7); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 22])
    ctx.move(to: CGPoint(x: 545, y: 400)); ctx.addLine(to: CGPoint(x: 750, y: 400)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: 735, y: 430)); ctx.addLine(to: CGPoint(x: 775, y: 400)); ctx.addLine(to: CGPoint(x: 735, y: 370))
    ctx.setLineJoin(.round); ctx.strokePath()

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat) {
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attr)
        str.draw(at: CGPoint(x: 660 - str.size().width / 2, y: y))
    }
    text("PortSense", 52, .bold, NSColor(srgbRed: 0.08, green: 0.12, blue: 0.22, alpha: 1), y: 650)
    text("Drag PortSense to Applications", 28, .medium, NSColor(srgbRed: 0.08, green: 0.12, blue: 0.22, alpha: 0.55), y: 120)
}
print("ok")
