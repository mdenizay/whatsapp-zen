// Draws the app icon — the WhatsApp glyph (app/Resources/whatsapp.svg, from
// Simple Icons) in white on a green plate — and writes the PNG sizes iconutil
// needs.
// Usage: swift tools/make-icon.swift <glyph.svg> <output.iconset>
import AppKit

let glyph = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!

/// The glyph filled with one colour, at a pixel size.
func tinted(_ color: NSColor, size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        glyph.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.62, blue: 0.35, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.36, green: 0.92, blue: 0.48, alpha: 1), CGColor(srgbRed: 0.05, green: 0.66, blue: 0.30, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A soft highlight along the top edge, like light on glass.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(srgbRed: 0, green: 0.28, blue: 0.12, alpha: 0.35))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    tinted(.white, size: 540).draw(in: CGRect(x: 242, y: 242, width: 540, height: 540))
    NSGraphicsContext.current = nil
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
