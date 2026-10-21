import Foundation

/// Fictional episode state. Event summaries are the editable memory used by later scenes.
struct StoryState: Codable, Equatable, Sendable {
  let serverId: String
  let revision: Int
  let relationships: [StoryRelationship]
  let events: [StoryEvent]
  let episodes: [StoryEpisode]

  /// Resolve ancestors first, then the selected episode. Descendants never
  /// alter an earlier episode, and a child override wins regardless of dates.
  func currentRelationships(episodeId: String) -> [StoryRelationship] {
    var lineage: [String] = []
    var visited: Set<String> = []
    var current = episodes.first { $0.id == episodeId }
    while let episode = current, visited.insert(episode.id).inserted {
      lineage.insert(episode.id, at: 0)
      current = episode.predecessorEpisodeId.flatMap { predecessor in
        episodes.first { $0.id == predecessor }
      }
    }
    struct Pair: Hashable { let from: String; let to: String }
    var pairs: [Pair: StoryRelationship] = [:]
    for ancestor in lineage {
      for relationship in relationships where relationship.episodeId == ancestor {
        pairs[Pair(from: relationship.fromCharacterId, to: relationship.toCharacterId)] = relationship
      }
    }
    return pairs.values.filter { $0.deleted != true }.sorted {
      ($0.fromCharacterId, $0.toCharacterId) < ($1.fromCharacterId, $1.toCharacterId)
    }
  }
}

struct StoryRelationship: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let episodeId: String
  let fromCharacterId: String
  let toCharacterId: String
  let summary: String
  let updatedAt: String
  let sourceEventId: String?
  var deleted: Bool? = nil
}

struct StoryDialogue: Codable, Equatable, Sendable {
  let speakerId: String
  let text: String
  var sourceThreadId: String? = nil
  var sourceTurnId: String? = nil
  var sourceMessageId: String? = nil
  var sourceIndex: Int? = nil
}

struct StoryRelationshipChange: Codable, Equatable, Sendable {
  let fromCharacterId: String
  let toCharacterId: String
  let summary: String
}

/// Runtime receipts are distinct from the editable scene dialogue and memory.
struct StoryCastExecution: Codable, Equatable, Sendable {
  struct Agent: Codable, Identifiable, Equatable, Sendable {
    let characterId: String
    let characterVersion: Int64
    let threadId: String?
    let status: String
    let response: String?
    var parentThreadId: String? = nil
    var turnId: String? = nil
    var finalMessageId: String? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil
    var error: String? = nil
    var agentRole: String? = nil
    var instructionsDigest: String? = nil

    enum CodingKeys: String, CodingKey {
      case characterId, threadId, status, parentThreadId, turnId, finalMessageId
      case model, reasoningEffort, error, agentRole, instructionsDigest
      case characterVersion = "profileVersion"
      case response = "rawResult"
    }

    var id: String { characterId }
    var statusKey: String {
      switch status {
      case "queued", "running", "completed", "failed", "interrupted": "story.execution.\(status)"
      default: "task.status.unknown"
      }
    }
    var statusSymbol: String {
      switch status {
      case "completed": "checkmark.circle"
      case "failed": "exclamationmark.circle"
      case "interrupted": "stop.circle"
      default: "clock"
      }
    }
  }

  let mode: String
  let coordinatorThreadId: String
  let agents: [Agent]
  var contextRevision: Int? = nil
  var contextDigest: String? = nil
  var sourceEventIds: [String]? = nil
  var relationshipIds: [String]? = nil
  var historyTruncated: Bool? = nil

  var hasCharacterAgents: Bool { mode == "native_subagents" && !agents.isEmpty }
}

struct StoryEvent: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let episodeId: String
  let taskId: String
  let summary: String
  let forgotten: Bool
  let createdAt: String
  let dialogue: [StoryDialogue]
  var excludedFromContext: Bool? = nil
  let relationshipChanges: [StoryRelationshipChange]
  var castExecution: StoryCastExecution? = nil

  enum CodingKeys: String, CodingKey {
    case id, episodeId, taskId, summary, forgotten, createdAt, dialogue
    case excludedFromContext, relationshipChanges
    case castExecution = "execution"
  }
}

struct StoryEpisode: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let castIds: [String]
  let castProfiles: [CompanionProfile]
  let seriesId: String
  let predecessorEpisodeId: String?
  let taskIds: [String]
  let createdAt: String
  let updatedAt: String
}

struct PendingStoryTurn: Codable, Equatable, Sendable {
  let origin: TaskEndpointIdentity
  let serverId: String
  let episodeId: String
  let expectedRevision: Int
  let requestId: String
  let prompt: String

  func encodedRequest() throws -> Data {
    struct Request: Encodable {
      let serverId: String
      let expectedRevision: Int
      let requestId: String
      let prompt: String
    }
    return try JSONEncoder().encode(Request(serverId: serverId, expectedRevision: expectedRevision,
      requestId: requestId, prompt: prompt))
  }
}
