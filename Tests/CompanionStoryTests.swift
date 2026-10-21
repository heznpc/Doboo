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
}
