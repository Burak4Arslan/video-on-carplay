import AVFoundation
import Foundation
import YouTubeKit

// A playable video from a YouTube link: the stream URLs are extracted on the device (YouTubeKit, remote server off),
// downloaded to a file and played locally. YouTube now serves sound and picture separately for most videos; the two
// are combined. Streaming directly was tried: AVFoundation waits more than half a minute on YouTube's fragmented mp4
// and gets the duration wrong, while downloading takes seconds.
enum YouTubeLoader {
    static func load(_ url: URL, status: @escaping @MainActor (String) -> Void) async throws -> (asset: AVAsset, title: String) {
        let video = YouTube(url: url, methods: [.local])
        await status(L("Looking for YouTube streams…", "YouTube akışları aranıyor…"))
        let streams = try await video.streams
        let title = (try? await video.metadata)?.title ?? "YouTube"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("youtube", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let progress = Progress(status: status)

        // The artwork is at most 600 px; 480p is enough and downloads fast
        if let muxed = streams.filterVideoAndAudio()
            .filter({ $0.isNativelyPlayable && $0.fileExtension == .mp4 && ($0.videoResolution ?? 0) <= 480 })
            .highestResolutionStream() {
            let file = folder.appendingPathComponent("video.mp4")
            try await download(muxed.url, to: file, progress: progress)
            return (AVURLAsset(url: file), title)
        }

        guard let videoStream = streams.filterVideoOnly()
                .filter({ $0.isNativelyPlayable && $0.fileExtension == .mp4 && ($0.videoResolution ?? 0) <= 480 })
                .highestResolutionStream(),
              let audioStream = streams.filterAudioOnly()
                .filter({ $0.isNativelyPlayable && $0.fileExtension == .m4a })
                .highestAudioBitrateStream() else {
            throw URLError(.resourceUnavailable)
        }
        let videoFile = folder.appendingPathComponent("video.mp4")
        let audioFile = folder.appendingPathComponent("audio.m4a")
        async let videoDone: Void = download(videoStream.url, to: videoFile, progress: progress)
        async let audioDone: Void = download(audioStream.url, to: audioFile, progress: progress)
        _ = try await (videoDone, audioDone)

        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = AVURLAsset(url: audioFile)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw URLError(.cannotDecodeContentData)
        }
        // AVFoundation gets the duration of these files wrong (twice as long); use the duration YouTube puts in the link
        var seconds = [videoStream.url, audioStream.url].compactMap(durationParameter).min()
        if seconds == nil {
            seconds = min(try await videoAsset.load(.duration).seconds, try await audioAsset.load(.duration).seconds)
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds ?? 0, preferredTimescale: 600))
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: audioTrack, at: .zero)
        return (composition, title)
    }

    private static func durationParameter(_ url: URL) -> Double? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dur" }?.value.flatMap(Double.init)
    }

    // Shows the downloaded bytes on screen
    actor Progress {
        private var done = 0
        private var total = 0
        private let status: @MainActor (String) -> Void

        init(status: @escaping @MainActor (String) -> Void) { self.status = status }

        func expect(_ bytes: Int) { total += bytes }

        func add(_ bytes: Int) async {
            done += bytes
            let text = L("Downloading… \(done / 1_000_000) / \(total / 1_000_000) MB", "İndiriliyor… \(done / 1_000_000) / \(total / 1_000_000) MB")
            await status(text)
        }
    }

    // 8 MB ranges, 4 requests in parallel; each one is written to its place in the file as soon as it arrives (low memory)
    private static func download(_ url: URL, to file: URL, progress: Progress) async throws {
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: probe)
        guard let contentRange = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let total = Int(contentRange.split(separator: "/").last ?? "") else {
            throw URLError(.badServerResponse)
        }
        await progress.expect(total)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = 8 << 20
        let parts = stride(from: 0, to: total, by: chunk).map { ($0, min($0 + chunk, total) - 1) }
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func addNext() {
                let (start, end) = parts[next]
                next += 1
                group.addTask {
                    var request = URLRequest(url: url)
                    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard data.count == end - start + 1 else { throw URLError(.networkConnectionLost) }
                    return (start, data)
                }
            }
            for _ in 0..<min(4, parts.count) { addNext() }
            while let (offset, data) = try await group.next() {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                await progress.add(data.count)
                if next < parts.count { addNext() }
            }
        }
    }
}
