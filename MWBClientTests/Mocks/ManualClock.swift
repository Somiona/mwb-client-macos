import Foundation

class ManualClock {
    var currentTime: TimeInterval = 0

    func advance(by milliseconds: TimeInterval) {
        currentTime += milliseconds
    }

    func now() -> TimeInterval {
        return currentTime
    }
}
