import SwiftUI

struct TaskDashboard: View {
  @Bindable var connection: TaskConnection
  @Bindable var library: CharacterLibrary
  @Environment(\.scenePhase) private var scenePhase
  #if os(watchOS)
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  #endif
  @State private var presentedSheet: TaskSheet?
  @State private var showForgetPending = false
  @State private var taskToCancel: CompanionTask?
  @State private var watchCharacterSent: String?

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
          if connection.tasks.isEmpty { submissionForm }
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
          #if os(iOS)
          if !connection.tasks.isEmpty {
            Divider()
            submissionForm
          }
          #endif
          #if os(watchOS)
          if connection.pendingRetry {
            Text(connection.prompt).lineLimit(3)
            Button("task.retrySubmission") {
              Task { await connection.submit(character: library.selected) }
            }.disabled(connection.submitting)
          }
          if !connection.tasks.isEmpty { connectionHeading }
          #endif
          if let error = connection.error {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          if connection.tasks.count > 1 {
            NavigationLink("continuity.history") {
              List(connection.tasks.dropFirst()) { task in
                NavigationLink {
                  ScrollView { taskSummary(task, fresh: connection.hasFreshStatus).padding() }
                    .navigationTitle(task.character.name)
                } label: {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(task.character.name).font(.caption).foregroundStyle(.secondary)
                    Text(task.prompt).lineLimit(2)
                  }
                }
              }.navigationTitle("continuity.history")
            }
          }
          Button("task.connectionSettings") { presentedSheet = .connection }.font(.caption)
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
      .sheet(item: $presentedSheet) { sheet in
        switch sheet {
        case .connection:
          ComputerConnectionForm(connection: connection)
        #if os(iOS)
        case .memory(let pack):
          CompanionMemoryView(connection: connection, pack: pack)
        #endif
        case .followup(let task):
          TaskFollowupView(connection: connection, task: task)
        }
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
      #if os(watchOS)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(task.character.name).font(.caption.weight(.semibold))
          .lineLimit(1).minimumScaleFactor(0.8)
          .accessibilityIdentifier("task.character")
        Spacer(minLength: 0)
        Label(LocalizedStringKey(fresh ? task.statusKey : "task.status.saved"),
              systemImage: fresh ? task.statusSymbol : "clock.arrow.circlepath")
          .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
          .layoutPriority(1).accessibilityIdentifier("task.status")
      }
      #else
      Text(task.character.name).font(.caption.weight(.semibold))
        .accessibilityIdentifier("task.character")
      Label(LocalizedStringKey(fresh ? task.statusKey : "task.status.saved"),
            systemImage: fresh ? task.statusSymbol : "clock.arrow.circlepath")
        .font(.headline).accessibilityIdentifier("task.status")
      #endif
      if fresh {
        #if os(watchOS)
        if !task.finished {
          Text(LocalizedStringKey(nextActionKey(for: task))).font(.caption).foregroundStyle(.secondary)
        }
        #else
        Text(LocalizedStringKey(nextActionKey(for: task))).font(.caption).foregroundStyle(.secondary)
        #endif
      } else {
        Text("task.savedExplanation").font(.caption).foregroundStyle(.secondary)
        Button("task.next.refresh") { Task { await connection.refresh() } }
          .accessibilityIdentifier("task.refresh")
      }
      #if os(watchOS)
      if !task.finished { Text(task.prompt).font(.caption).lineLimit(2) }
      #else
      Text(task.prompt).font(.subheadline)
      lastChecked
      #endif
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
        #else
        Text(task.result).accessibilityIdentifier("task.result")
        #endif
      }
      if task.continuity != nil && task.status == "completed" {
        Button("continuity.continue") { presentedSheet = .followup(task) }
          .disabled(!connection.canContinue(task: task))
          .accessibilityIdentifier("task.continue")
        if fresh && !connection.canContinue(task: task) {
          Text("continuity.unavailable").font(.caption2).foregroundStyle(.secondary)
        }
      }
      if ["failed", "interrupted"].contains(task.status),
         let parentID = task.continuity?.parentTaskId,
         let parent = connection.tasks.first(where: { $0.id == parentID }),
         connection.canContinue(task: parent) {
        Button("continuity.continueParent") { presentedSheet = .followup(parent) }
          .accessibilityIdentifier("task.continueParent")
      }
      #if os(watchOS)
      if !task.result.isEmpty {
        NavigationLink("task.resultDetails") {
          ScrollView { Text(task.result).font(.caption2).padding() }
            .navigationTitle("task.resultDetails")
        }
      }
      #endif
      if task.continuity != nil {
        NavigationLink("continuity.contextDetails") {
          TaskContextView(connection: connection, task: task)
        }.accessibilityIdentifier("task.context")
      }
      #if os(watchOS)
      NavigationLink("task.requestDetails") {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text(task.prompt).font(.caption)
            lastChecked
          }.padding()
        }.navigationTitle("task.requestDetails")
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

  @ViewBuilder
  private var lastChecked: some View {
    if let checkedAt = connection.lastSuccessfulRefreshAt {
      VStack(alignment: .leading, spacing: 2) {
        Text("task.lastChecked")
        Text(checkedAt, format: .dateTime.month().day().hour().minute())
      }
      .font(.caption2).foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
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
  private var hasSavedSelectedProfile: Bool {
    connection.companion(for: library.selected)?.profile == CompanionProfile(library.selected)
  }

  private var submissionForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      if connection.pendingRetry {
        Text("task.retrySubmission").font(.headline)
      } else {
        Text("continuity.newWork").font(.headline)
        Text(library.selected.name).font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("task.newCharacter")
        Button("continuity.memory") { presentedSheet = .memory(library.selected) }
          .disabled(!connection.supportsContinuity)
          .accessibilityIdentifier("memory.open")
        Button("transfer.send") {
          watchCharacterSent = "\(library.selected.id)@\(library.selected.version)"
          library.transfer?.send(library.selected)
        }
        .disabled(library.transfer == nil)
        .accessibilityIdentifier("task.sendCharacterToWatch")
        Text("continuity.appearanceTransferHelp").font(.caption).foregroundStyle(.secondary)
        if watchCharacterSent == "\(library.selected.id)@\(library.selected.version)" {
          Text(library.transferStatus).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("task.characterTransferStatus")
        }
        if !hasSavedSelectedProfile {
          Text("continuity.activateFirst").font(.caption).foregroundStyle(.secondary)
        }
        Text("continuity.newWorkHelp").font(.caption).foregroundStyle(.secondary)
      }
      TextField("task.promptPlaceholder", text: $connection.prompt, axis: .vertical)
        .lineLimit(3...7).textFieldStyle(.roundedBorder).accessibilityIdentifier("task.prompt")
        .disabled(connection.pendingRetry)
      Button(LocalizedStringKey(connection.pendingRetry ? "task.retrySubmission" : "task.submitToComputer")) {
        Task { await connection.submit(character: library.selected) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(((!connection.canSubmit || !hasSavedSelectedProfile) && !connection.pendingRetry) || connection.submitting)
      .accessibilityIdentifier("task.submit")
      if connection.pendingRetry {
        Button("task.pendingForget", role: .destructive) { showForgetPending = true }
          .disabled(connection.submitting).accessibilityIdentifier("task.forgetPending")
      }
    }
  }
  #endif
}

private enum TaskSheet: Identifiable {
  case connection, followup(CompanionTask)
  #if os(iOS)
  case memory(CharacterPack)
  #endif
  var id: String {
    switch self {
    case .connection: "connection"
    #if os(iOS)
    case .memory(let pack): "memory-\(pack.id)-\(pack.version)"
    #endif
    case .followup(let task): "followup-\(task.id)"
    }
  }
}

private struct ComputerConnectionForm: View {
  @Bindable var connection: TaskConnection
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var connectionTask: Task<Void, Never>?
  @State private var attemptID: UUID?
  @State private var confirmWatchConnection = false

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
        #if os(iOS)
        if let address = connection.verifiedAddress {
          Section("continuity.watchConnection") {
            Text(address).font(.caption).textSelection(.enabled)
            Text("continuity.watchConnectionHelp").font(.caption).foregroundStyle(.secondary)
            Button("continuity.sendConnection") { confirmWatchConnection = true }
              .disabled(!connection.canSendWatchConnection || connection.isSendingWatchConnection)
              .accessibilityIdentifier("connection.sendWatch")
            if connection.isSendingWatchConnection { ProgressView() }
            if let status = connection.watchConnectionStatus {
              Text(status).font(.caption).accessibilityIdentifier("connection.watchStatus")
            }
          }
        }
        #endif
      }
      .navigationTitle("컴퓨터 연결")
      .confirmationDialog("continuity.sendConnectionTitle", isPresented: $confirmWatchConnection,
                          titleVisibility: .visible) {
        Button("continuity.sendConnection") { Task { await connection.sendConnectionToWatch() } }
        Button("editor.cancel", role: .cancel) {}
      } message: {
        Text("continuity.sendConnectionScope")
      }
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


#if os(iOS)
/// Personal memory belongs to this computer connection, never to an exported pack.
private struct CompanionMemoryView: View {
  @Bindable var connection: TaskConnection
  let pack: CharacterPack
  @Environment(\.dismiss) private var dismiss
  @State private var memory: String
  @State private var expectedRevision: Int
  private let expectedServerID: String?
  @State private var confirmForget = false
  @State private var saved = false

  init(connection: TaskConnection, pack: CharacterPack) {
    self.connection = connection
    self.pack = pack
    expectedServerID = connection.serverId
    let current = connection.companion(for: pack)
    _memory = State(initialValue: current?.memory ?? "")
    _expectedRevision = State(initialValue: current?.revision ?? 0)
  }

  private var current: CompanionContext? { connection.companion(for: pack) }
  private var changedElsewhere: Bool {
    connection.serverId != expectedServerID || (current?.revision ?? 0) != expectedRevision
  }
  private var canEdit: Bool {
    connection.canEditCompanion(characterId: pack.id) && !connection.savingCompanion && !changedElsewhere
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("continuity.personality") {
          Text(pack.name).font(.headline)
          Text(pack.identity.voice)
          Text(pack.personality.traits.joined(separator: " · ")).foregroundStyle(.secondary)
          DisclosureGroup("continuity.instructions") {
            ForEach(Array(pack.personality.instructions.enumerated()), id: \.offset) { _, instruction in
              Text(instruction)
            }
          }
          Text("continuity.personalityHelp").font(.caption).foregroundStyle(.secondary)
        }
        Section("continuity.memoryTitle") {
          TextField("continuity.memoryPlaceholder", text: $memory, axis: .vertical)
            .lineLimit(3...8)
            .disabled(connection.savingCompanion)
            .accessibilityIdentifier("memory.text")
          Text("continuity.memoryHelp").font(.caption).foregroundStyle(.secondary)
          Text("continuity.memoryChangeHelp").font(.caption).foregroundStyle(.secondary)
          Button("continuity.save") { Task { await save(reset: false) } }
            .disabled(!canEdit)
            .accessibilityIdentifier("memory.save")
          if connection.savingCompanion { ProgressView() }
          if saved && memory == current?.memory {
            Label("continuity.saved", systemImage: "checkmark.circle")
              .accessibilityIdentifier("memory.saved")
          }
        }
        if changedElsewhere {
          Section {
            Text(LocalizedStringKey(connection.serverId == expectedServerID
              ? "continuity.memoryConflict" : "continuity.connectionChanged"))
              .foregroundStyle(.orange)
            Button("continuity.reloadMemory") { reload() }
              .disabled(connection.serverId != expectedServerID)
              .accessibilityIdentifier("memory.reload")
          }
        }
        if !connection.canEditCompanion(characterId: pack.id) {
          Text("continuity.editUnavailable").font(.caption).foregroundStyle(.secondary)
        }
        if let error = connection.error { Text(error).font(.caption).foregroundStyle(.red) }
        if current != nil {
          Section {
            Button("continuity.forget", role: .destructive) { confirmForget = true }
              .disabled(!canEdit)
              .accessibilityIdentifier("memory.forget")
            Text("continuity.forgetHelp").font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("continuity.scope") {
          if let address = connection.verifiedAddress { Text(address).font(.caption) }
          Text(connection.project).font(.caption)
          Text("continuity.scopeHelp").font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("continuity.memory")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }.disabled(connection.savingCompanion)
            .accessibilityIdentifier("memory.close")
        }
      }
      .interactiveDismissDisabled(connection.savingCompanion)
      .confirmationDialog("continuity.forgetTitle", isPresented: $confirmForget, titleVisibility: .visible) {
        Button("continuity.forget", role: .destructive) { Task { await save(reset: true) } }
        Button("editor.cancel", role: .cancel) {}
      } message: {
        Text("continuity.forgetHelp")
      }
    }
  }

  private func reload() {
    memory = current?.memory ?? ""
    expectedRevision = current?.revision ?? 0
    saved = false
  }

  private func save(reset: Bool) async {
    guard connection.serverId == expectedServerID else { return }
    saved = false
    if await connection.saveCompanion(character: pack, memory: reset ? "" : memory,
                                      expectedRevision: expectedRevision, resetHistory: reset, expectedServerId: expectedServerID) {
      reload()
      saved = true
    }
  }
}

