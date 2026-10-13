import CoreGraphics
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

  @Test func invalidGeometryCancelsAnActivePress() {
    let invalidSizes = [
      CGSize.zero,
      CGSize(width: -1, height: 100),
      CGSize(width: 100, height: -1),
      CGSize(width: CGFloat.nan, height: 100),
      CGSize(width: 100, height: CGFloat.nan),
      CGSize(width: CGFloat.infinity, height: 100),
      CGSize(width: 100, height: CGFloat.infinity),
    ]

    for size in invalidSizes {
      var state = BlobInteractionState()
      state.press(at: CGPoint(x: 100, y: 0), in: CGSize(width: 100, height: 100))

      #expect(!state.press(at: CGPoint(x: 10, y: 10), in: size))
      #expect(state == BlobInteractionState())
      #expect(state.intensity == 0)
      #expect(state.release() == .zero)
    }
  }

  @Test func nonfiniteLocationsNeverReachInteractionState() {
    let invalidLocations = [
      CGPoint(x: CGFloat.nan, y: 0),
      CGPoint(x: 0, y: CGFloat.nan),
      CGPoint(x: CGFloat.infinity, y: 0),
      CGPoint(x: 0, y: -CGFloat.infinity),
    ]
    let size = CGSize(width: 100, height: 100)

    for location in invalidLocations {
      var state = BlobInteractionState()
      state.press(at: CGPoint(x: 80, y: 20), in: size)

      #expect(!state.press(at: location, in: size))
      #expect(state == BlobInteractionState())
      #expect(BlobInteractionState.normalized(location: location, in: size) == .zero)
    }
  }

  @Test func finiteExtremeInputsRemainBounded() {
    var state = BlobInteractionState()
    let accepted = state.press(
      at: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude),
      in: CGSize(width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude)
    )

    #expect(accepted)
    #expect(state.touch == CGPoint(x: 1, y: -1))
    #expect(state.intensity == 1)
    #expect(state.expression == .surprised)
  }

  @Test func cancellationLeavesNoRecoilAndAllowsANewPress() {
    var state = BlobInteractionState()
    let size = CGSize(width: 100, height: 100)
    state.press(at: CGPoint(x: 100, y: 0), in: size)
    state.cancel()

    #expect(state == BlobInteractionState())
    #expect(state.release() == .zero)
    #expect(state.press(at: CGPoint(x: 50, y: 50), in: size))
    #expect(state.isPressed)
    #expect(state.expression == .squint)
  }

  @Test func repeatedReleaseDoesNotRepeatRecoil() {
    var state = BlobInteractionState()
    #expect(state.release() == .zero)
    state.press(at: CGPoint(x: 100, y: 50), in: CGSize(width: 100, height: 100))

    #expect(state.release() == CGPoint(x: 1, y: 0))
    #expect(state.release() == .zero)
    #expect(state == BlobInteractionState())
  }
}
