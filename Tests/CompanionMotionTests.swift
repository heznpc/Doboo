import Foundation
import CoreGraphics
import Testing
#if canImport(Doboo)
@testable import Doboo
#else
@testable import DobooCore
#endif

struct CompanionMotionTests {
  @Test func onlyACompletedReleaseProducesAnImpulse() {
    var touch = BlobInteractionState()
    let size = CGSize(width: 100, height: 100)
    touch.press(at: CGPoint(x: 90, y: 50), in: size)
    touch.cancel()
    #expect(touch.lastRelease == nil)
    touch.press(at: CGPoint(x: 90, y: 50), in: size)
    touch.release()
    let release = touch.lastRelease
    #expect(release != nil)
    touch.release()
    #expect(touch.lastRelease == release)
    touch.press(at: CGPoint(x: 50, y: 50), in: size)
    #expect(touch.lastRelease == nil)
  }

  @Test func reboundSettlesAndHonorsReducedMotion() {
    #expect(CompanionMotion.rebound(elapsed: 0.06, strength: 1, enabled: true) > 0)
    #expect(CompanionMotion.rebound(elapsed: 1, strength: 1, enabled: true) == 0)
    #expect(CompanionMotion.rebound(elapsed: 0.06, strength: 1, enabled: false) == 0)
    for elapsed in [Double.nan, .infinity, -1] {
      #expect(CompanionMotion.rebound(elapsed: elapsed, strength: 1, enabled: true) == 0)
    }
    #expect(CompanionMotion.rebound(elapsed: 0.06, strength: .nan, enabled: true) == 0)
  }

}
