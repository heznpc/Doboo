import SwiftUI

struct StoryDashboard: View {
  @Bindable var connection: TaskConnection
  @Bindable var library: CharacterLibrary
  @Environment(\.scenePhase) private var scenePhase
  @State private var showCreate = false
  @State private var showConnection = false
  @State private var showForgetPending = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("story.intro").font(.caption).foregroundStyle(.secondary)
          Button("task.connectionSettings") { showConnection = true }
          if connection.loadingStory && connection.story == nil { ProgressView("story.loading") }
          if let error = connection.storyError ?? connection.error {
            Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("story.error")
          }
          Button("task.next.refresh") { Task { await reload() } }
            .disabled(connection.loadingStory || connection.savingStory)
          #if os(iOS)
          Button("story.create", systemImage: "plus") { showCreate = true }
            .disabled(!connection.canEditStory)
            .accessibilityIdentifier("story.create")
          #else
          Text("story.phoneCreate").font(.caption)
          #endif
        }
        if connection.hasPendingStory {
          Section("story.pending") {
            Text(connection.pendingStoryTurn?.prompt ?? String(localized: "story.pendingUnreadable"))
            if let pending = connection.pendingStoryTurn {
              Button("task.retrySubmission") {
                Task { _ = await connection.submitStoryTurn(episodeId: pending.episodeId, prompt: pending.prompt) }
              }.disabled(connection.savingStory)
            }
            Button("task.pendingForget", role: .destructive) { showForgetPending = true }
              .disabled(connection.savingStory)
          }
        }
        Section("story.episodes") {
          if let story = connection.story {
            if story.episodes.isEmpty { Text("story.empty").foregroundStyle(.secondary) }
            ForEach(story.episodes.reversed()) { episode in
              NavigationLink {
                StoryEpisodeView(connection: connection, episodeId: episode.id, serverId: story.serverId)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(episode.title)
                  Text(episode.castProfiles.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                }
              }.accessibilityIdentifier("story.episode.\(episode.id)")
            }
          }
        }
      }
      .navigationTitle("story.title")
      .accessibilityIdentifier("story.dashboard")
      .sheet(isPresented: $showCreate) { StoryCreateView(connection: connection, library: library) }
      .sheet(isPresented: $showConnection) { ComputerConnectionForm(connection: connection) }
      .confirmationDialog("task.pendingForgetTitle", isPresented: $showForgetPending, titleVisibility: .visible) {
        Button("task.pendingForget", role: .destructive) { connection.forgetPendingStory() }
      } message: { Text("task.pendingForgetHelp") }
    }
    .task(id: scenePhase) {
      connection.setSceneActive(scenePhase == .active)
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        await reload()
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
      }
    }
  }

  private func reload() async {
    await connection.refresh()
    await connection.refreshStory()
  }
}

private struct StoryCreateView: View {
  @Bindable var connection: TaskConnection
  let library: CharacterLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var castIds: Set<String> = []

  var body: some View {
    NavigationStack {
      Form {
        Section("story.episodeTitle") {
          TextField("story.episodeTitle", text: $title).accessibilityIdentifier("story.title")
        }
        Section("story.cast") {
          Text("story.castHelp").font(.caption).foregroundStyle(.secondary)
          ForEach(library.packs) { pack in
            if let registered = connection.companion(for: pack), registered.profile == CompanionProfile(pack) {
              Toggle(pack.name, isOn: Binding(get: { castIds.contains(pack.id) }, set: { selected in
                if selected { castIds.insert(pack.id) } else { castIds.remove(pack.id) }
              })).accessibilityIdentifier("story.cast.\(pack.id)")
            } else {
              Button {
                Task {
                  let current = connection.companion(for: pack)
                  _ = await connection.saveCompanion(character: pack, memory: current?.memory ?? "",
                    expectedRevision: current?.revision ?? 0, expectedServerId: connection.serverId)
                }
              } label: {
                VStack(alignment: .leading) {
                  Text(pack.name)
                  Text("story.register").font(.caption)
                }
              }.disabled(!connection.canEditCompanion(characterId: pack.id))
                .accessibilityIdentifier("story.register.\(pack.id)")
            }
          }
        }
        Section {
          Text("story.snapshotHelp").font(.caption).foregroundStyle(.secondary)
          Button("story.create") {
            Task {
              if await connection.createStoryEpisode(title: title, castIds: castIds.sorted()) { dismiss() }
            }
          }.disabled(!connection.canEditStory || castIds.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("story.createEpisode")
          if connection.savingStory || connection.savingCompanion { ProgressView() }
          if let error = connection.storyError ?? connection.error { Text(error).foregroundStyle(.red) }
        }
      }
      .navigationTitle("story.create")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } } }
      .interactiveDismissDisabled(connection.savingStory || connection.savingCompanion)
    }
  }
}

