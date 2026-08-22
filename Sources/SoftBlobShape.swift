import SwiftUI

struct SoftBlobShape: Shape {
  var touch: CGPoint
  var pressure: CGFloat
  var breath: CGFloat
  var recoil: CGFloat

  var animatableData:
    AnimatablePair<
      AnimatablePair<CGFloat, CGFloat>,
      AnimatablePair<CGFloat, CGFloat>
    >
  {
    get {
      AnimatablePair(
        AnimatablePair(touch.x, touch.y),
        AnimatablePair(pressure, recoil)
      )
    }
    set {
      touch = CGPoint(x: newValue.first.first, y: newValue.first.second)
      pressure = newValue.second.first
      recoil = newValue.second.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let baseRadius = min(rect.width, rect.height) * (0.39 + breath * 0.008)
    let contactAngle = atan2(touch.y, touch.x)
    let contactDistance = min(1, hypot(touch.x, touch.y))
    let count = 20

    let points = (0..<count).map { index -> CGPoint in
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

    var path = Path()
    let firstMidpoint = midpoint(points[count - 1], points[0])
    path.move(to: firstMidpoint)

    for index in 0..<count {
      let point = points[index]
      let next = points[(index + 1) % count]
      path.addQuadCurve(to: midpoint(point, next), control: point)
    }

    path.closeSubpath()
    return path
  }

  private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
    CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
  }

  private func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    var distance = lhs - rhs
    while distance > .pi { distance -= .pi * 2 }
    while distance < -.pi { distance += .pi * 2 }
    return distance
  }
}
