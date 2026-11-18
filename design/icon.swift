// ScamShield app icon ("Triage"): a voicemail symbol above three sorted lanes —
// blue = needs attention, amber = review, red = scam. Source of truth for every icon.
// Usage: swift design/icon.swift out.png
import AppKit

let S: CGFloat = 1024
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let blue = rgb(0x3B82F6), amber = rgb(0xF5A524), red = rgb(0xEF4444), white = NSColor.white

func render(_ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(name).png"))
}
func gradient(_ cg: CGContext, _ a: NSColor, _ b: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
}
func pill(_ cg: CGContext, _ r: CGRect, _ c: NSColor) {
    cg.setFillColor(c.cgColor); cg.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); cg.fillPath()
}
// Voicemail glyph: two rings joined by a bar along their bottoms.
func voicemail(_ cg: CGContext, center: CGPoint, width: CGFloat, line: CGFloat, color: NSColor) {
    let r = width * 0.22
    let lx = center.x - width / 2 + r, rx = center.x + width / 2 - r
    cg.setStrokeColor(color.cgColor); cg.setLineWidth(line); cg.setLineCap(.round)
    cg.strokeEllipse(in: CGRect(x: lx - r, y: center.y - r, width: 2 * r, height: 2 * r))
    cg.strokeEllipse(in: CGRect(x: rx - r, y: center.y - r, width: 2 * r, height: 2 * r))
    cg.move(to: CGPoint(x: lx, y: center.y - r)); cg.addLine(to: CGPoint(x: rx, y: center.y - r)); cg.strokePath()
}

// A — "Triage": voicemail glyph above three sorted lanes (attention / review / scam).
render("A-triage") { cg in
    gradient(cg, rgb(0x1E2A5A), rgb(0x0E1226))
    voicemail(cg, center: CGPoint(x: S / 2, y: 650), width: 560, line: 58, color: white)
    pill(cg, CGRect(x: 232, y: 352, width: 560, height: 70), blue)
    pill(cg, CGRect(x: 232, y: 252, width: 400, height: 70), amber)
    pill(cg, CGRect(x: 232, y: 152, width: 240, height: 70), red)
}

