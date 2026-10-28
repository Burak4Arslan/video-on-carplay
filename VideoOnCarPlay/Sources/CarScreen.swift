import AVFoundation
import MediaPlayer
import UIKit

// Putting pictures on the car's screen without Apple's approval: when an app plays audio, iOS makes it the "now playing"
// app and CarPlay shows its title, artist and artwork on the Now Playing screen. By changing the artwork over and over
// we draw our own picture there; the car's ⏮ ⏯ ⏭ buttons come to us as commands.
@MainActor
final class CarScreen: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case video, camera, counter, animation
        var id: String { rawValue }
        // Also shown as the title on Now Playing
        var title: String {
            switch self {
            case .counter: L("Counter pattern", "Sayaç deseni")
            case .animation: L("Bouncing ball", "Seken top")
            case .video: L("Video", "Video")
            case .camera: L("Camera", "Kamera")
            }
        }
        // Short name for the picker on screen
        var shortName: String {
            switch self {
            case .counter: L("Counter", "Sayaç")
            case .animation: L("Ball", "Top")
            case .video: L("Video", "Video")
            case .camera: L("Camera", "Kamera")
            }
        }
    }

    enum Method: String, CaseIterable, Identifiable {
        case frames, animated
        var id: String { rawValue }
        var title: String {
            switch self {
            case .frames: L("Frame by frame", "Kare kare")
            case .animated: L("Animated artwork", "Hareketli kapak")
            }
        }
    }

    // In the car (wireless CarPlay) 24 was clean, at 30 and 60 the car sometimes showed its empty artwork; the steps in
    // between are for finding the limit
    static let fpsChoices: [Double] = [1, 2, 4, 8, 15, 20, 24, 25, 27, 29, 30, 60]

    @Published private(set) var isRunning = false
    @Published var source: Source = .video { didSet { if isRunning { updateAudio(); updateCamera() } } }
    // The speed is kept between launches (set once, then just press start in the car)
    @Published var fps: Double = CarScreen.saved("carplay.fps", or: 24) {
        didSet { UserDefaults.standard.set(fps, forKey: "carplay.fps"); if isRunning { restartTimer() } }
    }
    @Published var audible = false { didSet { if isRunning { startAudio() } } }
    // Changes every frame; not @Published, or the screen would be redrawn 30–60 times a second (shown with the preview)
    private(set) var frameNumber = 0
    // Frames we handed over as artwork in the last second
    @Published private(set) var sentFPS = 0
    // Frames iOS really took and passed on in the last second (how often it asked for the artwork)
    @Published private(set) var deliveredFPS = 0
    // Skip iOS's half-second batching wait (NowPlayingPush.swift). With it off, iOS passes on 2 frames per second.
    @Published var skipWait = true { didSet { note(skipWait ? L("Skipping the wait", "Bekleme atlanıyor") : L("iOS wait is on (2 frames per second)", "iOS'un beklemesi açık (saniyede 2 kare)")) } }
    // Treat every frame as new artwork of the same track; with it off, iOS passes on every frame as a new track
    @Published var sameTrack = true { didSet { note(sameTrack ? L("Every frame is the same track", "Her kare aynı şarkı") : L("Every frame is a new track", "Her kare yeni şarkı")) } }
    let canSkipWait = NowPlayingPush.isAvailable
    // Artwork edge in pixels: 600 is the size that worked in the car (smaller artwork was never confirmed there)
    let artworkSize: Double = 600
    @Published var cameraPosition: CameraCapture.Position = .back { didSet { if cameraPosition != oldValue { updateCamera(restart: true) } } }
    @Published private(set) var cameraStatus: String?
    // Image sizes iOS asked the artwork for in the last second, with counts (to see whether the car asks separately)
    @Published private(set) var requestedSizes = ""
    @Published private(set) var preview: UIImage?
    @Published private(set) var log: [String] = []
    @Published private(set) var videoName: String?
    @Published private(set) var videoStatus: String?
    // Method for video: frame-by-frame artwork or iOS 26 animated artwork (played by the system)
    @Published var method: Method = .frames { didSet { if method != oldValue { methodChanged() } } }
    @Published var fillSquare = true { didSet { video.fillSquare = fillSquare } }
    @Published private(set) var animatedStatus: String?
    var animatedSupport: String { AnimatedArtworkMaker.supportedKeysDescription }

    private let frameSize = CGSize(width: 600, height: 600)
    nonisolated private static func saved(_ key: String, or fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private let delivered = DeliveredFrames()
    private var lastCount = Date()
    private var lastPreview = Date.distantPast
    // Last frame sent: re-sent with the "paused" state when pausing
    private var lastSent: UIImage?
    private var renderTask: Task<Void, Never>?
    private var startedAt = Date()
    private var commandsRegistered = false
    private let video = VideoPlayback()
    private let camera = CameraCapture()
    private var cameraOn = false
    private var paused = false
    private var clips: AnimatedArtworkMaker.Clips?
    private var sentThisSecond = 0
    private var clipsTask: Task<Void, Never>?
    private var animatedEntries: [String: Any] = [:]
    private var staticArtwork: MPMediaItemArtwork?

    // MARK: - Start / stop

    func start() {
        guard !isRunning else { return }
        startedAt = Date()
        frameNumber = 0
        registerCommands()
        isRunning = true
        paused = false
        startAudio()
        updateCamera()
        restartTimer()
        tick()
        note(L("Started: \(source.title), \(Int(fps)) fps", "Başladı: \(source.title), \(Int(fps)) kare/sn"))
    }

    func stop() {
        stopTimer()
        renderTask?.cancel()
        renderTask = nil
        player?.stop()
        player = nil
        video.pause()
        isRunning = false
        updateCamera()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        note(L("Stopped", "Durdu"))
    }

    // Timer: independent of the phone's screen, keeps running while locked. The frames go to the car, not to the phone's
    // display, so there is no need to tie them to the display refresh (CADisplayLink).
    private func restartTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Audio: iOS only treats us as "now playing" with a real audio session and audio that plays

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Non-mixable .playback: the only way onto Now Playing (the radio or Spotify stops)
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: try Self.toneFile(audible: audible))
            player.numberOfLoops = -1
            player.volume = audible ? 0.3 : 1
            self.player?.stop()
            self.player = player
            updateAudio()
        } catch {
            note(L("Could not start audio: \(error.localizedDescription)", "Ses başlatılamadı: \(error.localizedDescription)"))
        }
    }

    // In video mode the video's own sound plays, otherwise a silent tone (or the test tone)
    private func updateAudio() {
        guard isRunning, !paused else { return }
        if source == .video && video.hasVideo {
            player?.pause()
            video.play()
        } else {
            video.pause()
            player?.play()
        }
    }

    // 2 seconds of audio: silence (zeros) or a 440 Hz test tone
    private static func toneFile(audible: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(audible ? "tone.caf" : "silence.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = audible ? Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.2) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    // MARK: - Making frames and turning them into artwork

    private func tick() {
        frameNumber += 1
        let elapsed = Date().timeIntervalSince(startedAt)
        let image: UIImage
        switch source {
        case .counter: image = FrameArt.counter(frame: frameNumber, elapsed: elapsed, fps: fps, size: frameSize)
        case .animation: image = FrameArt.ball(elapsed: elapsed, size: frameSize)
        case .video:
            guard video.hasVideo else {
                image = FrameArt.message(L("No video selected", "Video seçilmedi"), size: frameSize)
                break
            }
            // Until the player is ready the duration is unknown: sending then would mark the item as live in the car
            guard video.isReady else { return }
            if method == .animated, clips != nil {
                // With animated artwork the system plays the picture; we only update the position (once a second is enough)
                if frameNumber % max(1, Int(fps)) == 0 { publish(nil, elapsed: elapsed) }
                return
            }
            // A new frame is prepared in the background and sent as soon as it is ready (kickRender). Without a new
            // frame we do not send the same one again: needless work for iOS.
            kickRender()
            countSecond()
            return
        case .camera:
            kickRender()
            countSecond()
            return
        }
        let sized = image.resized(to: artworkSize)
        showPreview(sized)
        publish(sized, elapsed: elapsed)
    }

    // The preview on the phone at most 10 times a second: SwiftUI redraws the screen each time, which loads the main thread
    private func showPreview(_ image: UIImage) {
        let now = Date()
        guard now.timeIntervalSince(lastPreview) >= 0.1 else { return }
        lastPreview = now
        preview = image
    }

    // Prepare the next video frame in the background; at most one render runs at a time
    private func kickRender() {
        guard renderTask == nil else { return }
        let wanted = source
        let frameSource: VideoPlayback.FrameSource
        switch wanted {
        case .video:
            guard method != .animated, let next = video.nextFrameSource() else { return }
            frameSource = next
        case .camera:
            guard let buffer = camera.takeFrame() else { return }
            frameSource = .buffer(buffer, .up)
        default:
            return
        }
        let fill = video.fillSquare
        let maxSize = CGFloat(artworkSize)
        let context = UIApplication.shared.applicationState == .background ? video.softwareContext : video.ciContext
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let frame = await VideoPlayback.render(frameSource, fillSquare: fill, maxSize: maxSize, context: context)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.renderTask = nil
                guard let frame, self.isRunning, !self.paused, self.source == wanted,
                      wanted == .camera || self.method != .animated else { return }
                self.showPreview(frame)
                self.publish(frame, elapsed: Date().timeIntervalSince(self.startedAt))
            }
        }
    }

    private func publish(_ image: UIImage?, elapsed: TimeInterval) {
        let artwork: MPMediaItemArtwork
        if let image {
            let delivered = self.delivered
            artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                delivered.add(size)
                return image
            }
            lastSent = image
            sentThisSecond += 1
            countSecond()
        } else if let staticArtwork {
            artwork = staticArtwork
        } else {
            return
        }
        var info: [String: Any] = [
            // Constant title: CarPlay throttles title changes separately (Apple's answer on the forums). The frame number is in the picture.
            MPMediaItemPropertyTitle: source.title,
            MPMediaItemPropertyArtist: L("\(Int(fps)) fps", "\(Int(fps)) kare/sn"),
            MPMediaItemPropertyAlbumTitle: "Video on CarPlay",
            MPMediaItemPropertyArtwork: artwork,
            MPMediaItemPropertyPlaybackDuration: 3600,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.truncatingRemainder(dividingBy: 3600),
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
            // Always sent explicitly: once it had been true, leaving the key out did not clear it, and the car kept
            // showing LIVE for a video
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if source == .video, video.hasVideo {
            // Real duration and position for video: CarPlay shows the progress bar correctly
            // Constant text: the title must not change every frame, CarPlay should only refresh the picture
            info[MPMediaItemPropertyTitle] = video.title ?? "Video"
            info[MPMediaItemPropertyArtist] = method == .animated ? Method.animated.title : L("Frame by frame · \(Int(fps)) fps", "Kare kare · \(Int(fps)) kare/sn")
            if method == .animated, clips != nil {
                info.merge(animatedEntries) { $1 }
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = video.elapsed
            if let duration = video.duration {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            } else {
                info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
                info[MPNowPlayingInfoPropertyIsLiveStream] = true
            }
            info[MPNowPlayingInfoPropertyPlaybackRate] = Double(video.player.rate)
        } else if source == .camera {
            // The camera really is live: no duration, LIVE on the car's progress bar
            info[MPMediaItemPropertyArtist] = L("Live · \(Int(fps)) fps", "Canlı · \(Int(fps)) kare/sn")
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if sameTrack {
            // Constant identifier: iOS treats every frame as new artwork of the same track. Without it every assignment is
            // a new track (in the simulator every frame got a new item identifier).
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] = "video-on-carplay.\(source.rawValue).\(video.title ?? "")"
        }
        let center = MPNowPlayingInfoCenter.default()
        if skipWait { NowPlayingPush.skipWait(center) }
        center.nowPlayingInfo = info
    }

    // Once a second: how many frames we gave, how many iOS took
    private func countSecond() {
        let now = Date()
        let span = now.timeIntervalSince(lastCount)
        guard span >= 1 else { return }
        sentFPS = Int((Double(sentThisSecond) / span).rounded())
        deliveredFPS = Int((Double(delivered.take()) / span).rounded())
        requestedSizes = delivered.takeSizes()
            .sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: " · ")
        sentThisSecond = 0
        lastCount = now
    }

    // MARK: - Camera

    // The camera runs only while sending with the camera source (and not paused); the screen stays awake meanwhile,
    // because iOS stops the camera when the app leaves the screen
    private func updateCamera(restart: Bool = false) {
        let wanted = isRunning && !paused && source == .camera
        if wanted && (!cameraOn || restart) {
            cameraOn = true
            cameraStatus = nil
            camera.start(cameraPosition) { [weak self] failure in
                self?.cameraStatus = failure.localizedDescription
                self?.note(failure.localizedDescription)
            }
            note(L("Camera on (\(cameraPosition.title))", "Kamera açık (\(cameraPosition.title))"))
        } else if !wanted && cameraOn {
            cameraOn = false
            camera.stop()
        }
        UIApplication.shared.isIdleTimerDisabled = wanted
    }

    // MARK: - The car's buttons

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.faster() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.nextSource() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause(from: L("⏸ pause", "⏸ durdur")) }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume(from: L("▶️ play", "▶️ oynat")) }
            return .success
        }
        // Seeking from the progress bar (video)
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                self?.video.seek(to: event.positionTime)
                self?.note(L("🚗 seek → \(Int(event.positionTime)) s", "🚗 sarma → \(Int(event.positionTime)) sn"))
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.paused { self.resume(from: "⏯") } else { self.pause(from: "⏯") }
            }
            return .success
        }
    }

    private func faster() {
        let next = Self.fpsChoices.first { $0 > fps } ?? Self.fpsChoices[0]
        fps = next
        note(L("🚗 ⏭ next → \(Int(next)) fps", "🚗 ⏭ ileri → \(Int(next)) kare/sn"))
    }

    private func nextSource() {
        let all = Source.allCases
        source = all[(all.firstIndex(of: source)! + 1) % all.count]
        note(L("🚗 ⏮ previous → \(source.title)", "🚗 ⏮ geri → \(source.title)"))
    }

    private func pause(from button: String) {
        guard isRunning else { return }
        paused = true
        stopTimer()
        player?.pause()
        video.pause()
        updateCamera()
        // Re-send the last frame with the "paused" state so CarPlay stops the progress bar
        publish(lastSent, elapsed: source == .video ? video.elapsed : Date().timeIntervalSince(startedAt))
        note("🚗 \(button)")
    }

    private func resume(from button: String) {
        guard isRunning else { return }
        paused = false
        updateAudio()
        updateCamera()
        restartTimer()
        note("🚗 \(button)")
    }

    // MARK: - Animated artwork

    private func methodChanged() {
        note(L("Method: \(method.title)", "Yöntem: \(method.title)"))
        if method == .animated { prepareAnimated() } else { clearAnimated() }
    }

    private func clearAnimated() {
        clipsTask?.cancel()
        clips = nil
        animatedEntries = [:]
        staticArtwork = nil
        animatedStatus = nil
    }

    // Makes cropped clips of at most 2 minutes from the video's current position; the sound also plays from the clip's start
    private func prepareAnimated() {
        clearAnimated()
        guard #available(iOS 26.0, *) else { animatedStatus = L("Needs iOS 26", "iOS 26 gerekli"); return }
        guard let asset = video.asset else { animatedStatus = L("Pick a video first", "Önce bir video seç"); return }
        let start = video.elapsed
        clipsTask = Task {
            do {
                let clips = try await AnimatedArtworkMaker.make(from: asset, start: start) { text in self.animatedStatus = text }
                guard !Task.isCancelled, method == .animated else { return }
                self.clips = clips
                animatedEntries = AnimatedArtworkMaker.nowPlayingEntries(clips)
                let preview = clips.squarePreview
                staticArtwork = MPMediaItemArtwork(boundsSize: preview.size) { _ in preview }
                preview.prepareForDisplay { _ in }
                self.preview = preview
                video.seek(to: clips.start)
                if isRunning, !paused { video.play() }
                animatedStatus = animatedEntries.isEmpty
                    ? L("The system does not support animated artwork", "Sistem hareketli kapağı desteklemiyor")
                    : L("Ready: \(Int(clips.duration)) s clip from \(Int(clips.start)) s, looping", "Hazır: \(Int(clips.duration)) sn'lik klip (\(Int(clips.start)). saniyeden), döngüde")
                note(L("Animated artwork: \(Int(clips.duration)) s, keys: \(animatedEntries.count)", "Hareketli kapak: \(Int(clips.duration)) sn, anahtarlar: \(animatedEntries.count)"))
                if isRunning { publish(nil, elapsed: video.elapsed) }
            } catch {
                animatedStatus = L("Could not prepare: \(error.localizedDescription)", "Hazırlanamadı: \(error.localizedDescription)")
                note(L("Animated artwork error: \(error)", "Hareketli kapak hatası: \(error)"))
            }
        }
    }

    // MARK: - Video

    // Getting a video from Photos failed
    func videoImportFailed(_ text: String) {
        videoStatus = text
        note(text)
    }

    // A file picked from Photos
    func loadVideo(_ url: URL, name: String) {
        clearAnimated()
        video.load(url, title: name)
        videoName = name
        videoStatus = L("Ready: \(name)", "Hazır: \(name)")
        source = .video
        updateAudio()
        note("Video: \(name)")
        if method == .animated { prepareAnimated() }
    }

    // A plain video link (mp4, m3u8) or a YouTube link; false when it could not be opened (the reason is in videoStatus)
    @discardableResult
    func loadLink(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            videoStatus = L("Could not read the link", "Link anlaşılmadı")
            return false
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            do {
                let result = try await YouTubeLoader.load(url) { [weak self] text in self?.videoStatus = text }
                clearAnimated()
                video.load(asset: result.asset, title: result.title, canGenerate: true)
                videoName = result.title
                videoStatus = L("Ready: \(result.title)", "Hazır: \(result.title)")
                source = .video
                updateAudio()
                note("YouTube: \(result.title)")
                if method == .animated { prepareAnimated() }
                return true
            } catch {
                videoStatus = L("Could not open YouTube: \(error.localizedDescription)", "YouTube açılamadı: \(error.localizedDescription)")
                note(L("YouTube error: \(error)", "YouTube hatası: \(error)"))
                return false
            }
        } else {
            loadVideo(url, name: url.lastPathComponent.isEmpty ? host : url.lastPathComponent)
            return true
        }
    }

    private func note(_ text: String) {
        let time = Date().formatted(.dateTime.hour().minute().second())
        log.insert("\(time)  \(text)", at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
