// Renders the app icon: a Gear VR-style controller with motion arcs and a cursor.
// Usage: swift Tools/make-icon.swift  (writes Resources/AppIcon.icns; needs macOS 13+)

import AppKit

let size: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

// Controller outline in local coordinates (origin mid-body, +y toward the touchpad)
let headCenter = CGPoint(x: 0, y: 170)
let headRadius: CGFloat = 170
let handleHalfWidth: CGFloat = 112

func controllerPath() -> CGPath {
    let head = CGPath(ellipseIn: CGRect(x: -headRadius, y: headCenter.y - headRadius, width: headRadius * 2, height: headRadius * 2), transform: nil)
    let handle = CGPath(roundedRect: CGRect(x: -handleHalfWidth, y: -340, width: handleHalfWidth * 2, height: 390),
                        cornerWidth: handleHalfWidth, cornerHeight: handleHalfWidth, transform: nil)
    // Concave neck joining the round head to the narrower handle
    let a = 1.23 * CGFloat.pi   // point on the head's lower-left edge
    let hx = headRadius * cos(a), hy = headCenter.y + headRadius * sin(a)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: hx, y: hy))
    neck.addQuadCurve(to: CGPoint(x: -handleHalfWidth, y: -30), control: CGPoint(x: -handleHalfWidth, y: 40))
    neck.addLine(to: CGPoint(x: handleHalfWidth, y: -30))
    neck.addQuadCurve(to: CGPoint(x: -hx, y: hy), control: CGPoint(x: handleHalfWidth, y: 40))
    neck.closeSubpath()
    return head.union(handle).union(neck)
}

func drawController(_ ctx: CGContext) {
    let outline = controllerPath()

    // Drop shadow for the whole silhouette
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 14, height: -24), blur: 38, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(outline); ctx.setFillColor(rgb(0.14, 0.15, 0.17)); ctx.fillPath()
    ctx.restoreGState()

    // Body: matte charcoal with a soft top-left light
    ctx.saveGState()
    ctx.addPath(outline); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.27, 0.28, 0.31), rgb(0.12, 0.125, 0.14)]),
                           start: CGPoint(x: -170, y: 340), end: CGPoint(x: 120, y: -340), options: [])
    ctx.restoreGState()
    // Rim highlight
    ctx.saveGState()
    ctx.addPath(outline); ctx.setStrokeColor(rgb(1, 1, 1, 0.14)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    // Touchpad: recessed disc with a thin bezel
    let padRadius: CGFloat = 138
    let pad = CGRect(x: headCenter.x - padRadius, y: headCenter.y - padRadius, width: padRadius * 2, height: padRadius * 2)
    ctx.saveGState()
    ctx.setFillColor(rgb(0.07, 0.075, 0.085)); ctx.fillEllipse(in: pad.insetBy(dx: -6, dy: -6))
    ctx.addEllipse(in: pad); ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0.20, 0.21, 0.24), rgb(0.10, 0.105, 0.12)]),
                           startCenter: CGPoint(x: headCenter.x - 50, y: headCenter.y + 60), startRadius: 10,
                           endCenter: headCenter, endRadius: padRadius, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10)); ctx.setLineWidth(4); ctx.strokeEllipse(in: pad)

    // Round button (back / home)
    func roundButton(_ c: CGPoint, _ r: CGFloat) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(rgb(0.08, 0.085, 0.095)); ctx.fillEllipse(in: rect.insetBy(dx: -4, dy: -4))
        ctx.saveGState()
        ctx.addEllipse(in: rect); ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0.30, 0.31, 0.34), rgb(0.16, 0.165, 0.18)]),
                               start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
        ctx.restoreGState()
    }
    roundButton(CGPoint(x: -43, y: -22), 30)
    roundButton(CGPoint(x: 43, y: -22), 30)

    // Volume rocker with + / − marks
    let rocker = CGRect(x: -30, y: -225, width: 60, height: 160)
    let rockerPath = CGPath(roundedRect: rocker, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rocker.insetBy(dx: -4, dy: -4), cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(rgb(0.08, 0.085, 0.095)); ctx.fillPath()
    ctx.addPath(rockerPath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.30, 0.31, 0.34), rgb(0.16, 0.165, 0.18)]),
                           start: CGPoint(x: -30, y: -65), end: CGPoint(x: 30, y: -225), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0.78, 0.80, 0.84, 0.75)); ctx.setLineWidth(5); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: -11, y: -105)); ctx.addLine(to: CGPoint(x: 11, y: -105))   // +
    ctx.move(to: CGPoint(x: 0, y: -116)); ctx.addLine(to: CGPoint(x: 0, y: -94))
    ctx.move(to: CGPoint(x: -11, y: -185)); ctx.addLine(to: CGPoint(x: 11, y: -185))   // −
    ctx.strokePath()

    // Status LED
    ctx.setFillColor(rgb(0.80, 0.82, 0.86, 0.8))
    ctx.fillEllipse(in: CGRect(x: -7, y: -300, width: 14, height: 14))
}

func render() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background: macOS-style rounded square (824 pt tile inside the 1024 canvas)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.42, 0.72, 1.0), rgb(0.20, 0.33, 0.92)]),
                           start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Controller, tilted
    let origin = CGPoint(x: 420, y: 440)
    let tilt: CGFloat = -0.42
    let scale: CGFloat = 0.95
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.rotate(by: tilt)
    ctx.scaleBy(x: scale, y: scale)
    drawController(ctx)
    ctx.restoreGState()

    // Motion arcs around the touchpad head
    let head = CGPoint(x: origin.x - headCenter.y * scale * sin(tilt), y: origin.y + headCenter.y * scale * cos(tilt))
    ctx.saveGState()
    ctx.setLineCap(.round)
    for (i, r) in [215.0, 280.0].enumerated() {
        ctx.setStrokeColor(rgb(1, 1, 1, 0.85 - Double(i) * 0.35))
        ctx.setLineWidth(26)
        ctx.addArc(center: head, radius: r, startAngle: .pi * 0.2, endAngle: .pi * 0.45, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Cursor arrow
    ctx.saveGState()
    ctx.translateBy(x: 745, y: 690)
    ctx.scaleBy(x: 1.05, y: 1.05)
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 0, y: 0))
    arrow.addLine(to: CGPoint(x: 0, y: -190))
    arrow.addLine(to: CGPoint(x: 45, y: -148))
    arrow.addLine(to: CGPoint(x: 78, y: -222))
    arrow.addLine(to: CGPoint(x: 112, y: -207))
    arrow.addLine(to: CGPoint(x: 80, y: -135))
    arrow.addLine(to: CGPoint(x: 140, y: -135))
    arrow.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 4, height: -10), blur: 18, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(arrow)
    ctx.setFillColor(rgb(1, 1, 1)); ctx.setStrokeColor(rgb(0, 0, 0))
    ctx.setLineWidth(12); ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try render().write(to: master)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }
}
try FileManager.default.removeItem(at: master)

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let ic = Process()
ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
ic.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try ic.run(); ic.waitUntilExit()
print(ic.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
