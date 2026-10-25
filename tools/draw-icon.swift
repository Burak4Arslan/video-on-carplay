import AppKit
import CoreGraphics

// App icon: a car's dashboard screen playing a video. 1024x1024, opaque.
// Usage: swift tools/draw-icon.swift VideoOnCarPlay/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background: night blue
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x1E2F55), rgb(0x0A1020)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

// Dashboard: a wide curve under the screen
let dash = CGMutablePath()
dash.move(to: CGPoint(x: -20, y: 0))
dash.addLine(to: CGPoint(x: -20, y: 250))
dash.addQuadCurve(to: CGPoint(x: 1044, y: 250), control: CGPoint(x: 512, y: 400))
dash.addLine(to: CGPoint(x: 1044, y: 0))
dash.closeSubpath()
ctx.addPath(dash); ctx.setFillColor(rgb(0x05080F)); ctx.fillPath()
ctx.addPath({ let p = CGMutablePath(); p.move(to: CGPoint(x: -20, y: 250)); p.addQuadCurve(to: CGPoint(x: 1044, y: 250), control: CGPoint(x: 512, y: 400)); return p }())
ctx.setStrokeColor(rgb(0x3A4E7A)); ctx.setLineWidth(10); ctx.strokePath()

// Screen: glow, bezel, picture
let screen = CGRect(x: 132, y: 330, width: 760, height: 480)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 90, color: rgb(0xFF5A6E, 0.55))
ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -26, dy: -26), cornerWidth: 86, cornerHeight: 86, transform: nil))
ctx.setFillColor(rgb(0x0B0F18)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -26, dy: -26), cornerWidth: 86, cornerHeight: 86, transform: nil))
ctx.setStrokeColor(rgb(0x55627F)); ctx.setLineWidth(6); ctx.strokePath()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 62, cornerHeight: 62, transform: nil)); ctx.clip()
let picture = CGGradient(colorsSpace: cs, colors: [rgb(0xFFB547), rgb(0xFF4F7B), rgb(0x7C4DFF)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(picture, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
// Soft hills in the picture, like a frame of a video
ctx.setFillColor(rgb(0x000000, 0.16))
let hill = CGMutablePath()
hill.move(to: CGPoint(x: screen.minX, y: screen.minY))
hill.addLine(to: CGPoint(x: screen.minX, y: 470))
hill.addCurve(to: CGPoint(x: screen.maxX, y: 440), control1: CGPoint(x: 360, y: 600), control2: CGPoint(x: 640, y: 360))
hill.addLine(to: CGPoint(x: screen.maxX, y: screen.minY))
hill.closeSubpath()
ctx.addPath(hill); ctx.fillPath()
ctx.restoreGState()

// Play button
let cx: CGFloat = 512, cy: CGFloat = 590
ctx.setFillColor(rgb(0xFFFFFF, 0.22))
ctx.fillEllipse(in: CGRect(x: cx - 120, y: cy - 120, width: 240, height: 240))
let play = CGMutablePath()
play.move(to: CGPoint(x: cx - 42, y: cy + 70))
play.addLine(to: CGPoint(x: cx + 78, y: cy))
play.addLine(to: CGPoint(x: cx - 42, y: cy - 70))
play.closeSubpath()
ctx.addPath(play); ctx.setFillColor(rgb(0xFFFFFF)); ctx.setLineJoin(.round); ctx.setLineWidth(24)
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.drawPath(using: .fillStroke)

// Progress bar, like on Now Playing
let track = CGRect(x: 212, y: 392, width: 600, height: 18)
ctx.addPath(CGPath(roundedRect: track, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.setFillColor(rgb(0xFFFFFF, 0.35)); ctx.fillPath()
let done = CGRect(x: track.minX, y: track.minY, width: track.width * 0.42, height: track.height)
ctx.addPath(CGPath(roundedRect: done, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.fillEllipse(in: CGRect(x: done.maxX - 20, y: track.midY - 20, width: 40, height: 40))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
