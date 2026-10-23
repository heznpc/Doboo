#if canImport(CoreGraphics)
  import CoreGraphics
#else
  import Foundation
#endif
import Testing

#if canImport(Doboo)
  @testable import Doboo
#else
  @testable import DobooCore
#endif

struct BlobInteractionStateTests {
  @Test func normalizesAndClampsTouchLocation() {
    let size = CGSize(width: 100, height: 200)

    #expect(BlobInteractionState.normalized(location: CGPoint(x: 50, y: 100), in: size) == .zero)
    #expect(
      BlobInteractionState.normalized(location: CGPoint(x: 150, y: -20), in: size)
        == CGPoint(x: 1, y: -1))
  }

  @Test func pressAndReleasePreserveRecoilDirection() {
    var state = BlobInteractionState()
    state.press(at: CGPoint(x: 80, y: 20), in: CGSize(width: 100, height: 100))

    #expect(state.isPressed)
    #expect(abs(state.touch.x - 0.6) < 0.0001)
    #expect(abs(state.touch.y + 0.6) < 0.0001)
    #expect(state.expression == .surprised)

    let recoil = state.release()

    #expect(abs(recoil.x - 0.6) < 0.0001)
    #expect(abs(recoil.y + 0.6) < 0.0001)
    #expect(!state.isPressed)
    #expect(state.touch == .zero)
    #expect(state.expression == .calm)
  }

  @Test func expressionEscalatesAsTouchMovesOutward() {
    var state = BlobInteractionState()
    let size = CGSize(width: 100, height: 100)

    state.press(at: CGPoint(x: 50, y: 50), in: size)
    #expect(state.expression == .squint)

    state.press(at: CGPoint(x: 100, y: 50), in: size)
    #expect(state.expression == .surprised)
  }

  @Test func zeroSizeProducesSafeCenter() {
    #expect(
      BlobInteractionState.normalized(
        location: CGPoint(x: 20, y: 20),
        in: .zero
      ) == .zero
    )
  }
}