#endif

private struct TaskContextView: View {
  @Bindable var connection: TaskConnection
  let task: CompanionTask

  private var current: CompanionContext? {
    guard task.continuity?.serverId == connection.serverId else { return nil }
    return connection.companions.first { $0.characterId == task.character.id }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(task.character.name).font(.headline)
        if let context = task.continuity {
          Label("continuity.personalityApplied", systemImage: "person.crop.circle.badge.checkmark")
          Text(LocalizedStringKey(context.memoryApplied ? "continuity.memoryApplied" : "continuity.noMemoryApplied"))
          Text(String(format: String(localized: "continuity.historyCount"), context.historyCount))
          if context.historyTruncated {
            Text("continuity.historyTruncated").foregroundStyle(.secondary)
          }
          Text("continuity.historyLimit").foregroundStyle(.secondary)
          Divider()
          Text("continuity.currentMemory").font(.headline)
          if let current {
            Text(current.memory.isEmpty ? String(localized: "continuity.memoryEmpty") : current.memory)
              .accessibilityIdentifier("task.sharedMemory")
            if current.generation != context.generation {
              Text("continuity.contextChanged").foregroundStyle(.secondary)
            }
          } else {
            Text("continuity.memoryUnavailable").foregroundStyle(.secondary)
          }
          if !connection.hasFreshStatus {
            Text("task.savedExplanation").foregroundStyle(.secondary)
          }
          Text("continuity.phoneEdit").foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .navigationTitle("continuity.contextDetails")
  }
}

private struct TaskFollowupView: View {
  @Bindable var connection: TaskConnection
  let task: CompanionTask
  @Environment(\.dismiss) private var dismiss
  @State private var request = ""
  @State private var sending = false

