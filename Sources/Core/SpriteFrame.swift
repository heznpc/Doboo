import Foundation

struct SpriteFrame: Equatable, Sendable {
  let column: Int
  let row: Int
  static let width = 192
  static let height = 208
  static let idleDurations = [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]

  static func frame(layout: CharacterPack.Appearance.Sprite.Layout, elapsed: TimeInterval,
                    touchX: Double, touchY: Double, pressed: Bool, motionEnabled: Bool, taskStatus: String? = nil) -> SpriteFrame {
    guard motionEnabled else { return .init(column: 0, row: 0) }
    if !pressed, let status = taskStatus, elapsed.isFinite {
      let action: (row: Int, count: Int, duration: Double)? = switch status {
      case "queued", "needsApproval": (6, 6, 0.15)
      case "running": (7, 6, 0.12)
      case "completed": (8, 6, 0.15)
      case "failed": (5, 8, 0.14)
      default: nil
      }
      if let action { return .init(column: Int(max(0, elapsed).truncatingRemainder(dividingBy: action.duration * Double(action.count)) / action.duration), row: action.row) }
    }
    if pressed, layout == .petsV2, touchX.isFinite, touchY.isFinite, hypot(touchX, touchY) > 0.15 {
      // Pointer coordinates: up = 0°, clockwise, 16 directions.
      let angle = atan2(touchX, -touchY)
      let direction = (Int((angle / (2 * .pi) * 16).rounded()) + 16) % 16
      return .init(column: direction % 8, row: 9 + direction / 8)
    }
    guard !pressed, elapsed.isFinite else { return .init(column: 0, row: 0) }
    let total = idleDurations.reduce(0, +)
    var time = max(0, elapsed).truncatingRemainder(dividingBy: total)
    for (column, duration) in idleDurations.enumerated() {
      if time < duration { return .init(column: column, row: 0) }
      time -= duration
    }
    return .init(column: 0, row: 0)
  }
}
