import SwiftUI

/// The companion remains the home. Work is something you ask it to do.
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
        Text("눌러 보고, 끌어 보고, 잠깐 같이 쉬어요.")
          .font(.subheadline).foregroundStyle(.secondary)
        Button { showingTasks = true } label: {
          Label(matchingTask.map { "부탁한 작업 · \($0.label)" } ?? "Doboo에게 부탁하기",
                systemImage: "bubble.left.and.bubble.right")
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .accessibilityIdentifier("home.tasks")
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
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        if !showingTasks { await tasks.refresh() }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  private var matchingTask: CompanionTask? {
    tasks.tasks.first.flatMap { task in
      task.character.id == library.selected.id && task.character.version == library.selected.version ? task : nil
    }
  }
}
