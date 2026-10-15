import CoreGraphics
import Foundation

struct BlobInteractionState: Equatable {
  enum Expression: Equatable {
    case calm
    case squint
    case surprised
  }

  struct Release: Equatable {
    let id = UUID()
    let touch: CGPoint
    let strength: CGFloat
  }
  private(set) var lastRelease: Release?
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

  @discardableResult
  mutating func press(at location: CGPoint, in size: CGSize) -> Bool {
    guard Self.isValid(location: location, in: size) else {
      cancel()
      return false
    }

    lastRelease = nil
    isPressed = true
    touch = Self.normalized(location: location, in: size)
    return true
  }

  @discardableResult
  mutating func release() -> CGPoint {
    guard isPressed else { return .zero }
    let recoil = touch
    let strength = intensity
    cancel()
    lastRelease = Release(touch: recoil, strength: strength)
    return recoil
  }

  /// Ends an interrupted interaction without generating a release response.
  mutating func cancel() {
    isPressed = false
    touch = .zero
    lastRelease = nil
  }

  static func normalized(location: CGPoint, in size: CGSize) -> CGPoint {
    guard isValid(location: location, in: size) else { return .zero }
    return CGPoint(
      x: normalized(location.x, extent: size.width),
      y: normalized(location.y, extent: size.height)
    )
  }

  private static func isValid(location: CGPoint, in size: CGSize) -> Bool {
    location.x.isFinite && location.y.isFinite
      && size.width.isFinite && size.height.isFinite
      && size.width > 0 && size.height > 0
  }

  private static func normalized(_ coordinate: CGFloat, extent: CGFloat) -> CGFloat {
    // Clamp before dividing so even tiny valid layouts and distant drags stay finite.
    let bounded = min(extent, max(0, coordinate))
    return (bounded / extent) * 2 - 1
  }
}
