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
    let points = BlobGeometry.controlPoints(
      in: rect, touch: touch, pressure: pressure, breath: breath, recoil: recoil
    )

    var path = Path()
    guard let first = points.first, let last = points.last else { return path }
    let firstMidpoint = BlobGeometry.midpoint(last, first)
    path.move(to: firstMidpoint)

    for index in points.indices {
      let point = points[index]
      let next = points[(index + 1) % points.count]
      path.addQuadCurve(to: BlobGeometry.midpoint(point, next), control: point)
    }

    path.closeSubpath()
    return path
  }
}
