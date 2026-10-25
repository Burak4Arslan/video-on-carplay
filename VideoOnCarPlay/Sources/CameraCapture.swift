import AVFoundation

// The live camera as a source: the newest camera frame becomes the artwork.
// iOS only lets apps use the camera while they are on screen, so the app has to stay open (the screen is kept awake).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Position: String, CaseIterable, Identifiable {
        case back, front
        var id: String { rawValue }
        var title: String {
            switch self {
            case .back: L("Back", "Arka")
            case .front: L("Front", "Ön")
            }
        }
    }

    enum Failure: LocalizedError {
        case denied, noCamera
        var errorDescription: String? {
            switch self {
            case .denied: L("No camera permission (Settings > Video on CarPlay > Camera)", "Kamera izni yok (Ayarlar > uygulama > Kamera)")
            case .noCamera: L("No camera found", "Kamera bulunamadı")
            }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var fresh = false

    // Starts (or switches) the camera; the error is reported on the main thread
    func start(_ position: Position, failed: @escaping @MainActor (Failure) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                Task { @MainActor in failed(.denied) }
                return
            }
            self.queue.async {
                do {
                    try self.configure(position)
                    if !self.session.isRunning { self.session.startRunning() }
                } catch {
                    Task { @MainActor in failed(error as? Failure ?? .noCamera) }
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.lock.lock(); self.latest = nil; self.fresh = false; self.lock.unlock()
        }
    }

    // The newest frame if it has not been handed out yet
    func takeFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard fresh else { return nil }
        fresh = false
        return latest
    }

    private func configure(_ position: Position) throws {
        let wanted: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wanted) else { throw Failure.noCamera }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        // 720p is plenty: the artwork is at most 600 px
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure.noCamera }
        session.addInput(input)
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // Upright portrait frames; the front camera mirrored like a selfie
        if let connection = session.outputs.first?.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buffer; fresh = true; lock.unlock()
    }
}