private struct StoryEpisodeView: View {
  @Bindable var connection: TaskConnection
  let episodeId: String
  let serverId: String
  @State private var prompt = ""
  @State private var editEvent: StoryEvent?
  @State private var showRelationships = false
  @State private var showSequel = false
  @State private var sequelTitle = ""

  private var state: StoryState? { connection.story?.serverId == serverId ? connection.story : nil }
  private var episode: StoryEpisode? { state?.episodes.first { $0.id == episodeId } }
  private func name(_ id: String) -> String { episode?.castProfiles.first { $0.id == id }?.name ?? id }

  var body: some View {
    List {
      if let episode, let state {
        Section {
          Text(episode.castProfiles.map { "\($0.name) · v\($0.version)" }.joined(separator: ", "))
            .font(.caption).foregroundStyle(.secondary)
          Text("story.fictionalMemory").font(.caption)
          Button("story.relationships") { showRelationships = true }
            .accessibilityIdentifier("story.relationships")
          ForEach(inheritedRelationships(state, episode: episode)) { relation in
            VStack(alignment: .leading) {
              Text("\(name(relation.fromCharacterId)) → \(name(relation.toCharacterId))").font(.caption.bold())
              Text(relation.summary).font(.caption)
            }
          }
        }
        if !state.episodes.contains(where: { $0.predecessorEpisodeId == episodeId }) {
          Section {
            Button("story.sequel") { showSequel = true }
              .disabled(!connection.canEditStory || !state.events.contains(where: { $0.episodeId == episodeId }))
              .accessibilityIdentifier("story.sequel")
          }
        }
        if let successor = state.episodes.first(where: { $0.predecessorEpisodeId == episodeId }) {
          Section {
            Text("story.continueInSequel").font(.caption).foregroundStyle(.secondary)
            NavigationLink(successor.title) {
              StoryEpisodeView(connection: connection, episodeId: successor.id, serverId: serverId)
            }.accessibilityIdentifier("story.openSequel")
          }
        } else {
        Section("story.scene") {
          TextField("story.scenePlaceholder", text: $prompt, axis: .vertical)
            .lineLimit(2...6).disabled(connection.savingStory || connection.hasPendingStory)
            .accessibilityIdentifier("story.scenePrompt")
          Button("story.sendScene") {
            Task { if await connection.submitStoryTurn(episodeId: episodeId, prompt: prompt) { prompt = "" } }
          }.disabled(!connection.canEditStory || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("story.sendScene")
          if connection.savingStory { ProgressView() }
          if let pending = connection.pendingStoryTurn, pending.episodeId == episodeId {
            Text(pending.prompt).font(.caption)
            Button("task.retrySubmission") {
              Task { if await connection.submitStoryTurn(episodeId: episodeId, prompt: pending.prompt) { prompt = "" } }
            }.disabled(connection.savingStory)
          }
          if let task = connection.tasks.first(where: { $0.episodeId == episodeId }) {
            Label(LocalizedStringKey(connection.hasFreshStatus ? task.statusKey : "task.status.saved"),
              systemImage: connection.hasFreshStatus ? task.statusSymbol : "clock.arrow.circlepath")
              .accessibilityIdentifier("story.sceneStatus")
            if !task.finished { Text("story.waiting").font(.caption) }
            if let error = task.error { Text(error).font(.caption).foregroundStyle(.red) }
          }
          if let error = connection.storyError { Text(error).foregroundStyle(.red).font(.caption) }
        }
        }
        ForEach(state.events.filter { $0.episodeId == episodeId }) { event in
          Section {
            if event.forgotten {
              Text("story.forgotten").foregroundStyle(.secondary)
            } else {
              ForEach(Array(event.dialogue.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 4) {
                  Text(name(line.speakerId)).font(.caption.bold())
                  Text(line.text)
                }
              }
              if event.excludedFromContext == true {
                Text("story.excluded").font(.caption).foregroundStyle(.secondary)
              }
              Text("story.eventMemory").font(.caption.bold())
              Text(event.summary).accessibilityIdentifier("story.event.\(event.id)")
              Button("story.editMemory") { editEvent = event }
                .disabled(!connection.canEditStory).accessibilityIdentifier("story.editEvent.\(event.id)")
              ForEach(Array((event.excludedFromContext == true ? [] : event.relationshipChanges).enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                  Text("story.proposedRelationship").font(.caption.bold())
                  Text("\(name(change.fromCharacterId)) → \(name(change.toCharacterId)): \(change.summary)")
                  Button("story.acceptRelationship") {
                    Task {
                      _ = await connection.saveStoryRelationship(episodeId: episodeId,
                        from: change.fromCharacterId, to: change.toCharacterId, summary: change.summary,
                        sourceEventId: event.id, expectedRevision: state.revision, expectedServerId: serverId)
                    }
                  }.disabled(!connection.canEditStory)
                }.font(.caption)
              }
            }
          }
        }
      } else {
        Text("story.unavailable")
      }
    }
    .navigationTitle(episode?.title ?? String(localized: "story.title"))
    .alert("story.sequel", isPresented: $showSequel) {
      TextField("story.episodeTitle", text: $sequelTitle)
      Button("story.create") {
        Task {
          if await connection.createStoryEpisode(title: sequelTitle, castIds: episode?.castIds ?? [],
            predecessorEpisodeId: episodeId) { sequelTitle = "" }
        }
      }
      Button("editor.cancel", role: .cancel) {}
    } message: { Text("story.sequelHelp") }
    .sheet(item: $editEvent) { event in
      if let state { StoryEventEditor(connection: connection, event: event, snapshot: state) }
    }
    .sheet(isPresented: $showRelationships) {
      if let episode, let state { StoryRelationshipsView(connection: connection, episode: episode, snapshot: state) }
    }
  }
}

private func inheritedRelationships(_ state: StoryState, episode: StoryEpisode) -> [StoryRelationship] {
  state.currentRelationships(episodeId: episode.id)
}

private struct StoryRelationshipsView: View {
  @Bindable var connection: TaskConnection
  let episode: StoryEpisode
  @State private var snapshot: StoryState
  @Environment(\.dismiss) private var dismiss
  @State private var from = ""
  @State private var to = ""
  @State private var summary = ""

