import SwiftUI

struct TaskDashboard: View {
  @Bindable var connection: TaskConnection
  @Bindable var library: CharacterLibrary
  @Environment(\.scenePhase) private var scenePhase
  #if os(watchOS)
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  #endif
  @State private var showConnection = false
  @State private var showForgetPending = false
  @State private var taskToCancel: CompanionTask?

  private var statusTimelinePaused: Bool {
    #if os(watchOS)
    scenePhase != .active || isLuminanceReduced
    #else
    scenePhase != .active
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          #if os(iOS)
          connectionHeading
          submissionForm
          #else
          if connection.tasks.isEmpty { connectionHeading }
          #endif
          // Time changes freshness without animating a cached task's character.
          TimelineView(.animation(minimumInterval: 1, paused: statusTimelinePaused)) { _ in
            if let task = connection.tasks.first {
              taskSummary(task, fresh: connection.hasFreshStatus)
            } else {
              Text("task.empty").foregroundStyle(.secondary)
            }
          }
          #if os(watchOS)
          if !connection.tasks.isEmpty { connectionHeading }
          #endif
          if let error = connection.error {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          Button("task.connectionSettings") { showConnection = true }.font(.caption)
        }.padding()
      }
      .navigationTitle("task.title")
      .alert("task.pendingForgetTitle", isPresented: $showForgetPending) {
        Button("editor.cancel", role: .cancel) {}
        Button("task.pendingForget", role: .destructive) { connection.forgetPending() }
      } message: {
        Text("task.pendingForgetHelp")
      }
      .confirmationDialog("task.cancelTitle", isPresented: Binding(
        get: { taskToCancel != nil }, set: { if !$0 { taskToCancel = nil } }),
        titleVisibility: .visible, presenting: taskToCancel) { task in
          Button("task.cancelConfirm", role: .destructive) {
            taskToCancel = nil
            Task { await connection.cancel(task) }
          }
          Button("task.keepRunning", role: .cancel) { taskToCancel = nil }
        } message: { task in
          #if os(watchOS)
          Text(task.prompt.count > 40 ? String(task.prompt.prefix(40)) + "…" : task.prompt)
          #else
          Text(task.prompt).lineLimit(3)
          #endif
        }
      #if os(watchOS)
      .font(.caption)
      #endif
      .sheet(isPresented: $showConnection) {
        ComputerConnectionForm(connection: connection)
      }
      .task(id: scenePhase) {
        connection.setSceneActive(scenePhase == .active)
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
          await connection.refresh()
          do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
      }
      .onChange(of: scenePhase) { _, phase in
        connection.setSceneActive(phase == .active)
        if phase != .active { taskToCancel = nil }
      }
    }
  }

  private var connectionHeading: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("task.computer", systemImage: "desktopcomputer").font(.headline)
      if !connection.project.isEmpty {
        Text(connection.project).font(.caption).lineLimit(1)
      }
      Text("task.foregroundOnly").font(.caption2).foregroundStyle(.secondary)
      if !connection.hasConnection {
        Text("task.connectionRequired").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func taskSummary(_ task: CompanionTask, fresh: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(LocalizedStringKey(fresh ? task.statusKey : "task.status.saved"),
            systemImage: fresh ? task.statusSymbol : "clock.arrow.circlepath")
        .font(.headline).accessibilityIdentifier("task.status")
      if fresh {
        Text(LocalizedStringKey(nextActionKey(for: task))).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("task.savedExplanation").font(.caption).foregroundStyle(.secondary)
        Button("task.next.refresh") { Task { await connection.refresh() } }
          .accessibilityIdentifier("task.refresh")
      }
      Text(task.prompt).font(.subheadline)
        #if os(watchOS)
        .lineLimit(2)
        #endif
      if let checkedAt = connection.lastSuccessfulRefreshAt {
        VStack(alignment: .leading, spacing: 2) {
          Text("task.lastChecked")
          Text(checkedAt, format: .dateTime.month().day().hour().minute())
        }
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
      #if os(iOS)
      if fresh && !task.finished && !task.activity.isEmpty {
        Text(task.activity).font(.caption).foregroundStyle(.secondary)
      }
      if fresh {
        ForEach(task.approvals) { approval in
          Text(approval.description).font(.caption)
          HStack {
            Button("task.approve") { Task { await connection.approve(task, approval: approval, accept: true) } }
            Button("task.decline", role: .destructive) { Task { await connection.approve(task, approval: approval, accept: false) } }
          }
        }
      }
      #endif
      if !task.result.isEmpty {
        #if os(watchOS)
        Text(task.result).font(.caption2).lineLimit(3)
          .accessibilityIdentifier("task.result")
        NavigationLink("task.resultDetails") {
          ScrollView { Text(task.result).font(.caption2).padding() }
            .navigationTitle("task.resultDetails")
        }
        #else
        Text(task.result).accessibilityIdentifier("task.result")
        #endif
      }
      #if os(watchOS)
      NavigationLink("task.requestDetails") {
        ScrollView { Text(task.prompt).font(.caption).padding() }
          .navigationTitle("task.requestDetails")
      }
      #endif
      if let error = task.error { Text(error).font(.caption).foregroundStyle(.red) }
      if fresh && !task.finished {
        Button("task.cancel", role: .destructive) { taskToCancel = task }
          .accessibilityIdentifier("task.cancel")
      }
      #if os(iOS)
      if !task.commands.isEmpty {
        DisclosureGroup("컴퓨터 실행 기록 \(task.commands.count)개") {
          ForEach(Array(task.commands.enumerated()), id: \.offset) { _, command in
            Text(command.command).font(.caption.monospaced())
            Text("종료 코드: \(command.exitCode.map(String.init) ?? "실행 중")").font(.caption)
            Text(command.output).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      #endif
    }
  }

  private func nextActionKey(for task: CompanionTask) -> String {
    #if os(iOS)
    task.status == "needsApproval" ? "task.next.reviewApproval" : task.nextActionKey
    #else
    task.nextActionKey
    #endif
  }

  #if os(iOS)
  private var submissionForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("task.promptPlaceholder", text: $connection.prompt, axis: .vertical)
        .lineLimit(3...7).textFieldStyle(.roundedBorder).accessibilityIdentifier("task.prompt")
        .disabled(connection.pendingRetry)
      Button(LocalizedStringKey(connection.pendingRetry ? "task.retrySubmission" : "task.submitToComputer")) {
        Task { await connection.submit(character: library.selected) }
      }
      .buttonStyle(.borderedProminent)
      .disabled((!connection.canSubmit && !connection.pendingRetry) || connection.submitting)
      .accessibilityIdentifier("task.submit")
      if connection.pendingRetry {
        Button("task.pendingForget", role: .destructive) { showForgetPending = true }
          .disabled(connection.submitting).accessibilityIdentifier("task.forgetPending")
      }
    }
  }
  #endif
}

private struct ComputerConnectionForm: View {
  @Bindable var connection: TaskConnection
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var connectionTask: Task<Void, Never>?
  @State private var attemptID: UUID?

  var body: some View {
    NavigationStack {
      Form {
        TextField("컴퓨터 주소", text: $connection.address).textContentType(.URL)
          .disabled(connectionTask != nil)
        SecureField("연결 키", text: $connection.connectionToken)
          .disabled(connectionTask != nil)
        Button("연결", action: connect)
          .disabled(connectionTask != nil || scenePhase != .active)
        if connectionTask != nil { ProgressView() }
        if let error = connection.error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("컴퓨터 연결")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") {
            cancelConnection()
            dismiss()
          }
        }
      }
    }
    .onDisappear { cancelConnection() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { cancelConnection() }
    }
  }

  private func connect() {
    guard connectionTask == nil, scenePhase == .active else { return }
    let id = UUID()
    attemptID = id
    connectionTask = Task { @MainActor in
      let connected = await connection.connect()
      guard !Task.isCancelled, attemptID == id else { return }
      connectionTask = nil
      attemptID = nil
      if connected { dismiss() }
    }
  }

  private func cancelConnection() {
    attemptID = nil
    connectionTask?.cancel()
    connectionTask = nil
  }
}