  private var companion: CompanionContext? {
    connection.companions.first { $0.characterId == task.character.id }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(task.character.name).font(.headline)
          #if os(iOS)
          Text(task.prompt).font(.caption).lineLimit(2)
          Text("continuity.followupHelp").font(.caption).foregroundStyle(.secondary)
          #endif
          TextField("continuity.followupPlaceholder", text: Binding(
            get: { connection.pendingRetry ? connection.prompt : request },
            set: { request = $0 }), axis: .vertical)
            #if os(watchOS)
            .lineLimit(1...4)
            #else
            .lineLimit(2...5)
            #endif
            .disabled(sending || connection.pendingRetry)
            .accessibilityIdentifier("task.followupPrompt")
          Button(LocalizedStringKey(connection.pendingRetry ? "task.retrySubmission" : "continuity.sendFollowup")) {
            Task { await send() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(sending || connection.submitting ||
                    (!connection.pendingRetry && (request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.canContinue(task: task))))
          .accessibilityIdentifier("task.followupSend")
          if sending { ProgressView() }
          if !connection.canContinue(task: task) && !connection.pendingRetry {
            Text("continuity.unavailable").font(.caption).foregroundStyle(.secondary)
          }
          if let error = connection.error { Text(error).font(.caption).foregroundStyle(.red) }
          #if os(watchOS)
          Text(task.prompt).font(.caption).lineLimit(2)
          Text("continuity.followupHelp").font(.caption).foregroundStyle(.secondary)
          #endif
        }.padding()
      }
      .navigationTitle("continuity.continue")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }.disabled(sending)
        }
      }
      .interactiveDismissDisabled(sending)
    }
  }

  private func send() async {
    guard !sending, let companion else { return }
    sending = true
    defer { sending = false }
    if !connection.pendingRetry { connection.prompt = request }
    if await connection.submit(companion: companion, parentTask: task) { dismiss() }
  }
}
