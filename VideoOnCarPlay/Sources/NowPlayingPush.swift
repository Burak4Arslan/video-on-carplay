import MediaPlayer
import ObjectiveC

// iOS batches Now Playing updates and passes them on at most every half second. Measured in the simulator: sending
// 4, 30 or 60 artworks per second, only 2 per second ever reached iOS's media service (mediaremoted).
// MPNowPlayingInfoCenter keeps the time of the last push in the private `_pushDate` ivar; moving it into the past
// before each update sends every frame right away (30 of 30, 60 of 60). It is private: if the ivar is renamed or
// missing, nothing is touched.
enum NowPlayingPush {
    static let isAvailable: Bool = {
        let cls: AnyClass = MPNowPlayingInfoCenter.self
        return class_getInstanceVariable(cls, "_pushDate") != nil && class_getInstanceVariable(cls, "_accessQueue") != nil
    }()

    // Called right before the next nowPlayingInfo assignment
    static func skipWait(_ center: MPNowPlayingInfoCenter = .default()) {
        guard isAvailable, let queue = center.value(forKey: "accessQueue") as? DispatchQueue else { return }
        // The ivar is read and written on this queue; change it on the same queue
        queue.sync { center.setValue(Date.distantPast, forKey: "pushDate") }
    }
}

// Counts how often iOS asks for the artwork image: every request is a frame that was really passed on.
// The artwork block runs on iOS's own queue, hence the lock.
final class DeliveredFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() {
        lock.lock(); count += 1; lock.unlock()
    }

    func take() -> Int {
        lock.lock(); defer { count = 0; lock.unlock() }
        return count
    }
}