  init(connection: TaskConnection, episode: StoryEpisode, snapshot: StoryState) {
    self.connection = connection; self.episode = episode
    _snapshot = State(initialValue: snapshot)
  }

  var body: some View {
    NavigationStack {
      Form {
        Text("story.directedHelp").font(.caption)
        Picker("story.from", selection: $from) {
          ForEach(episode.castProfiles, id: \.id) { Text($0.name).tag($0.id) }
        }.accessibilityIdentifier("story.relationshipFrom")
        Picker("story.to", selection: $to) {
          ForEach(episode.castProfiles, id: \.id) { Text($0.name).tag($0.id) }
        }.accessibilityIdentifier("story.relationshipTo")
        TextField("story.relationshipSummary", text: $summary, axis: .vertical)
          .lineLimit(3...8).accessibilityIdentifier("story.relationshipSummary")
        Button("editor.save") {
          Task {
            if await connection.saveStoryRelationship(episodeId: episode.id, from: from, to: to,
              summary: summary, expectedRevision: snapshot.revision, expectedServerId: snapshot.serverId) { dismiss() }
          }
        }.disabled(!connection.canEditStory || connection.story?.revision != snapshot.revision || from == to || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("story.saveRelationship")
        Button("story.removeRelationship", role: .destructive) {
          Task {
            if await connection.saveStoryRelationship(episodeId: episode.id, from: from, to: to,
              summary: "", expectedRevision: snapshot.revision, expectedServerId: snapshot.serverId) { dismiss() }
          }
        }.disabled(!connection.canEditStory || connection.story?.revision != snapshot.revision || from == to || !inheritedRelationships(snapshot, episode: episode).contains {
          $0.fromCharacterId == from && $0.toCharacterId == to
        }).accessibilityIdentifier("story.removeRelationship")
        if let error = connection.storyError { Text(error).foregroundStyle(.red) }
        StoryConflictReview(connection: connection, snapshot: $snapshot, draft: $summary) { latest in
          latest.currentRelationships(episodeId: episode.id).first {
            $0.fromCharacterId == from && $0.toCharacterId == to
          }?.summary ?? ""
        }
      }
      .navigationTitle("story.relationships")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } } }
      .onAppear { from = episode.castIds.first ?? ""; to = episode.castIds.dropFirst().first ?? ""; loadSummary() }
      .onChange(of: from) { loadSummary() }
      .onChange(of: to) { loadSummary() }
      .interactiveDismissDisabled(connection.savingStory)
    }
  }

  private func loadSummary() {
    summary = inheritedRelationships(snapshot, episode: episode).first {
      $0.fromCharacterId == from && $0.toCharacterId == to
    }?.summary ?? ""
  }
}

