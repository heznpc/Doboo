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
  @State private var selectedCastIds: Set<String> = []

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
          NavigationLink("story.title") {
            StoryDashboard(connection: connection, library: library)
          }.accessibilityIdentifier("story.open")
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
        case .workCast:
          WorkCastSelectionView(connection: connection, host: library.selected, selectedIds: $selectedCastIds)
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
      .onChange(of: library.selected.id) { _, _ in selectedCastIds = [] }
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
      if let work = task.work {
        NavigationLink {
          WorkTaskDetailView(connection: connection, task: task)
        } label: {
          Label("작업 캐스트 \(work.cast.count)명", systemImage: "person.2")
        }.accessibilityIdentifier("task.workDetails")
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
      if task.work == nil && !task.commands.isEmpty {
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
        if connection.workCastSupported {
          Button("참여 캐릭터 \(selectedCastIds.union([library.selected.id]).count)명") {
            selectedCastIds.insert(library.selected.id)
            presentedSheet = .workCast
          }
          .disabled(!hasSavedSelectedProfile || connection.submitting)
          .accessibilityIdentifier("task.chooseCast")
          Text("두 명 이상 선택하면 각 캐릭터가 제안하고, 호스트가 채택 여부를 결정해 작업을 실행합니다.")
            .font(.caption).foregroundStyle(.secondary)
        }
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
        Task { await connection.submit(character: library.selected, castIds: selectedCastIds) }
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
  case memory(CharacterPack), workCast
  #endif
  var id: String {
    switch self {
    case .connection: "connection"
    #if os(iOS)
    case .memory(let pack): "memory-\(pack.id)-\(pack.version)"
    case .workCast: "work-cast"
    #endif
    case .followup(let task): "followup-\(task.id)"
    }
  }
}

struct ComputerConnectionForm: View {
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
          if let work = task.work {
            Text("참여 캐릭터 \(work.cast.count)명과 작업 기억을 이어갑니다.")
              .font(.caption).foregroundStyle(.secondary)
          }
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

#if os(iOS)
private struct WorkCastSelectionView: View {
  @Bindable var connection: TaskConnection
  let host: CharacterPack
  @Binding var selectedIds: Set<String>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("진행 캐릭터를 포함해 최대 6명이 의견을 냅니다. 실제 변경과 검증은 호스트 실행 기록에서 확인합니다.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(connection.companions.sorted { $0.profile.name < $1.profile.name }) { companion in
            Toggle(isOn: Binding(
              get: { companion.characterId == host.id || selectedIds.contains(companion.characterId) },
              set: { selected in
                if selected { selectedIds.insert(companion.characterId) }
                else { selectedIds.remove(companion.characterId) }
              })) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(companion.profile.name)
                  Text(companion.characterId == host.id ? "진행 캐릭터 · 항상 참여" : "의견 제공")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              .disabled(companion.characterId == host.id || connection.pendingRetry || connection.submitting
                || (!selectedIds.contains(companion.characterId) && selectedIds.union([host.id]).count >= 6))
              .accessibilityIdentifier("task.cast.\(companion.characterId)")
          }
        } footer: {
          Text("한 명만 선택하면 기존 단일 작업으로 보냅니다. 새 캐릭터는 먼저 기억·성격 화면에서 컴퓨터에 적용해 주세요.")
        }
      }
      .navigationTitle("참여 캐릭터")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("선택 적용") { selectedIds.insert(host.id); dismiss() }
            .accessibilityIdentifier("task.castDone")
        }
      }
    }
  }
}
#endif

private struct WorkTaskDetailView: View {
  @Bindable var connection: TaskConnection
  let task: CompanionTask

