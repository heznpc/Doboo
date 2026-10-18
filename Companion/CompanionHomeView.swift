import SwiftUI

/// The character stays on the home screen; computer tasks have a separate entry.
struct CompanionHomeView: View {
  @Bindable var library: CharacterLibrary
  @Bindable var tasks: TaskConnection
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingTasks = false

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 24) {
        Spacer(minLength: 12)
        Text(library.selected.name).font(.largeTitle.weight(.semibold))
        CharacterPlayView(pack: library.selected, isEnabled: !showingTasks)
          .frame(height: min(480, max(180, proxy.size.height * 0.55)))
          .frame(maxWidth: 520)
        Text("continuity.homeHint")
          .font(.subheadline).foregroundStyle(.secondary)
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { _ in
          Button { showingTasks = true } label: {
            Label {
              VStack(spacing: 3) {
                Text("task.homeComputer")
                if let task = tasks.tasks.first {
                  Text(task.character.name)
                    .font(.caption.weight(.semibold))
                  Text(LocalizedStringKey(tasks.hasFreshStatus ? task.statusKey : "task.status.saved"))
                    .font(.caption)
                }
              }
            } icon: { Image(systemName: "checklist") }
              .padding(.horizontal, 12).padding(.vertical, 4)
          }
          .buttonStyle(.bordered).buttonBorderShape(.capsule)
          .accessibilityIdentifier("home.tasks")
        }
        Spacer(minLength: 12)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(hex: library.selected.appearance.tint).opacity(0.07))
    }
    .sheet(isPresented: $showingTasks) {
      TaskDashboard(connection: tasks, library: library)
        .safeAreaInset(edge: .bottom) {
          Button("동반자로 돌아가기") { showingTasks = false }
            .buttonStyle(.bordered).padding(8).accessibilityIdentifier("task.dismiss")
        }
    }
    .task(id: scenePhase) {
      tasks.setSceneActive(scenePhase == .active)
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        if !showingTasks { await tasks.refresh() }
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      tasks.setSceneActive(phase == .active)
    }
  }
}
