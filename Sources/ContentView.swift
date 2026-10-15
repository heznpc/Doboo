import SwiftUI
import WatchKit

struct ContentView: View {
  @Bindable var library: CharacterLibrary
  @Bindable var tasks: TaskConnection
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @AppStorage("doboo.hasSeenWelcome") private var hasSeenWelcome = false
  @AppStorage("doboo.hapticsEnabled") private var hapticsEnabled = true
  @AppStorage("doboo.motionEnabled") private var motionEnabled = true

  @GestureState private var isGestureActive = false
  @State private var interaction = BlobInteractionState()
  @State private var hasPlayedPressHaptic = false
  @State private var presentedSheet: DobooSheet?
  @State private var accessiblePlayTask: Task<Void, Never>?
  @State private var accessiblePlayID: UUID?

  private var isForeground: Bool {
    scenePhase == .active && !isLuminanceReduced
  }

  private var canInteract: Bool {
    isForeground && presentedSheet == nil
  }

  private var canAnimate: Bool {
    canInteract && motionEnabled && !reduceMotion
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(library.selected.name).font(.caption.weight(.semibold)).lineLimit(1)
        .accessibilityIdentifier("character.activeName")
      GeometryReader { proxy in
        ZStack {
          ambientDots

          TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !canAnimate)) { timeline in
            PackCharacterView(
              pack: library.selected.watchRepresentation,
              interaction: interaction,
              phase: canAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0,
              motionEnabled: canAnimate
            )
          }
        }
        .contentShape(Rectangle())
        .gesture(blobGesture(in: proxy.size))
        .allowsHitTesting(canInteract)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(library.selected.name)
        .accessibilityIdentifier("character.play")
        .accessibilityValue(
          interaction.isPressed
            ? Text("character.state.pressed") : Text("character.state.resting")
        )
        .accessibilityHint("character.hint")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { playAccessibly(in: proxy.size) }
        .accessibilityAction(named: "character.action.squeeze") {
          playAccessibly(in: proxy.size)
        }
        .accessibilityAction(named: "character.action.left") { playAccessibly(in: proxy.size, point: .init(x: 0.2, y: 0.5)) }
        .accessibilityAction(named: "character.action.right") { playAccessibly(in: proxy.size, point: .init(x: 0.8, y: 0.5)) }
        .accessibilityAction(named: "character.action.top") { playAccessibly(in: proxy.size, point: .init(x: 0.5, y: 0.2)) }
        .accessibilityAction(named: "character.action.bottom") { playAccessibly(in: proxy.size, point: .init(x: 0.5, y: 0.8)) }
      }

      Button { present(.tasks) } label: {
        Label(tasks.tasks.first?.label ?? "작업 보기", systemImage: "bubble.left")
          .font(.caption2).lineLimit(1)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("home.tasks")
      .disabled(!isForeground)
      .padding(.vertical, 4)

      HStack {
        Button {
          present(.help)
        } label: {
          Image(systemName: "questionmark.circle")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("help.title")

        Spacer(minLength: 0)

        Button { present(.characters) } label: {
          Image(systemName: "person.crop.square").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("library.title")

        Spacer(minLength: 0)

        Button {
          present(.settings)
        } label: {
          Image(systemName: "gearshape")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("settings.title")
      }
      .font(.body)
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .disabled(!isForeground)
      .opacity(isLuminanceReduced ? 0 : 1)
      .accessibilityHidden(isLuminanceReduced)
    }
    .background {
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.06, blue: 0.16), Color(red: 0.03, green: 0.02, blue: 0.08),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
    .sheet(item: $presentedSheet) { sheet in
      switch sheet {
      case .welcome:
        DobooWelcomeView {
          hasSeenWelcome = true
          presentedSheet = nil
        }
      case .settings:
        DobooSettingsView(hapticsEnabled: $hapticsEnabled, motionEnabled: $motionEnabled)
      case .help:
        DobooHelpSheetView()
      case .characters:
        WatchLibraryView(library: library)
      case .tasks:
        TaskDashboard(connection: tasks, library: library)
      }
    }
    .alert("library.errorTitle", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
      Button("common.ok", role: .cancel) { library.errorMessage = nil }
    } message: { Text(library.errorMessage ?? "") }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        if presentedSheet != .tasks { await tasks.refresh() }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
    .onChange(of: library.selected.id) { _, _ in cancelInteraction() }
    .onChange(of: library.selected.version) { _, _ in cancelInteraction() }
    .onAppear {
      if !hasSeenWelcome { present(.welcome) }
    }
    .onDisappear { cancelInteraction() }
    .onChange(of: canInteract) { _, enabled in
      if !enabled { cancelInteraction() }
    }
    .onChange(of: canAnimate) { _, enabled in
      if !enabled { cancelInteraction() }
    }
    .onChange(of: isGestureActive) { _, active in
      // SwiftUI resets GestureState for interruptions as well as a normal end.
      // A canceled drag does not call onEnded, so it must release here without a haptic.
      if !active && accessiblePlayID == nil && interaction.isPressed { cancelInteraction() }
    }
  }

  private var ambientDots: some View {
    GeometryReader { proxy in
      ZStack {
        Circle().fill(.white.opacity(0.18)).frame(width: 3)
          .position(x: proxy.size.width * 0.14, y: proxy.size.height * 0.17)
        Circle().fill(.white.opacity(0.12)).frame(width: 2)
          .position(x: proxy.size.width * 0.83, y: proxy.size.height * 0.29)
        Circle().fill(.white.opacity(0.10)).frame(width: 4)
          .position(x: proxy.size.width * 0.87, y: proxy.size.height * 0.83)
        Circle().fill(.white.opacity(0.08)).frame(width: 3)
          .position(x: proxy.size.width * 0.16, y: proxy.size.height * 0.87)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func blobGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isGestureActive) { _, active, _ in active = true }
      .onChanged { value in
        guard canInteract else {
          cancelInteraction()
          return
        }
        if accessiblePlayID != nil { cancelInteraction() }
        guard interaction.press(at: value.location, in: size) else {
          cancelInteraction()
          return
        }
        if !hasPlayedPressHaptic {
          playHaptic(.click)
          hasPlayedPressHaptic = true
        }
      }
      .onEnded { _ in
        guard accessiblePlayID == nil else { return }
        guard canInteract else {
          cancelInteraction()
          return
        }
        releaseInteraction()
      }
  }

  private func releaseInteraction() {
    guard interaction.isPressed else { return }
    interaction.release()
    hasPlayedPressHaptic = false
    playHaptic(.directionUp)
  }

  private func cancelInteraction() {
    accessiblePlayTask?.cancel()
    accessiblePlayTask = nil
    accessiblePlayID = nil
    hasPlayedPressHaptic = false
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { interaction.cancel() }
  }

  private func playAccessibly(in size: CGSize, point: UnitPoint = .init(x: 0.7, y: 0.45)) {
    guard canInteract else { return }
    cancelInteraction()
    guard interaction.press(at: CGPoint(x: size.width * point.x, y: size.height * point.y), in: size)
    else { return }
    playHaptic(.click)

    let playID = UUID()
    accessiblePlayID = playID
    accessiblePlayTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(300))
      } catch {
        return
      }
      // Canceled or superseded actions must never release a newer touch.
      guard !Task.isCancelled, accessiblePlayID == playID else { return }
      releaseInteraction()
      accessiblePlayID = nil
      accessiblePlayTask = nil
    }
  }

  private func playHaptic(_ type: WKHapticType) {
    guard hapticsEnabled && canInteract else { return }
    WKInterfaceDevice.current().play(type)
  }

  private func present(_ sheet: DobooSheet) {
    cancelInteraction()
    presentedSheet = sheet
  }
}

private enum DobooSheet: String, Identifiable {
  case welcome, settings, help, characters, tasks

  var id: String { rawValue }
}

#Preview {
  ContentView(library: CharacterLibrary(), tasks: TaskConnection())
}
