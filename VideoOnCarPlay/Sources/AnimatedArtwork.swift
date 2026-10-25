import AVFoundation
import CoreImage
import MediaPlayer
import UIKit

// iOS 26 animated album artwork (MPMediaItemAnimatedArtwork): instead of frame-by-frame images the system gets a video
// file and plays it by itself (the animated covers in Apple Music). If CarPlay showed it, the video would be smooth.
// Makes silent clips cropped from the video: 1:1 (square) and 3:4 (portrait).
enum AnimatedArtworkMaker {
    struct Clips {
        let square: URL
        let tall: URL
        let squarePreview: UIImage
        let tallPreview: UIImage
        let start: TimeInterval
        let duration: TimeInterval
    }

    static let maxSeconds = 120.0

    static func make(from asset: AVAsset, start: TimeInterval, status: @escaping @MainActor (String) -> Void) async throws -> Clips {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw URLError(.cannotDecodeContentData) }
        let total = try await asset.load(.duration).seconds
        let begin = total.isFinite && start < total - 1 ? max(0, start) : 0
        let length = min(maxSeconds, (total.isFinite ? total : maxSeconds) - begin)
        let range = CMTimeRange(start: CMTime(seconds: begin, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))

        // Video track only (animated artwork is silent)
        let videoOnly = AVMutableComposition()
        let compositionTrack = videoOnly.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionTrack?.insertTimeRange(range, of: track, at: .zero)
        compositionTrack?.preferredTransform = try await track.load(.preferredTransform)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("animated-artwork", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString.prefix(8)

        await status(L("Preparing animated artwork (square)…", "Hareketli kapak hazırlanıyor (kare)…"))
        let square = folder.appendingPathComponent("square-\(id).mp4")
        try await export(videoOnly, size: CGSize(width: 720, height: 720), to: square)
        await status(L("Preparing animated artwork (portrait)…", "Hareketli kapak hazırlanıyor (dikey)…"))
        let tall = folder.appendingPathComponent("portrait-\(id).mp4")
        try await export(videoOnly, size: CGSize(width: 720, height: 960), to: tall)

        return Clips(square: square, tall: tall,
                     squarePreview: try await firstFrame(square), tallPreview: try await firstFrame(tall),
                     start: begin, duration: length)
    }

    // Scales the picture to fill the target size and crops the center
    private static func export(_ asset: AVAsset, size: CGSize, to url: URL) async throws {
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let scale = max(size.width / source.extent.width, size.height / source.extent.height)
            var image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let x = image.extent.midX - size.width / 2
            let y = image.extent.midY - size.height / 2
            image = image.cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
                .transformed(by: CGAffineTransform(translationX: -x, y: -y))
            request.finish(with: image, context: nil)
        }
        composition.renderSize = size
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw URLError(.cannotCreateFile)
        }
        session.videoComposition = composition
        session.outputURL = url
        session.outputFileType = .mp4
        await session.export()
        if let error = session.error { throw error }
    }

    private static func firstFrame(_ url: URL) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        return UIImage(cgImage: try await generator.image(at: .zero).image)
    }

    // Keys to add to nowPlayingInfo; a key the system does not support is left out
    @available(iOS 26.0, *)
    static func nowPlayingEntries(_ clips: Clips) -> [String: Any] {
        func artwork(_ name: String, _ preview: UIImage, _ video: URL) -> MPMediaItemAnimatedArtwork {
            MPMediaItemAnimatedArtwork(artworkID: "\(name)-\(video.lastPathComponent)",
                                       previewImageRequestHandler: { _, completion in completion(preview) },
                                       videoAssetFileURLRequestHandler: { _, completion in completion(video) })
        }
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        var entries: [String: Any] = [:]
        if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
            entries[MPNowPlayingInfoProperty1x1AnimatedArtwork] = artwork("square", clips.squarePreview, clips.square)
        }
        if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
            entries[MPNowPlayingInfoProperty3x4AnimatedArtwork] = artwork("portrait", clips.tallPreview, clips.tall)
        }
        return entries
    }

    static var supportedKeysDescription: String {
        guard #available(iOS 26.0, *) else { return L("needs iOS 26", "iOS 26 gerekli") }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        let names = keys.map { $0 == MPNowPlayingInfoProperty1x1AnimatedArtwork ? L("square (1:1)", "kare (1:1)") : $0 == MPNowPlayingInfoProperty3x4AnimatedArtwork ? L("portrait (3:4)", "dikey (3:4)") : $0 }
        return names.isEmpty ? L("the system supports none", "sistem hiçbirini desteklemiyor") : names.joined(separator: ", ")
    }
}
