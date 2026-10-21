import Foundation

private struct StoryCheckFailure: Error, CustomStringConvertible { let description: String }

@main
struct StoryFlow {
  @MainActor static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw StoryCheckFailure(description: message) }
  }

  @MainActor static func waitForScene(_ client: TaskConnection, episodeId: String) async throws -> CompanionTask {
    let deadline = Date().addingTimeInterval(240)
    while Date() < deadline {
      await client.refresh()
      if let task = client.tasks.first(where: { $0.episodeId == episodeId }), task.finished {
        try require(task.status == "completed", "Scene failed: \(task.error ?? task.status)")
        try require(task.commands.isEmpty && task.approvals.isEmpty, "Fictional scene executed real commands")
        await client.refreshStory()
        guard let event = client.story?.events.first(where: { $0.taskId == task.id }),
              let execution = task.castExecution else {
          throw StoryCheckFailure(description: "Completed scene lacks a canonical event or native cast receipt")
        }
        try require(execution.mode == "native_subagents" && event.castExecution == execution, "Event and task native receipts differ")
        let castIds = client.story!.episodes.first(where: { $0.id == episodeId })!.castIds
        try require(Set(execution.agents.map(\.characterId)) == Set(castIds), "Cast execution is incomplete")
        try require(Set(execution.agents.compactMap(\.threadId)).count == castIds.count, "Characters share a thread or have no native thread")
        try require(execution.coordinatorThreadId == task.threadId, "Coordinator thread mismatch")
        try require(Set(execution.agents.compactMap(\.model)).count == 1 && Set(execution.agents.compactMap(\.reasoningEffort)).count == 1, "Character model or reasoning levels differ")
        for agent in execution.agents {
          try require(agent.agentRole != nil && agent.instructionsDigest?.count == 64, "Host-authored character role binding missing")
          try require(agent.status == "completed" && agent.parentThreadId == task.threadId && agent.threadId != task.threadId,
                      "Character did not complete as a separate direct native child")
          guard let response = agent.response?.data(using: .utf8),
                let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                let sourceLines = json["dialogue"] as? [[String: String]] else {
            throw StoryCheckFailure(description: "Native character response missing")
          }
          try require(json["contextDigest"] as? String == execution.contextDigest, "Character saw a different context digest")
          let dialogue = event.dialogue.filter { $0.speakerId == agent.characterId }
          try require(!dialogue.isEmpty && dialogue.count == sourceLines.count, "Canonical dialogue omitted a child contribution")
          for line in dialogue {
            try require(line.sourceThreadId == agent.threadId && line.sourceTurnId == agent.turnId && line.sourceMessageId == agent.finalMessageId,
                        "Canonical dialogue lacks exact native source IDs")
            guard let index = line.sourceIndex, sourceLines.indices.contains(index) else {
              throw StoryCheckFailure(description: "Canonical dialogue source index missing")
            }
            try require(line.text == sourceLines[index]["text"], "Coordinator rewrote character dialogue")
          }
        }
        print("PASS cast receipts: \(execution.agents.compactMap(\.threadId).joined(separator: ", ")); context \(execution.contextDigest ?? "missing")")
        return task
      }
      try await Task.sleep(for: .milliseconds(300))
    }
    throw StoryCheckFailure(description: "Scene timed out")
  }

  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let phase = CommandLine.arguments[2]
    let endpoint = try JSONDecoder().decode(ComputerConnection.self, from: Data(contentsOf: root.appendingPathComponent("bridge/connection.json")))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = TaskConnection(storage: root.appendingPathComponent(phase == "seed" ? "phone" : "second-device"), session: session, persistCredential: { _ in })
    client.setSceneActive(true)
    defer { client.setSceneActive(false) }
    client.address = endpoint.url; client.connectionToken = endpoint.token
    let connected = await client.connect()
    try require(connected, "Connection failed: \(client.error ?? "unknown")")
    await client.refreshStory()

    if phase == "seed" {
      for (id, name, marker, trait) in [("ember", "Ember", "[EMBER]", "impulsive and enthusiastic"), ("moss", "Moss", "[MOSS]", "cautious and analytical")] {
        var pack = CharacterPack.builtin
        pack.id = id; pack.name = name
        pack.identity = .init(backstory: "A fictional traveler in the observatory.", voice: "Start each of your dialogue lines with \(marker).")
        pack.personality = .init(traits: [trait], instructions: ["Respect the recorded fictional events. If a requested code is absent, say UNKNOWN. Keep dialogue short."])
        let saved = await client.saveCompanion(character: pack, memory: "", expectedRevision: 0)
        try require(saved, "Cast registration failed: \(client.error ?? "unknown")")
      }
      await client.refreshStory()
      let created = await client.createStoryEpisode(title: "Observatory arrival", castIds: ["ember", "moss"])
      try require(created, "Episode creation failed: \(client.storyError ?? "unknown")")
      let episode = client.story!.episodes.last!
      let related = await client.saveStoryRelationship(episodeId: episode.id, from: "moss", to: "ember", summary: "Moss distrusts Ember's reckless choices.", expectedRevision: client.story!.revision, expectedServerId: client.serverId!)
      try require(related, "Relationship save failed")
      let sent = await client.submitStoryTurn(episodeId: episode.id, prompt: "Create a short fictional scene: Ember shares the observatory code AURORA913 with Moss, who reluctantly accepts the help. Include this code in the event summary. Propose the directed relationship change that Moss now trusts Ember with the observatory code. Both characters must speak in their distinctive voices. No tools.")
      try require(sent, "Scene submit failed: \(client.storyError ?? "unknown")")
      let task = try await waitForScene(client, episodeId: episode.id)
      try require(task.result.contains("[EMBER]") && task.result.contains("[MOSS]"), "Distinct character voices absent")
      let event = client.story!.events.first(where: { $0.taskId == task.id })!
      try require(event.summary.contains("AURORA913"), "Event memory omitted the story fact")
      let accepted = await client.saveStoryRelationship(episodeId: episode.id, from: "moss", to: "ember", summary: "Moss trusts Ember with the shared observatory code AURORA913.", sourceEventId: event.id, expectedRevision: client.story!.revision, expectedServerId: client.serverId!)
      try require(accepted, "Event-sourced relationship confirmation failed")
      try JSONEncoder().encode(client.story!).write(to: root.appendingPathComponent("story-seed.json"))
      print("PASS native client: two cast voices, fictional event memory and confirmed directional relationship")
    } else {
      let seed = try JSONDecoder().decode(StoryState.self, from: Data(contentsOf: root.appendingPathComponent("story-seed.json")))
      try require(client.story?.serverId == seed.serverId && client.story?.events == seed.events, "Restart lost story state")
      let original = seed.episodes[0]
      let sequelCreated = await client.createStoryEpisode(title: "Observatory return", castIds: original.castIds, predecessorEpisodeId: original.id)
      try require(sequelCreated, "Sequel rejected: \(client.storyError ?? "unknown")")
      let sequel = client.story!.episodes.last!
      try require(sequel.id != original.id, "Sequel not created")
      let sent = await client.submitStoryTurn(episodeId: sequel.id, prompt: "Continue the story on the next day. Have each character say the observatory code from canonical memory and describe Moss's current trust in Ember from the supplied relationship. Include the known code in the new summary. If unknown, say UNKNOWN. No tools.")
      try require(sent, "Sequel submit failed: \(client.storyError ?? "unknown")")
      let continued = try await waitForScene(client, episodeId: sequel.id)
      try require(continued.result.contains("AURORA913"), "Prior episode memory missing from sequel")
      try require(continued.castExecution?.sourceEventIds?.contains(seed.events[0].id) == true, "Sequel receipt omitted prior event memory")
      try require(Set(continued.castExecution!.agents.compactMap(\.threadId)).isDisjoint(with: Set(seed.events[0].castExecution!.agents.compactMap(\.threadId))), "Sequel reused old character conversation history")
      print("PASS second native client after restart: sequel inherited prior episode memory")

      let event = client.story!.events.first(where: { $0.id == seed.events[0].id })!
      let forgotten = await client.saveStoryEvent(event, summary: event.summary, forgotten: true, expectedRevision: client.story!.revision, expectedServerId: client.serverId!)
      try require(forgotten, "Forget failed: \(client.storyError ?? "unknown")")
      let afterForget = await client.submitStoryTurn(episodeId: sequel.id, prompt: "Both characters must report the observatory code only if present in canonical memories or relationships. Otherwise both must say UNKNOWN. Never invent a code. No tools.")
      try require(afterForget, "Post-forget submit failed")
      let fresh = try await waitForScene(client, episodeId: sequel.id)
      try require(fresh.result.contains("UNKNOWN") && !fresh.result.contains("AURORA913"), "Forgotten event resurfaced from a descendant or relation")
      try require(fresh.castExecution?.sourceEventIds?.isEmpty == true && fresh.castExecution?.relationshipIds?.isEmpty == true, "Forgotten event or derived relationship was supplied to children")
      print("PASS forgetting: prior and derived episode context excluded from actual output")

      let independent = await client.createStoryEpisode(title: "Separate world", castIds: original.castIds)
      try require(independent, "Independent episode creation failed")
      let other = client.story!.episodes.last!
      let independentSent = await client.submitStoryTurn(episodeId: other.id, prompt: "Both characters report any known observatory code. If absent from canonical memories and relationships say UNKNOWN. No tools.")
      try require(independentSent, "Independent scene submit failed")
      let isolated = try await waitForScene(client, episodeId: other.id)
      try require(!isolated.result.contains("AURORA913") && isolated.result.contains("UNKNOWN"), "Unrelated stories leaked context")
      print("PASS unrelated episode isolation")
    }
  }
}
