import CoreGraphics

/// The finite control points shared by the renderer and its geometry tests.
enum BlobGeometry {
  static func controlPoints(
    in rect: CGRect,
    touch: CGPoint,
    pressure: CGFloat,
    breath: CGFloat,
    recoil: CGFloat
  ) -> [CGPoint] {
    guard !rect.isNull, !rect.isInfinite,
      rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.size.width.isFinite, rect.size.height.isFinite,
      rect.size.width > 0, rect.size.height > 0,
      (rect.origin.x + rect.width).isFinite,
      (rect.origin.y + rect.height).isFinite
    else { return [] }

    let touch = CGPoint(x: bounded(touch.x, to: -1...1), y: bounded(touch.y, to: -1...1))
    let pressure = bounded(pressure, to: 0...1)
    let breath = bounded(breath, to: -1...1)
    let recoil = bounded(recoil, to: -1...1)
    let center = CGPoint(
      x: rect.origin.x + rect.width * 0.5,
      y: rect.origin.y + rect.height * 0.5
    )
    let baseRadius = min(rect.width, rect.height) * (0.39 + breath * 0.008)
    let contactAngle = atan2(touch.y, touch.x)
    let contactDistance = min(1, hypot(touch.x, touch.y))
    let count = 20

    return (0..<count).map { index in
      let angle = (CGFloat(index) / CGFloat(count)) * .pi * 2
      let delta = angularDistance(angle, contactAngle)
      let contactFalloff = exp(-pow(delta / 0.48, 2))
      let oppositeFalloff = exp(-pow((abs(delta) - .pi) / 1.05, 2))
      let idleRipple = sin(angle * 3 + breath * .pi) * 0.012
      let indentation = pressure * contactDistance * contactFalloff * 0.20
      let bulge = pressure * oppositeFalloff * 0.055
      let springRipple = recoil * cos(angle * 2) * 0.075
      let radius = baseRadius * (1 + idleRipple - indentation + bulge + springRipple)

      return CGPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius * (1 - pressure * 0.07 + recoil * 0.06)
      )
    }
  }

  static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
    // Halve first to avoid overflowing when both finite points are very large.
    CGPoint(x: lhs.x * 0.5 + rhs.x * 0.5, y: lhs.y * 0.5 + rhs.y * 0.5)
  }

  private static func bounded(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
    guard value.isFinite else { return 0 }
    return min(range.upperBound, max(range.lowerBound, value))
  }

  private static func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    let distance = (lhs - rhs).truncatingRemainder(dividingBy: .pi * 2)
    if distance > .pi { return distance - .pi * 2 }
    if distance < -.pi { return distance + .pi * 2 }
    return distance
  }
}