  private var current: CompanionTask { connection.tasks.first { $0.id == task.id } ?? task }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("진행: \(current.character.name)").font(.headline)
        Text("캐릭터별 제안을 호스트가 검토하고, 실행 결과와 검증 기록을 남깁니다.")
          .font(.caption).foregroundStyle(.secondary)
        if !connection.hasFreshStatus { Text("task.savedExplanation").font(.caption) }
        if let record = current.workRecord {
          recordContent(record)
        } else {
          advisorProgress
          if current.showsUnverifiedWorkEvidence {
            unverifiedEvidence
          } else {
            Text("제안과 실행 기록을 모으고 있습니다.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
    .navigationTitle("작업 캐스트")
    .accessibilityIdentifier("task.workDetailScreen")
  }

  private func name(_ id: String) -> String {
    current.work?.cast.first { $0.character.id == id }?.character.name ?? id
  }

  private var advisorProgress: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(current.work?.cast ?? [], id: \.character.id) { member in
        VStack(alignment: .leading, spacing: 4) {
          Text(member.character.name).font(.subheadline.bold())
          if let agent = current.castExecution?.agents.first(where: { $0.characterId == member.character.id }) {
            Label(LocalizedStringKey(connection.hasFreshStatus ? agent.statusKey : "story.execution.saved"),
                  systemImage: connection.hasFreshStatus ? agent.statusSymbol : "clock.arrow.circlepath")
              .font(.caption).foregroundStyle(.secondary)
            if let error = agent.error { Text(error).font(.caption).foregroundStyle(.red) }
          } else {
            Text("의견 실행 확인 대기").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var unverifiedEvidence: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("검증되지 않은 변경·실행 기록").font(.headline)
      Text("이 부분 기록은 다음 작업 기억으로 저장되지 않았습니다. 명령 종료와 파일 변경만으로 작업 성공을 판단할 수 없습니다.")
        .font(.caption).foregroundStyle(.secondary)
      if current.commands.isEmpty {
        Text("기록된 명령 이력 없음").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(Array(current.commands.enumerated()), id: \.offset) { _, command in
          WorkDetailDisclosure(title: command.command) {
            Text("종료 코드: \(command.exitCode.map(String.init) ?? "미확인")").font(.caption)
            Text(command.output).font(.caption2.monospaced())
          }
        }
      }
      if let changes = current.fileChanges, !changes.isEmpty {
        fileChangeEvidence(changes)
      }
      if let repository = current.partialRepositoryEvidence {
        repositoryEvidence(repository)
      } else if current.fileChanges?.isEmpty != false {
        Text("파일 변경 증거를 확인하지 못했습니다.").font(.caption).foregroundStyle(.secondary)
      }
    }.accessibilityIdentifier("task.unverifiedWorkEvidence")
  }

  @ViewBuilder
  private func recordContent(_ record: WorkRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("캐릭터별 제안과 호스트 결정").font(.headline)
      ForEach(record.contributions) { contribution in
        VStack(alignment: .leading, spacing: 10) {
          Text(name(contribution.characterId)).font(.subheadline.bold())
          if contribution.proposals.isEmpty { Text("기록된 제안 없음").font(.caption).foregroundStyle(.secondary) }
          ForEach(contribution.proposals) { proposal in
            VStack(alignment: .leading, spacing: 5) {
              Text(proposal.summary).font(.subheadline)
              Text(proposal.rationale).font(.caption).foregroundStyle(.secondary)
              if !proposal.paths.isEmpty {
                Text(proposal.paths.joined(separator: "\n")).font(.caption.monospaced())
              }
              if let decision = record.decisions.first(where: {
                $0.characterId == contribution.characterId && $0.proposalId == proposal.id
              }) {
                Text("\(decision.label): \(decision.rationale)").font(.caption)
              } else {
                Text("호스트 결정 기록 없음").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          if !contribution.rememberedTaskIds.isEmpty {
            WorkDetailDisclosure(title: "이 캐릭터가 참고한 작업") {
              sourceTasks(contribution.rememberedTaskIds)
            }
          }
          if !contribution.commands.isEmpty {
            WorkDetailDisclosure(title: "의견 조사 중 실행 기록") {
              commandEvidence(contribution.commands)
            }
          }
        }.padding(.vertical, 4)
      }
    }
    Divider()
    VStack(alignment: .leading, spacing: 10) {
      Text("작업 보고와 검증 명령 이력").font(.headline)
      Text("호스트 모델 보고").font(.caption.bold()).foregroundStyle(.secondary)
      Text(record.summary)
      Text("명령 이력의 실행 상태, 종료 코드와 출력을 확인해 주세요.").font(.caption).foregroundStyle(.secondary)
      if record.evidence.commands.isEmpty {
        Text("기록된 검증 명령 없음").font(.caption).foregroundStyle(.secondary)
      } else {
        commandEvidence(record.evidence.commands)
      }
      if !record.evidence.hasRecordedFileChanges && record.evidence.repository == nil {
        Text("파일 변경 증거가 제공되지 않았습니다.").font(.caption).foregroundStyle(.secondary)
      }
      if !record.evidence.fileChanges.isEmpty {
        fileChangeEvidence(record.evidence.fileChanges)
      }
      if let repository = record.evidence.repository {
        repositoryEvidence(repository)
      }
      ForEach(Array(record.remainingRisks.enumerated()), id: \.offset) { _, risk in
        Label(risk, systemImage: "exclamationmark.circle").font(.caption)
      }
    }
    Divider()
    VStack(alignment: .leading, spacing: 8) {
      Text("다음 작업으로 이어갈 기억").font(.headline)
      Text("이 작업에서 이어가기를 누르면 제안, 호스트 결정, 결과·검증 기록을 다음 요청에 연결합니다.")
        .font(.caption).foregroundStyle(.secondary)
      Text(record.taskId).font(.caption.monospaced())
      Text(record.recordedAt).font(.caption2).foregroundStyle(.secondary)
      WorkDetailDisclosure(title: "이번 작업이 참고한 기억 \(record.sourceTaskIds.count)개") {
        sourceTasks(record.sourceTaskIds)
        Text("문맥: \(record.contextDigest)").font(.caption2.monospaced())
      }
    }
    if let execution = current.castExecution {
      WorkDetailDisclosure(title: "캐릭터 실행 확인") {
        Text("호스트: \(execution.coordinatorThreadId)").font(.caption2.monospaced())
        ForEach(execution.agents) { agent in
          Text(name(agent.characterId)).font(.caption.bold())
          Text(LocalizedStringKey(agent.statusKey)).font(.caption)
          if let thread = agent.threadId { Text(thread).font(.caption2.monospaced()) }
          if let turn = agent.turnId { Text(turn).font(.caption2.monospaced()) }
          if let model = agent.model { Text(model).font(.caption2) }
          if let effort = agent.reasoningEffort { Text(effort).font(.caption2) }
        }
      }
    }
  }

  private func fileChangeEvidence(_ changes: [WorkRecord.FileChange]) -> some View {
    ForEach(Array(changes.enumerated()), id: \.offset) { _, item in
      WorkDetailDisclosure(title: "런타임 파일 변경 기록 · \(item.status)") {
        ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
          VStack(alignment: .leading, spacing: 4) {
            Text(change.path).font(.caption.monospaced())
            Text(change.kind.type).font(.caption).foregroundStyle(.secondary)
            if let destination = change.kind.move_path { Text(destination).font(.caption.monospaced()) }
            Text(change.diff).font(.caption2.monospaced())
          }
        }
        receipt(threadId: item.threadId, turnId: item.turnId, itemId: item.itemId)
      }
    }
  }

  private func repositoryEvidence(_ repository: WorkRecord.Repository) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("파일 해시 비교").font(.subheadline.bold())
      if !repository.available {
        Text("파일 해시 비교 결과를 확인하지 못했습니다.").font(.caption).foregroundStyle(.secondary)
      } else if repository.changes.isEmpty {
        Text("비교한 파일에서 SHA256 변경이 감지되지 않았습니다.").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("SHA256 비교에서 변경을 감지한 파일 \(repository.changes.count)개").font(.caption)
      }
      if repository.truncated {
        Label("비교 대상 일부만 포함되어 있습니다. 이 목록이 전체 변경 범위를 뜻하지는 않습니다.",
              systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(repository.changes.enumerated()), id: \.offset) { _, change in
        VStack(alignment: .leading, spacing: 4) {
          Text(change.path).font(.caption.monospaced())
          WorkDetailDisclosure(title: "전후 SHA256") {
            Text("이전: \(change.beforeSHA256 ?? "기록 없음")").font(.caption2.monospaced())
            Text("이후: \(change.afterSHA256 ?? "기록 없음")").font(.caption2.monospaced())
          }
        }
      }
      if repository.headBefore != nil || repository.headAfter != nil {
        WorkDetailDisclosure(title: "비교 기준 커밋") {
          Text("이전: \(repository.headBefore ?? "기록 없음")").font(.caption2.monospaced())
          Text("이후: \(repository.headAfter ?? "기록 없음")").font(.caption2.monospaced())
        }
      }
    }.accessibilityIdentifier("task.repositoryEvidence")
  }

  private func commandEvidence(_ commands: [WorkRecord.Command]) -> some View {
    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
      WorkDetailDisclosure(title: command.command) {
        Text("상태: \(command.status) · 종료 코드: \(command.exitCode.map(String.init) ?? "미확인")")
          .font(.caption)
        if let purpose = command.purpose { Text(purpose).font(.caption) }
        Text(command.output).font(.caption2.monospaced())
        receipt(threadId: command.threadId, turnId: command.turnId, itemId: command.itemId)
      }
    }
  }

  private func sourceTasks(_ ids: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      if ids.isEmpty { Text("이전 작업 기억 없음").font(.caption).foregroundStyle(.secondary) }
      ForEach(ids, id: \.self) { id in
        Text(connection.tasks.first { $0.id == id }?.prompt ?? id).font(.caption)
        Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
  }

  private func receipt(threadId: String, turnId: String, itemId: String) -> some View {
    Text("\(threadId) / \(turnId) / \(itemId)").font(.caption2.monospaced()).foregroundStyle(.secondary)
  }
}

private struct WorkDetailDisclosure<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    #if os(watchOS)
    NavigationLink(title) {
      ScrollView { VStack(alignment: .leading, spacing: 10) { content }.padding() }
        .navigationTitle(title)
    }.font(.caption)
    #else
    DisclosureGroup(title) {
      VStack(alignment: .leading, spacing: 8) { content }
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }.font(.caption)
    #endif
  }
}
