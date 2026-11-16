// Renders Resources/AppIcon.icns: a blueprint-style line drawing of the KeyLab on dark-grey grid paper.
// Run from KeyLabManager/: swift tools/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    let s = CGFloat(px)
    let small = px <= 32
    // Work in a 1024 design space, y down.
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)
    let u: CGFloat = 1024 / s                       // one device pixel in design units
    func lw(_ w: CGFloat) -> CGFloat { max(w, u) }  // never thinner than a pixel

    // Squircle background (macOS icon grid: 824 px body, 100 px margin)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 / u * 0.5), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(white: 0.115, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Grid paper
    if !small {
        for i in stride(from: 100, through: 924, by: 32) {
            let major = (i - 100) % 128 == 0
            ctx.setStrokeColor(NSColor(white: major ? 0.20 : 0.155, alpha: 1).cgColor)
            ctx.setLineWidth(lw(major ? 3 : 2))
            ctx.move(to: CGPoint(x: CGFloat(i), y: 100)); ctx.addLine(to: CGPoint(x: CGFloat(i), y: 924))
            ctx.move(to: CGPoint(x: 100, y: CGFloat(i))); ctx.addLine(to: CGPoint(x: 924, y: CGFloat(i)))
            ctx.strokePath()
        }
    }

    let ink = NSColor(white: 0.93, alpha: 1).cgColor
    let faint = NSColor(white: 0.62, alpha: 1).cgColor
    let paper = NSColor(white: 0.115, alpha: 1).cgColor
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    let main: CGFloat = small ? 34 : 12, thin: CGFloat = small ? 22 : 7

    // Keyboard body
    let kb = CGRect(x: 168, y: 300, width: 688, height: 430)
    ctx.setFillColor(paper)
    ctx.addPath(CGPath(roundedRect: kb, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.fillPath()
    ctx.setStrokeColor(ink); ctx.setLineWidth(lw(main))
    ctx.addPath(CGPath(roundedRect: kb, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.strokePath()

    // Panel / keys divider
    let keysTop: CGFloat = 548
    ctx.move(to: CGPoint(x: kb.minX, y: keysTop)); ctx.addLine(to: CGPoint(x: kb.maxX, y: keysTop)); ctx.strokePath()

    // Keys: 2 octaves (14 white keys), black keys solid
    let kx0 = kb.minX + 18, kx1 = kb.maxX - 18, ky1 = kb.maxY - 18
    let whites = small ? 7 : 14
    let kw = (kx1 - kx0) / CGFloat(whites)
    ctx.setLineWidth(lw(thin)); ctx.setStrokeColor(small ? faint : ink)
    for i in 1..<whites {
        let x = kx0 + kw * CGFloat(i)
        ctx.move(to: CGPoint(x: x, y: keysTop)); ctx.addLine(to: CGPoint(x: x, y: ky1))
    }
    ctx.strokePath()
    let blackH = (ky1 - keysTop) * 0.6
    ctx.setStrokeColor(ink); ctx.setLineWidth(lw(thin))
    for i in 0..<(whites - 1) where [0, 1, 3, 4, 5].contains(i % 7) {
        let r = CGRect(x: kx0 + kw * CGFloat(i + 1) - kw * 0.32, y: keysTop, width: kw * 0.64, height: blackH)
        ctx.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor); ctx.fill(r)
        if !small { ctx.stroke(r) }
    }

    // Control panel
    let py0 = kb.minY + 40, py1 = keysTop - 40
    if small {
        // Display + 2×2 pads only
        ctx.setLineWidth(lw(thin)); ctx.setStrokeColor(ink)
        ctx.stroke(CGRect(x: 230, y: py0, width: 200, height: 90))
        for r in 0..<2 { for c in 0..<2 {
            ctx.stroke(CGRect(x: 520 + CGFloat(c) * 140, y: py0 - 4 + CGFloat(r) * 104, width: 110, height: 92))
        } }
    } else {
        ctx.setLineWidth(lw(thin)); ctx.setStrokeColor(ink)
        // LCD with two text lines
        let lcd = CGRect(x: 214, y: py0, width: 170, height: 72)
        ctx.stroke(lcd)
        ctx.setStrokeColor(faint)
        for (i, w) in [CGFloat(120), 90].enumerated() {
            let y = lcd.minY + 24 + CGFloat(i) * 24
            ctx.move(to: CGPoint(x: lcd.minX + 22, y: y)); ctx.addLine(to: CGPoint(x: lcd.minX + 22 + w, y: y))
        }
        ctx.strokePath()
        // Two small buttons under the display
        ctx.setStrokeColor(ink)
        for i in 0..<3 { ctx.strokeEllipse(in: CGRect(x: 222 + CGFloat(i) * 56, y: py0 + 100, width: 30, height: 30)) }
        // 4×4 pads
        let pad: CGFloat = 38, gap: CGFloat = 12, px0: CGFloat = 418, ppy0 = py0 - 2
        for r in 0..<4 { for c in 0..<4 {
            let rr = CGRect(x: px0 + CGFloat(c) * (pad + gap), y: ppy0 + CGFloat(r) * (pad + gap), width: pad, height: pad)
            ctx.addPath(CGPath(roundedRect: rr, cornerWidth: 5, cornerHeight: 5, transform: nil))
        } }
        ctx.strokePath()
        // Encoders (top row) and faders (bottom) — 4 strips
        let sx0: CGFloat = 648
        for i in 0..<4 {
            let cx = sx0 + CGFloat(i) * 48
            ctx.strokeEllipse(in: CGRect(x: cx - 15, y: py0, width: 30, height: 30))
            ctx.move(to: CGPoint(x: cx, y: py0 + 2)); ctx.addLine(to: CGPoint(x: cx, y: py0 + 13))
            // fader track + cap at different positions
            ctx.move(to: CGPoint(x: cx, y: py0 + 52)); ctx.addLine(to: CGPoint(x: cx, y: py1))
            ctx.strokePath()
            let capY = py0 + 58 + CGFloat([70, 30, 95, 50][i])
            ctx.setFillColor(paper)
            let cap = CGRect(x: cx - 13, y: capY, width: 26, height: 16)
            ctx.fill(cap); ctx.stroke(cap)
        }
    }
    ctx.restoreGState()

    // Thin outline of the squircle
    ctx.addPath(shape); ctx.setStrokeColor(NSColor(white: 0.30, alpha: 1).cgColor); ctx.setLineWidth(lw(4)); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", out.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "keylab-icon-preview.png")
try? FileManager.default.copyItem(at: out.appendingPathComponent("icon_512x512@2x.png"),
                                  to: URL(fileURLWithPath: NSTemporaryDirectory() + "keylab-icon-preview.png"))
try? FileManager.default.removeItem(at: out)
print("Wrote Resources/AppIcon.icns")
