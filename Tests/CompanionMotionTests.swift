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

  @Test func idleStartsNeutralAndStopsForReducedMotionOrInvalidTime() {
    #expect(CompanionMotion.idle(elapsed: 0, enabled: true) == .neutral)
    for elapsed in [-123.0, 0, 1, 1_800_000_000, .greatestFiniteMagnitude] {
      #expect(CompanionMotion.idle(elapsed: elapsed, enabled: false) == .neutral)
    }
    for elapsed in [Double.nan, .infinity, -.infinity] {
      #expect(CompanionMotion.idle(elapsed: elapsed, enabled: true) == .neutral)
      #expect(CompanionMotion.idle(elapsed: elapsed, enabled: false) == .neutral)
    }
  }

  @Test func idleMotionIsVisibleButAlwaysBounded() {
    let times = (0..<720).map { Double($0) / 4 } + [-1_800_000_000, 1_800_000_000, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    let poses = times.map { CompanionMotion.idle(elapsed: $0, enabled: true) }
    #expect(poses.allSatisfy { abs($0.x) <= 0.07 && abs($0.y) <= 0.035 && abs($0.rotationDegrees) <= 4 })
    #expect(poses.allSatisfy { abs($0.gazeX) <= 1 && abs($0.gazeY) <= 1 })
    // Ensure the movement remains noticeable instead of merely nonzero.
    #expect(poses.map(\.x).max()! - poses.map(\.x).min()! > 0.10)
    #expect(poses.map(\.y).max()! - poses.map(\.y).min()! > 0.05)
    #expect(poses.map(\.rotationDegrees).max()! - poses.map(\.rotationDegrees).min()! > 6)
    #expect(poses.map(\.gazeX).max()! - poses.map(\.gazeX).min()! > 1)
    #expect(poses.map(\.gazeY).max()! - poses.map(\.gazeY).min()! > 0.5)
  }

  @Test func idlePoseChangesSmoothlyAtFrameIntervalsIncludingAbsoluteDates() {
    for origin in [0.0, 1_800_000_000] {
      for sample in 0..<600 {
        let elapsed = origin + Double(sample) / 20
        let before = CompanionMotion.idle(elapsed: elapsed, enabled: true)
        let after = CompanionMotion.idle(elapsed: elapsed + 1.0 / 60, enabled: true)
        #expect(abs(after.x - before.x) < 0.001)
        #expect(abs(after.y - before.y) < 0.001)
        #expect(abs(after.rotationDegrees - before.rotationDegrees) < 0.05)
        #expect(abs(after.gazeX - before.gazeX) < 0.02)
        #expect(abs(after.gazeY - before.gazeY) < 0.02)
      }
    }
  }

  @Test func holdingTheClockKeepsTheSamePoseWithoutHiddenAnimationState() {
    let held = CompanionMotion.idle(elapsed: 123.45, enabled: true)
    _ = CompanionMotion.idle(elapsed: 9_999, enabled: true)
    _ = CompanionMotion.idle(elapsed: 123.45, enabled: false)
    #expect(CompanionMotion.idle(elapsed: 123.45, enabled: true) == held)
    #expect(held != .neutral)
  }
}