private struct StoryEventEditor: View {
  @Bindable var connection: TaskConnection
  let event: StoryEvent
  @State private var snapshot: StoryState
  @Environment(\.dismiss) private var dismiss
  @State private var summary: String
  @State private var confirmForget = false

  init(connection: TaskConnection, event: StoryEvent, snapshot: StoryState) {
    self.connection = connection; self.event = event
    _snapshot = State(initialValue: snapshot)
    _summary = State(initialValue: event.summary)
  }

  var body: some View {
    NavigationStack {
      Form {
        Text("story.correctionHelp").font(.caption).foregroundStyle(.secondary)
        TextField("story.eventMemory", text: $summary, axis: .vertical).lineLimit(4...10)
          .accessibilityIdentifier("story.eventSummary")
        Button("editor.save") { Task { await save(forgotten: false) } }
          .disabled(!connection.canEditStory || connection.story?.revision != snapshot.revision || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("story.saveMemory")
        Button("story.forgetMemory", role: .destructive) { confirmForget = true }
          .disabled(!connection.canEditStory || connection.story?.revision != snapshot.revision).accessibilityIdentifier("story.forgetMemory")
        if let error = connection.storyError { Text(error).foregroundStyle(.red) }
        StoryConflictReview(connection: connection, snapshot: $snapshot, draft: $summary) { latest in
          latest.events.first { $0.id == event.id }?.summary ?? ""
        }
        if let current = connection.story?.events.first(where: { $0.id == event.id }), current.forgotten {
          Text("story.forgotten").font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("story.eventMemory")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } } }
      .confirmationDialog("story.forgetMemory", isPresented: $confirmForget, titleVisibility: .visible) {
        Button("story.forgetMemory", role: .destructive) { Task { await save(forgotten: true) } }
      } message: { Text("story.forgetHelp") }
      .interactiveDismissDisabled(connection.savingStory)
    }
  }

  private func save(forgotten: Bool) async {
    if await connection.saveStoryEvent(event, summary: summary, forgotten: forgotten,
      expectedRevision: snapshot.revision, expectedServerId: snapshot.serverId) { dismiss() }
  }
}

/// Refreshing displays the conflicting version without advancing the editor's
/// revision. The user must review it and explicitly keep or replace the draft.
private struct StoryConflictReview: View {
  let connection: TaskConnection
  @Binding var snapshot: StoryState
  @Binding var draft: String
  let latestSummary: (StoryState) -> String
  @State private var reviewed: StoryState?

  var body: some View {
    if connection.story?.serverId != snapshot.serverId {
      Text("story.unavailable").foregroundStyle(.secondary)
    } else if connection.story?.revision != snapshot.revision {
      Section("story.conflictTitle") {
        Text("story.conflictHelp").font(.caption).foregroundStyle(.secondary)
        Button("story.reviewLatest") {
          Task {
            await connection.refreshStory()
            if let latest = connection.story, latest.serverId == snapshot.serverId { reviewed = latest }
          }
        }.disabled(connection.loadingStory || connection.savingStory)
          .accessibilityIdentifier("story.reviewLatest")
        if let reviewed {
          Text("story.latestSaved").font(.caption.bold())
          Text(latestSummary(reviewed).isEmpty ? String(localized: "story.noSavedSummary") : latestSummary(reviewed))
            .accessibilityIdentifier("story.conflictLatest")
          Text("story.yourDraft").font(.caption.bold())
          Text(draft).accessibilityIdentifier("story.conflictDraft")
          Button("story.keepReviewedDraft") { snapshot = reviewed; self.reviewed = nil }
            .disabled(connection.story?.revision != reviewed.revision)
            .accessibilityIdentifier("story.keepReviewedDraft")
          Button("story.useLatest") {
            draft = latestSummary(reviewed); snapshot = reviewed; self.reviewed = nil
          }.disabled(connection.story?.revision != reviewed.revision)
            .accessibilityIdentifier("story.useLatest")
          if connection.story?.revision != reviewed.revision { Text("story.reviewChanged").font(.caption) }
        }
      }
    }
  }
}
