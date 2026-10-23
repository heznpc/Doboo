#if canImport(CoreGraphics)
  import CoreGraphics
#else
  import Foundation
#endif

struct BlobInteractionState: Equatable {
  enum Expression: Equatable {
    case calm
    case squint
    case surprised
  }

  private(set) var touch = CGPoint.zero
  private(set) var isPressed = false

  var intensity: CGFloat {
    guard isPressed else { return 0 }
    return min(1, 0.48 + hypot(touch.x, touch.y) * 0.52)
  }

  var expression: Expression {
    guard isPressed else { return .calm }
    return intensity > 0.82 ? .surprised : .squint
  }

  mutating func press(at location: CGPoint, in size: CGSize) {
    isPressed = true
    touch = Self.normalized(location: location, in: size)
  }

  @discardableResult
  mutating func release() -> CGPoint {
    let recoil = touch
    isPressed = false
    touch = .zero
    return recoil
  }

  static func normalized(location: CGPoint, in size: CGSize) -> CGPoint {
    guard size.width > 0, size.height > 0 else { return .zero }
    return CGPoint(
      x: clamp((location.x / size.width) * 2 - 1),
      y: clamp((location.y / size.height) * 2 - 1)
    )
  }

  private static func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(-1, value))
  }
}
