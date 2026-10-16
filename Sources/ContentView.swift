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
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height * 0.8)
      let characterSize = CGSize(width: side * 1.08, height: side * 1.08)
      TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !canAnimate)) { timeline in
        let phase = canAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0
        let pose = CompanionMotion.idle(elapsed: phase, enabled: canAnimate)

        PackCharacterView(
          pack: library.selected.watchRepresentation,
          interaction: interaction,
          phase: phase,
          motionEnabled: canAnimate,
          idleGaze: CGPoint(x: pose.gazeX, y: pose.gazeY)
        )
        .frame(width: characterSize.width, height: characterSize.height)
        .contentShape(Rectangle())
        .gesture(blobGesture(in: characterSize))
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
        .accessibilityAction { playAccessibly(in: characterSize) }
        .accessibilityAction(named: "character.action.squeeze") {
          playAccessibly(in: characterSize)
        }
        .accessibilityAction(named: "character.action.left") { playAccessibly(in: characterSize, point: .init(x: 0.2, y: 0.5)) }
        .accessibilityAction(named: "character.action.right") { playAccessibly(in: characterSize, point: .init(x: 0.8, y: 0.5)) }
        .accessibilityAction(named: "character.action.top") { playAccessibly(in: characterSize, point: .init(x: 0.5, y: 0.2)) }
        .accessibilityAction(named: "character.action.bottom") { playAccessibly(in: characterSize, point: .init(x: 0.5, y: 0.8)) }
        .rotationEffect(.degrees(pose.rotationDegrees))
        .offset(x: side * pose.x, y: side * pose.y)
        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.47)
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .ignoresSafeArea()
    .background {
      Color.black.ignoresSafeArea()
      RadialGradient(colors: [Color(hex: library.selected.appearance.tint).opacity(0.13), .clear],
                     center: .center, startRadius: 10, endRadius: 140).ignoresSafeArea()
    }
    .overlay(alignment: .bottom) {
      homeControls
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
      case .menu:
        DobooMenuView(name: library.selected.name,
                      widgetSyncError: library.widgetSyncError,
                      onCharacters: { present(.characters) },
                      onSettings: { present(.settings) },
                      onHelp: { present(.help) })
      }
    }
    .alert("library.errorTitle", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
      Button("common.ok", role: .cancel) { library.errorMessage = nil }
    } message: { Text(library.errorMessage ?? "") }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      library.refreshWidgetSnapshot()
      while !Task.isCancelled {
        if presentedSheet != .tasks { await tasks.refresh() }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
    .onChange(of: library.selected.id) { _, _ in cancelInteraction() }
    .onChange(of: library.selected.version) { _, _ in cancelInteraction() }
    .onOpenURL { url in
      guard url.scheme == "doboo", url.host == "companion" else { return }
      cancelInteraction()
      library.refreshWidgetSnapshot(forceReload: true)
      if hasSeenWelcome { presentedSheet = nil }
    }
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

  private var homeControls: some View {
    HStack {
      Button { present(.tasks) } label: {
        Image(systemName: "bubble.left.and.bubble.right")
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel("home.tasks")
      .accessibilityIdentifier("home.tasks")

      Spacer(minLength: 0)

      Button { present(.menu) } label: {
        Image(systemName: "ellipsis")
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel("home.menu")
      .accessibilityIdentifier("home.menu")
    }
    .font(.system(size: 17, weight: .medium))
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.bottom, 2)
    .disabled(!isForeground)
    .opacity(isLuminanceReduced ? 0 : 1)
    .accessibilityHidden(isLuminanceReduced)
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
  case welcome, settings, help, characters, tasks, menu

  var id: String { rawValue }
}

#Preview {
  ContentView(library: CharacterLibrary(), tasks: TaskConnection())
}
