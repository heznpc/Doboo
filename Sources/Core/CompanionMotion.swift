import Foundation

enum CompanionMotion {
  struct IdlePose: Equatable, Sendable {
    /// Translation as a fraction of the character's shorter side.
    let x: Double
    let y: Double
    let rotationDegrees: Double
    let gazeX: Double
    let gazeY: Double

    static let neutral = IdlePose(x: 0, y: 0, rotationDegrees: 0, gazeX: 0, gazeY: 0)
  }

  /// A pose sampled from the caller's clock; no animation or clock is retained.
  static func idle(elapsed: TimeInterval, enabled: Bool) -> IdlePose {
    guard enabled, elapsed.isFinite else { return .neutral }
    func wave(_ period: TimeInterval) -> Double {
      // Reduce before multiplying so absolute Date values and large finite
      // inputs stay precise and never overflow the trigonometric argument.
      sin(elapsed.truncatingRemainder(dividingBy: period) / period * (2 * .pi))
    }
    return IdlePose(
      x: 0.065 * wave(7.6),
      y: 0.030 * wave(5.8),
      rotationDegrees: 3.4 * wave(8.4),
      gazeX: 0.70 * wave(6.8) + 0.18 * wave(9.0),
      gazeY: 0.38 * wave(8.2) - 0.16 * wave(6.2)
    )
  }

  /// A single release settles in under a second; it never starts a repeating task.
  static func rebound(elapsed: TimeInterval, strength: Double, enabled: Bool) -> Double {
    guard enabled, elapsed.isFinite, strength.isFinite, elapsed >= 0, elapsed < 0.85 else { return 0 }
    return min(1, max(0, strength)) * exp(-elapsed * 6) * sin(elapsed * 20)
  }
}
