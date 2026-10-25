import AVFoundation
import CoreImage
import UIKit
import YouTubeKit

// Plays the video with its sound and hands out the current frame. Since the sound comes from our app, we stay the
// "now playing" app: picture frame by frame on CarPlay's Now Playing screen, sound from the car's speakers.
@MainActor
final class VideoPlayback {
    let player = AVPlayer()
    private(set) var title: String?
    private(set) var asset: AVAsset?
    // Fill the square: crop a 16:9 video to a square from the center (CarPlay shows the artwork as a square)
    var fillSquare = true
    private var output: AVPlayerItemVideoOutput?
    // The player's frames come in the video's stored orientation; used to turn videos shot in portrait
    private var orientation: CGImagePropertyOrientation = .up
    // With the phone locked iOS may switch the video track off; for a local file the frame is then read from the file
    private var generator: AVAssetImageGenerator?
    private var lastOutputFrame = Date.distantPast
    private var endObserver: NSObjectProtocol?
    let ciContext = CIContext()
    // In the background (phone locked) iOS may not allow the GPU; then we render on the CPU
    let softwareContext = CIContext(options: [.useSoftwareRenderer: true])
    let maxSize: CGFloat = 600

    // Where the next frame comes from: a frame decoded by the player, or a moment to read from the file
    enum FrameSource: @unchecked Sendable {
        case buffer(CVPixelBuffer, CGImagePropertyOrientation)
        case file(AVAssetImageGenerator, CMTime)
    }

    var hasVideo: Bool { player.currentItem != nil }
    var isReady: Bool { player.currentItem?.status == .readyToPlay }
    var elapsed: TimeInterval { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: TimeInterval? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    func load(_ url: URL, title: String) {
        // Frames of a local file or a plain mp4 can also be read from the file; not for an m3u8 (HLS) stream
        let canGenerate = url.isFileURL || ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
        load(asset: AVURLAsset(url: url), title: title, canGenerate: canGenerate)
    }

    func load(asset: AVAsset, title: String, canGenerate: Bool) {
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        output = nil
        orientation = .up
        // Add the frame output once the video track's size and orientation are known
        Task { [weak self] in
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let info = try? await track?.load(.naturalSize, .preferredTransform)
            guard let self, self.player.currentItem === item else { return }
            self.attachOutput(to: item, naturalSize: info?.0 ?? .zero, transform: info?.1 ?? .identity)
        }
        if canGenerate {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Keep the short side at least maxSize (so it does not shrink when cropped to a square)
            generator.maximumSize = CGSize(width: maxSize * 2, height: maxSize * 2)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            self.generator = generator
        } else {
            generator = nil
        }
        lastOutputFrame = .distantPast
        self.title = title
        player.replaceCurrentItem(with: item)
        // Loop at the end
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
    }

    // Ask the player for scaled-down frames (short side maxSize): cropping and drawing work on a small image instead of
    // 1080p, so every frame is much cheaper. In the simulator only 18–21 of 25 frames per second made it at 1080p.
    private func attachOutput(to item: AVPlayerItem, naturalSize: CGSize, transform: CGAffineTransform) {
        orientation = Self.orientation(of: transform)
        var attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if naturalSize.width > 0, naturalSize.height > 0 {
            let scale = min(1, maxSize / min(naturalSize.width, naturalSize.height))
            attributes[kCVPixelBufferWidthKey as String] = Int((naturalSize.width * scale).rounded())
            attributes[kCVPixelBufferHeightKey as String] = Int((naturalSize.height * scale).rounded())
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        self.output = output
    }

    // Videos shot in portrait on a phone are stored in landscape; the orientation is in preferredTransform
    private static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    // Returns the player's new frame if there is one (on the main thread, fast). If no frame came for half a second
    // (iOS may have switched the video track off while locked), a local file is read at the current time instead.
    func nextFrameSource() -> FrameSource? {
        guard let output else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastOutputFrame = Date()
            return .buffer(buffer, orientation)
        }
        if let generator, player.rate > 0, Date().timeIntervalSince(lastOutputFrame) > 0.5 {
            return .file(generator, player.currentTime())
        }
        return nil
    }

    // Runs in the background: cropping, scaling and making the CGImage should not hold up the main thread
    nonisolated static func render(_ source: FrameSource, fillSquare: Bool, maxSize: CGFloat, context: CIContext) async -> UIImage? {
        var image: CIImage
        switch source {
        case .buffer(let buffer, let orientation):
            image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        case .file(let generator, let time):
            guard let cg = try? await generator.image(at: time).image else { return nil }
            image = CIImage(cgImage: cg)
        }
        if fillSquare {
            let side = min(image.extent.width, image.extent.height)
            image = image.cropped(to: CGRect(x: image.extent.midX - side / 2,
                                              y: image.extent.midY - side / 2,
                                              width: side, height: side))
        }
        let scale = min(1, maxSize / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
