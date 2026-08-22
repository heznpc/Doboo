import SwiftUI
import WatchKit

struct ContentView: View {
  @State private var interaction = BlobInteractionState()
  @State private var recoil: CGFloat = 0
  @State private var hasPlayedPressHaptic = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 0.08, green: 0.06, blue: 0.16), Color(red: 0.03, green: 0.02, blue: 0.08),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        ambientDots

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          DobooCharacterView(
            interaction: interaction,
            recoil: recoil,
            phase: timeline.date.timeIntervalSinceReferenceDate
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
        }
      }
      .contentShape(Rectangle())
      .gesture(blobGesture(in: proxy.size))
    }
  }

  private var ambientDots: some View {
    ZStack {
      Circle().fill(.white.opacity(0.18)).frame(width: 3).offset(x: -70, y: -72)
      Circle().fill(.white.opacity(0.12)).frame(width: 2).offset(x: 62, y: -48)
      Circle().fill(.white.opacity(0.10)).frame(width: 4).offset(x: 71, y: 64)
      Circle().fill(.white.opacity(0.08)).frame(width: 3).offset(x: -65, y: 72)
    }
    .allowsHitTesting(false)
  }

  private func blobGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !hasPlayedPressHaptic {
          WKInterfaceDevice.current().play(.click)
          hasPlayedPressHaptic = true
        }

        interaction.press(at: value.location, in: size)
      }
      .onEnded { _ in
        let releasedTouch = interaction.release()
        hasPlayedPressHaptic = false
        WKInterfaceDevice.current().play(.directionUp)

        recoil = min(1, 0.35 + hypot(releasedTouch.x, releasedTouch.y) * 0.65)
        Task { @MainActor in
          withAnimation(.spring(response: 0.52, dampingFraction: 0.38)) {
            recoil = 0
          }
        }
      }
  }
}

#Preview {
  ContentView()
}
