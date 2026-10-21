import Foundation
import Testing
#if canImport(Doboo)
@testable import Doboo
#else
@testable import DobooCore
#endif

struct CompanionStoryTests {
  @Test func relationshipInheritanceUsesLineageRatherThanSeriesOrTimestamp() {
    func episode(_ id: String, predecessor: String? = nil) -> StoryEpisode {
      .init(id: id, title: id, castIds: ["a", "b"], castProfiles: [], seriesId: "series",
        predecessorEpisodeId: predecessor, taskIds: [], createdAt: "now", updatedAt: "now")
    }
    func relation(_ id: String, episode: String, reverse: Bool = false,
        timestamp: String = "2026-01-01", deleted: Bool = false) -> StoryRelationship {
      .init(id: id, episodeId: episode, fromCharacterId: reverse ? "b" : "a",
        toCharacterId: reverse ? "a" : "b", summary: id, updatedAt: timestamp,
        sourceEventId: nil, deleted: deleted)
    }
    let state = StoryState(serverId: "server", revision: 1, relationships: [
      relation("parent-newer-date", episode: "parent", timestamp: "2027-01-01"),
      relation("reverse-parent", episode: "parent", reverse: true),
      relation("child-override", episode: "child"),
      relation("child-delete-reverse", episode: "child", reverse: true, deleted: true),
      relation("future", episode: "future", timestamp: "2028-01-01"),
      relation("unrelated", episode: "unrelated", timestamp: "2029-01-01")
    ], events: [], episodes: [episode("parent"), episode("child", predecessor: "parent"),
      episode("future", predecessor: "child"), episode("unrelated")])
    #expect(state.currentRelationships(episodeId: "parent").map(\.id) == ["parent-newer-date", "reverse-parent"])
    #expect(state.currentRelationships(episodeId: "child").map(\.id) == ["child-override"])
    #expect(state.currentRelationships(episodeId: "future").map(\.id) == ["future"])
    #expect(state.currentRelationships(episodeId: "unrelated").map(\.id) == ["unrelated"])
    #expect(state.currentRelationships(episodeId: "missing").isEmpty)
  }

  @Test func pendingSceneRoundTripRetainsRequestAndServerWithoutRawCredential() throws {
    let token = String(repeating: "z", count: 64)
    let endpoint = try #require(TaskEndpointIdentity(url: "https://example.test", token: token))
    let pending = PendingStoryTurn(origin: endpoint, serverId: "computer-one", episodeId: "episode-one",
      expectedRevision: 12, requestId: "request-one", prompt: "Continue at the lighthouse")
    let persisted = try JSONEncoder().encode(pending)
    #expect(!String(decoding: persisted, as: UTF8.self).contains(token))
    let restored = try JSONDecoder().decode(PendingStoryTurn.self, from: persisted)
    #expect(restored == pending)
    let payload = try #require(JSONSerialization.jsonObject(with: restored.encodedRequest()) as? [String: Any])
    #expect(payload["requestId"] as? String == "request-one")
    #expect(payload["serverId"] as? String == "computer-one")
    #expect(payload["expectedRevision"] as? Int == 12)
    #expect(payload["origin"] == nil)
    #expect(endpoint != TaskEndpointIdentity(url: "https://other.test", token: token))
    #expect(endpoint != TaskEndpointIdentity(url: "https://example.test", token: String(repeating: "y", count: 64)))
  }

