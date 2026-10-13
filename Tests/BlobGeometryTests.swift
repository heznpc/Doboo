import CoreGraphics
import Testing

#if canImport(Doboo)
  @testable import Doboo
#else
  @testable import DobooCore
#endif

struct BlobGeometryTests {
  @Test func invalidLayoutsProduceNoDrawingCommands() {
    let invalidRects = [
      CGRect.zero,
      CGRect.null,
      CGRect.infinite,
      CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
      CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
      CGRect(x: 0, y: 0, width: -100, height: 100),
      CGRect(
        x: CGFloat.greatestFiniteMagnitude, y: 0,
        width: CGFloat.greatestFiniteMagnitude, height: 100),
    ]

    for rect in invalidRects {
      #expect(
        BlobGeometry.controlPoints(in: rect, touch: .zero, pressure: 0, breath: 0, recoil: 0)
          .isEmpty
      )
    }
  }

  @Test func nonfiniteAnimationInputsFallBackToRestingGeometry() {
    let rect = CGRect(x: 10, y: 20, width: 180, height: 220)
    let resting = BlobGeometry.controlPoints(
      in: rect, touch: .zero, pressure: 0, breath: 0, recoil: 0
    )
    let sanitized = BlobGeometry.controlPoints(
      in: rect, touch: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
      pressure: .nan, breath: -.infinity, recoil: .infinity
    )

    #expect(sanitized == resting)
    #expect(sanitized.count == 20)
    #expect(sanitized.allSatisfy { $0.x.isFinite && $0.y.isFinite })
  }

  @Test func animationExtremesStayWithinTheLayout() {
    let rect = CGRect(x: -40, y: 20, width: 180, height: 220)
    let extremes: [CGFloat] = [-.greatestFiniteMagnitude, -1, 0, 1, .greatestFiniteMagnitude]

    for pressure in extremes {
      for recoil in extremes {
        for breath in extremes {
          let points = BlobGeometry.controlPoints(
            in: rect,
            touch: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude),
            pressure: pressure, breath: breath, recoil: recoil
          )

          #expect(points.count == 20)
          #expect(points.allSatisfy { point in
            point.x.isFinite && point.y.isFinite
              && point.x >= rect.minX && point.x <= rect.maxX
              && point.y >= rect.minY && point.y <= rect.maxY
          })
        }
      }
    }
  }

  @Test func veryLargeFiniteLayoutsAndMidpointsDoNotOverflow() {
    let extent = CGFloat.greatestFiniteMagnitude
    let points = BlobGeometry.controlPoints(
      in: CGRect(x: 0, y: 0, width: extent, height: extent),
      touch: CGPoint(x: 1, y: -1), pressure: 1, breath: 1, recoil: 1
    )

    #expect(points.count == 20)
    #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let point = CGPoint(x: extent, y: -extent)
    #expect(BlobGeometry.midpoint(point, point) == point)
  }

  @Test func geometryRespectsTheDrawingOrigin() {
    let base = BlobGeometry.controlPoints(
      in: CGRect(x: 0, y: 0, width: 180, height: 220),
      touch: CGPoint(x: 0.8, y: -0.6), pressure: 1, breath: 0.5, recoil: -0.3
    )
    let translated = BlobGeometry.controlPoints(
      in: CGRect(x: -40, y: 20, width: 180, height: 220),
      touch: CGPoint(x: 0.8, y: -0.6), pressure: 1, breath: 0.5, recoil: -0.3
    )

    #expect(base.count == translated.count)
    for (original, shifted) in zip(base, translated) {
      #expect(abs(shifted.x - (original.x - 40)) < 0.0001)
      #expect(abs(shifted.y - (original.y + 20)) < 0.0001)
    }
  }
}
