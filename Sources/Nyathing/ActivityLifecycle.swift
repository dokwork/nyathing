import Foundation

/// Reserves cancelled protocol IDs until their monotonic deadlines.
struct CancelledActivityIDs {
  private var deadlines: [String: DispatchTime] = [:]

  /// Records a cancellation and returns the deadline for scheduled cleanup.
  mutating func reserve(_ id: String, for duration: TimeInterval, now: DispatchTime = .now())
    -> DispatchTime
  {
    let deadline = now + duration
    deadlines[id] = deadline
    return deadline
  }

  /// Checks the reservation without consuming it or extending its lifetime.
  func contains(_ id: String, now: DispatchTime = .now()) -> Bool {
    guard let deadline = deadlines[id] else { return false }
    return now < deadline
  }

  /// Removes only the reservation associated with this cleanup callback.
  mutating func remove(_ id: String, deadline: DispatchTime) {
    guard deadlines[id] == deadline else { return }
    deadlines.removeValue(forKey: id)
  }
}

/// Tracks activity ownership, per-activity expiration generations, and disconnect accounting.
struct ActivityLifecycle {
  static let missingDescription = "No description provided"

  private(set) var activities: [UUID: String] = [:]
  private(set) var descriptions: [UUID: String] = [:]
  private(set) var expirationDeadlines: [UUID: UInt64] = [:]
  private(set) var timedOutActivities: [ExpiredActivity] = []
  private(set) var disconnectedCount = 0

  struct ExpiredActivity: Equatable, Identifiable {
    let id: UUID
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
    let expired = ExpiredActivity(id: id, animation: animation, description: description)
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

  mutating func acknowledgeTimeout(_ id: UUID) -> Bool {
    guard let index = timedOutActivities.firstIndex(where: { $0.id == id }) else { return false }
    timedOutActivities.remove(at: index)
    disconnectedCount = max(0, disconnectedCount - 1)
    return true
  }

  mutating func reset() {
    activities.removeAll()
    descriptions.removeAll()
    expirationDeadlines.removeAll()
    timedOutActivities.removeAll()
    disconnectedCount = 0
  }
}
