import Foundation

/// Tracks activity ownership, per-activity expiration generations, and disconnect accounting.
struct ActivityLifecycle {
    private(set) var activities: [UUID: String] = [:]
    private(set) var expirationDeadlines: [UUID: UInt64] = [:]
    private(set) var disconnectedCount = 0

    @discardableResult
    mutating func start(animation: String, deadline: UInt64) -> UUID {
        let id = UUID()
        activities[id] = animation
        expirationDeadlines[id] = deadline
        return id
    }

    mutating func keepalive(_ id: UUID, deadline: UInt64) -> Bool {
        guard activities[id] != nil else { return false }
        expirationDeadlines[id] = deadline
        return true
    }

    @discardableResult
    mutating func stop(_ id: UUID) -> String? {
        expirationDeadlines.removeValue(forKey: id)
        return activities.removeValue(forKey: id)
    }

    /// Expires an activity only for its current deadline and increments the disconnect count once.
    @discardableResult
    mutating func expire(_ id: UUID, deadline: UInt64) -> String? {
        guard expirationDeadlines[id] == deadline,
              let animation = activities.removeValue(forKey: id) else { return nil }
        expirationDeadlines.removeValue(forKey: id)
        disconnectedCount += 1
        return animation
    }

    func animation(for id: UUID) -> String? {
        activities[id]
    }

    func deadline(for id: UUID) -> UInt64? {
        expirationDeadlines[id]
    }

    func activityCount(for animation: String) -> Int {
        activities.values.reduce(into: 0) { count, value in
            if value == animation { count += 1 }
        }
    }

    mutating func resetDisconnectedCount() {
        disconnectedCount = 0
    }

    mutating func reset() {
        activities.removeAll()
        expirationDeadlines.removeAll()
        disconnectedCount = 0
    }
}
