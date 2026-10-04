// Puts a window capture on a soft gradient with a drop shadow, for the README.
// Usage: swift tools/frame-screenshot.swift <in.png> <out.png>
import AppKit

let input = NSImage(contentsOfFile: CommandLine.arguments[1])!
let shot = input.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let margin = 140
let width = shot.width + margin * 2, height = shot.height + margin * 2

let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let colors = [CGColor(srgbRed: 0.80, green: 0.95, blue: 0.86, alpha: 1), CGColor(srgbRed: 0.62, green: 0.86, blue: 0.86, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: CGColor(gray: 0, alpha: 0.28))
ctx.draw(shot, in: CGRect(x: margin, y: margin, width: shot.width, height: shot.height))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
