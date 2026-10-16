import SwiftUI

struct DobooCharacterView: View {
  let interaction: BlobInteractionState
  let recoil: CGFloat
  let phase: TimeInterval
  let motionEnabled: Bool
  var tint: Color = Color(red: 1.0, green: 0.55, blue: 0.38)
  var idleGaze: CGPoint = .zero

  private var breath: CGFloat {
    motionEnabled ? CGFloat(sin(phase * 2.2)) : 0
  }

  private var blink: CGFloat {
    guard motionEnabled else { return 1 }
    let cycle = phase.truncatingRemainder(dividingBy: 4.4)
    guard cycle > 4.05 else { return 1 }
    return min(1, max(0.12, abs(CGFloat(cycle - 4.22)) * 9))
  }

  private var eyeHeight: CGFloat {
    switch interaction.expression {
    case .calm: blink
    case .squint: 0.28
    case .surprised: 1.25
    }
  }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let pressure = interaction.intensity
      let touch = interaction.touch

      ZStack {
        SoftBlobShape(
          touch: touch,
          pressure: pressure,
          breath: breath,
          recoil: recoil
        )
        .fill(
          RadialGradient(
            colors: [
              tint.opacity(0.75), tint,
            ],
            center: UnitPoint(x: 0.35, y: 0.27),
            startRadius: 2,
            endRadius: side * 0.55
          )
        )
        .overlay {
          SoftBlobShape(
            touch: touch,
            pressure: pressure,
            breath: breath,
            recoil: recoil
          )
          .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
        }
        .shadow(color: tint.opacity(0.35), radius: 12, y: 7)

        face(side: side, touch: touch, pressure: pressure)
      }
      .scaleEffect(
        x: 1 + abs(touch.x) * pressure * 0.055 + recoil * 0.035,
        y: 1 - pressure * 0.055 + recoil * 0.075
      )
      .offset(x: touch.x * pressure * 5, y: touch.y * pressure * 4)
      .animation(
        motionEnabled
          ? .interactiveSpring(
            response: interaction.isPressed ? 0.18 : 0.52,
            dampingFraction: interaction.isPressed ? 0.68 : 0.48
          ) : nil,
        value: interaction
      )
      .transaction { transaction in
        if !motionEnabled { transaction.disablesAnimations = true }
      }
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func face(side: CGFloat, touch: CGPoint, pressure: CGFloat) -> some View {
    let gazeX = interaction.isPressed ? touch.x * side * 0.012 : idleGaze.x * side * 0.025
    let gazeY = interaction.isPressed ? touch.y * side * 0.010 : idleGaze.y * side * 0.020
    let eyeWidth = side * 0.075
    let baseEyeHeight = side * 0.105

    VStack(spacing: side * 0.045) {
      HStack(spacing: side * 0.14) {
        eye(width: eyeWidth, height: baseEyeHeight, gazeX: gazeX, gazeY: gazeY)
        eye(width: eyeWidth, height: baseEyeHeight, gazeX: gazeX, gazeY: gazeY)
      }

      mouth(side: side)
    }
    .offset(
      x: touch.x * pressure * side * 0.025, y: side * 0.015 + touch.y * pressure * side * 0.018)
  }

  private func eye(width: CGFloat, height: CGFloat, gazeX: CGFloat, gazeY: CGFloat) -> some View {
    Capsule()
      .fill(Color(red: 0.20, green: 0.10, blue: 0.12))
      .frame(width: width, height: max(2, height * eyeHeight))
      .overlay(alignment: .topLeading) {
        if interaction.expression != .squint {
          Circle()
            .fill(.white.opacity(0.82))
            .frame(width: width * 0.25)
            .padding(width * 0.16)
        }
      }
      .offset(x: gazeX, y: gazeY)
  }

  @ViewBuilder
  private func mouth(side: CGFloat) -> some View {
    switch interaction.expression {
    case .surprised:
      Ellipse()
        .fill(Color(red: 0.28, green: 0.08, blue: 0.10))
        .frame(width: side * 0.07, height: side * 0.10)
    case .calm, .squint:
      SmileShape(curve: interaction.expression == .calm ? 1 : 0.35)
        .stroke(
          Color(red: 0.28, green: 0.08, blue: 0.10),
          style: StrokeStyle(lineWidth: max(2, side * 0.018), lineCap: .round)
        )
        .frame(width: side * 0.16, height: side * 0.075)
    }
  }
}

private struct SmileShape: Shape {
  var curve: CGFloat

  var animatableData: CGFloat {
    get { curve }
    set { curve = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.28))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28),
      control: CGPoint(x: rect.midX, y: rect.minY + rect.height * curve)
    )
    return path
  }
}
