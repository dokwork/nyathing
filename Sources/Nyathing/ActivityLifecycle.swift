import Foundation

/// Tracks activity ownership, per-activity expiration generations, and disconnect accounting.
struct ActivityLifecycle {
  static let missingDescription = "No description provided"

  private(set) var activities: [UUID: String] = [:]
  private(set) var descriptions: [UUID: String] = [:]
  private(set) var expirationDeadlines: [UUID: UInt64] = [:]
  private(set) var timedOutActivities: [ExpiredActivity] = []
  private(set) var disconnectedCount = 0

  struct ExpiredActivity: Equatable {
    let animation: String
    let description: String
  }

  @discardableResult
  mutating func start(animation: String, description: String? = nil, deadline: UInt64) -> UUID {
    let id = UUID()
    activities[id] = animation
    descriptions[id] = description ?? Self.missingDescription
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
    descriptions.removeValue(forKey: id)
    return activities.removeValue(forKey: id)
  }

  /// Expires an activity at its current deadline and returns its description for error reporting.
  @discardableResult
  mutating func expire(_ id: UUID, deadline: UInt64) -> ExpiredActivity? {
    guard expirationDeadlines[id] == deadline,
      let animation = activities.removeValue(forKey: id),
      let description = descriptions.removeValue(forKey: id)
    else { return nil }
    expirationDeadlines.removeValue(forKey: id)
    disconnectedCount += 1
    let expired = ExpiredActivity(animation: animation, description: description)
    timedOutActivities.append(expired)
    return expired
  }

  func animation(for id: UUID) -> String? {
    activities[id]
  }

  func deadline(for id: UUID) -> UInt64? {
    expirationDeadlines[id]
  }

  func description(for id: UUID) -> String? {
    descriptions[id]
  }

  func activityCount(for animation: String) -> Int {
    activities.values.reduce(into: 0) { count, value in
      if value == animation { count += 1 }
    }
  }

  mutating func resetDisconnectedCount() {
    disconnectedCount = 0
    timedOutActivities.removeAll()
  }

  mutating func reset() {
    activities.removeAll()
    descriptions.removeAll()
    expirationDeadlines.removeAll()
    timedOutActivities.removeAll()
    disconnectedCount = 0
  }
}