  @Test func decodesMemoryExclusionAndRelationshipTombstone() throws {
    let data = Data(#"""
    {"serverId":"computer-one","revision":3,"episodes":[],"relationships":[
      {"id":"r","episodeId":"e","fromCharacterId":"a","toCharacterId":"b","summary":"","updatedAt":"now","sourceEventId":null,"deleted":true}
    ],"events":[
      {"id":"event","episodeId":"e","taskId":"task","summary":"Old memory","forgotten":false,"createdAt":"now","dialogue":[],"relationshipChanges":[],"excludedFromContext":true,"kind":"fictional_scene"}
    ]}
    """#.utf8)
    let state = try JSONDecoder().decode(StoryState.self, from: data)
    #expect(state.events[0].excludedFromContext == true)
    #expect(state.relationships[0].deleted == true)
    #expect(try JSONDecoder().decode(StoryState.self, from: JSONEncoder().encode(state)) == state)
  }

  @Test func legacySceneAndTaskDoNotGainExecutionEvidence() throws {
    let event = try JSONDecoder().decode(StoryEvent.self, from: Data(#"""
    {"id":"event","episodeId":"episode","taskId":"task","summary":"A saved scene",
     "forgotten":false,"createdAt":"now","dialogue":[{"speakerId":"a","text":"Hello"}],
     "relationshipChanges":[]}
    """#.utf8))
    let task = try JSONDecoder().decode(CompanionTask.self, from: Data(#"""
    {"id":"task","prompt":"Continue","character":{"id":"a","version":1,"name":"A"},
     "project":"story","status":"completed","sequence":1,"result":"Hello","activity":"",
     "approvals":[],"commands":[]}
    """#.utf8))
    #expect(event.castExecution == nil)
    #expect(task.castExecution == nil)
    #expect(try JSONDecoder().decode(StoryEvent.self, from: JSONEncoder().encode(event)) == event)
    #expect(try JSONDecoder().decode(CompanionTask.self, from: JSONEncoder().encode(task)) == task)
  }

  @Test func executionReceiptPreservesOriginalResponsesAndOptionalRuntimeEvidence() throws {
    let data = Data(#"""
    {"id":"task","prompt":"Continue","character":{"id":"a","version":7,"name":"A"},
     "project":"story","status":"completed","sequence":2,"result":"A scene","activity":"",
     "approvals":[],"commands":[],"episodeId":"episode","castExecution":{
       "mode":"native_subagents","coordinatorThreadId":"coordinator","contextRevision":12,"contextDigest":"scene-digest",
       "sourceEventIds":["earlier-event"],"relationshipIds":["relationship"],"historyTruncated":true,
       "agents":[
         {"characterId":"a","profileVersion":7,"threadId":"child-a","status":"completed",
          "rawResult":"  **그대로**\n두 번째 줄.  ",
          "parentThreadId":"coordinator","turnId":"turn-a","finalMessageId":"message-a",
          "model":"configured-model","reasoningEffort":"high","agentRole":"scene-role-a","instructionsDigest":"instructions-a"},
         {"characterId":"b","profileVersion":2,"threadId":"child-b","status":"completed",
          "rawResult":"Hello"}
       ]
     }}
    """#.utf8)
    let task = try JSONDecoder().decode(CompanionTask.self, from: data)
    let execution = try #require(task.castExecution)
    #expect(execution.hasCharacterAgents)
    #expect(execution.coordinatorThreadId == "coordinator")
    #expect(execution.contextRevision == 12)
    #expect(execution.contextDigest == "scene-digest")
    #expect(execution.sourceEventIds == ["earlier-event"])
    #expect(execution.relationshipIds == ["relationship"])
    #expect(execution.historyTruncated == true)
    #expect(execution.agents.map(\.threadId) == ["child-a", "child-b"])
    #expect(execution.agents[0].characterVersion == 7)
    #expect(execution.agents[0].response == "  **그대로**\n두 번째 줄.  ")
    #expect(execution.agents[0].parentThreadId == "coordinator")
    #expect(execution.agents[0].turnId == "turn-a")
    #expect(execution.agents[0].finalMessageId == "message-a")
    #expect(execution.agents[0].model == "configured-model")
    #expect(execution.agents[0].reasoningEffort == "high")
    #expect(execution.agents[0].agentRole == "scene-role-a")
    #expect(execution.agents[0].instructionsDigest == "instructions-a")
    #expect(execution.agents[1].agentRole == nil)
    #expect(execution.agents[1].model == nil)
    #expect(execution.agents[1].reasoningEffort == nil)
    #expect(try JSONDecoder().decode(CompanionTask.self, from: JSONEncoder().encode(task)) == task)

    let event = StoryEvent(id: "event", episodeId: "episode", taskId: task.id,
      summary: "Reviewed memory", forgotten: false, createdAt: "now", dialogue: [
        StoryDialogue(speakerId: "a", text: "그대로", sourceThreadId: "child-a",
          sourceTurnId: "turn-a", sourceMessageId: "message-a", sourceIndex: 0)
      ],
      relationshipChanges: [], castExecution: execution)
    let eventData = try JSONEncoder().encode(event)
    let eventPayload = try #require(JSONSerialization.jsonObject(with: eventData) as? [String: Any])
    #expect(eventPayload["execution"] != nil)
    #expect(eventPayload["castExecution"] == nil)
    let restored = try JSONDecoder().decode(StoryEvent.self, from: eventData)
    #expect(restored.castExecution == execution)
    #expect(restored.castExecution?.agents[0].response == "  **그대로**\n두 번째 줄.  ")
    #expect(restored.dialogue[0].sourceThreadId == "child-a")
    #expect(restored.dialogue[0].sourceTurnId == "turn-a")
    #expect(restored.dialogue[0].sourceMessageId == "message-a")
    #expect(restored.dialogue[0].sourceIndex == 0)
  }

  @Test func partialExecutionDecodesWithoutAResponseOrOptionalMetadata() throws {
    let execution = try JSONDecoder().decode(StoryCastExecution.self, from: Data(#"""
    {"mode":"native_subagents","coordinatorThreadId":"coordinator","agents":[
      {"characterId":"a","profileVersion":1,"threadId":"child-a","status":"running"},
      {"characterId":"b","profileVersion":1,"threadId":"child-b","status":"failed","error":"Runner disconnected"},
      {"characterId":"c","profileVersion":1,"status":"queued"}
    ]}
    """#.utf8))
    #expect(execution.hasCharacterAgents)
    #expect(execution.contextRevision == nil)
    #expect(execution.contextDigest == nil)
    #expect(execution.agents[0].response == nil)
    #expect(execution.agents[0].statusKey == "story.execution.running")
    #expect(execution.agents[1].statusKey == "story.execution.failed")
    #expect(execution.agents[1].error == "Runner disconnected")
    #expect(execution.agents[2].threadId == nil)
    #expect(execution.agents[2].turnId == nil)
    #expect(execution.agents[2].finalMessageId == nil)
    #expect(execution.agents[2].statusKey == "story.execution.queued")
    #expect(!StoryCastExecution(mode: "legacy", coordinatorThreadId: "coordinator",
      agents: execution.agents).hasCharacterAgents)
    #expect(!StoryCastExecution(mode: "native_subagents", coordinatorThreadId: "coordinator",
      agents: []).hasCharacterAgents)
  }
}
