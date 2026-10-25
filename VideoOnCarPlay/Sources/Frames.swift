import AVFoundation
import UIKit

// Frames sent as the artwork image
enum FrameArt {
    private static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
    }

    private static func text(_ string: String, font: UIFont, color: UIColor = .white, centerY: CGFloat, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = font.lineHeight
        (string as NSString).draw(in: CGRect(x: 0, y: centerY - height / 2, width: width, height: height), withAttributes: attributes)
    }

    // Test pattern: count on the car's screen how many frames per second really change
    static func counter(frame: Int, elapsed: TimeInterval, fps: Double, size: CGSize) -> UIImage {
        render(size) { context in
            UIColor(hue: CGFloat(frame % 24) / 24, saturation: 0.65, brightness: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            text("\(frame)", font: .monospacedDigitSystemFont(ofSize: 220, weight: .heavy), centerY: size.height * 0.42, width: size.width)
            let seconds = String(format: L("%.1f s", "%.1f sn"), elapsed)
            text(seconds, font: .monospacedDigitSystemFont(ofSize: 56, weight: .semibold), centerY: size.height * 0.72, width: size.width)
            text(L("target \(Int(fps)) fps", "hedef \(Int(fps)) kare/sn"), font: .systemFont(ofSize: 36, weight: .medium),
                 color: UIColor.white.withAlphaComponent(0.8), centerY: size.height * 0.84, width: size.width)
            // A bar that moves one step per frame: skipped frames show up as gaps
            let steps = 12
            let w = size.width / CGFloat(steps)
            UIColor.white.setFill()
            context.fill(CGRect(x: CGFloat(frame % steps) * w, y: size.height - 40, width: w, height: 40))
        }
    }

    // Bouncing ball: to judge how smooth the motion is
    static func ball(elapsed: TimeInterval, size: CGSize) -> UIImage {
        render(size) { context in
            UIColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let r: CGFloat = 60
            func bounce(_ t: Double, _ span: CGFloat) -> CGFloat {
                let period = 2.0
                let p = t.truncatingRemainder(dividingBy: period) / period
                return r + (span - 2 * r) * CGFloat(p < 0.5 ? p * 2 : 2 - p * 2)
            }
            let x = bounce(elapsed * 0.8, size.width)
            let y = bounce(elapsed * 1.3, size.height)
            UIColor.systemOrange.setFill()
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            text(String(format: "%.1f", elapsed), font: .monospacedDigitSystemFont(ofSize: 40, weight: .bold),
                 color: UIColor.white.withAlphaComponent(0.7), centerY: 40, width: size.width)
        }
    }

    static func message(_ string: String, size: CGSize) -> UIImage {
        render(size) { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            text(string, font: .systemFont(ofSize: 48, weight: .bold), centerY: size.height / 2, width: size.width)
        }
    }
}

extension UIImage {
    // Scaled down so the longer edge is `edge` (the drawn sources are made at 600 px); unchanged if already that small
    func resized(to edge: Double) -> UIImage {
        guard edge < Double(max(size.width, size.height)) else { return self }
        let scale = edge / Double(max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
