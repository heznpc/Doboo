import Foundation

enum CompanionMotion {
  /// A single release settles in under a second; it never starts a repeating task.
  static func rebound(elapsed: TimeInterval, strength: Double, enabled: Bool) -> Double {
    guard enabled, elapsed.isFinite, strength.isFinite, elapsed >= 0, elapsed < 0.85 else { return 0 }
    return min(1, max(0, strength)) * exp(-elapsed * 6) * sin(elapsed * 20)
  }
}
