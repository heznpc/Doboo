import Foundation

struct CompanionTask: Codable, Identifiable, Equatable, Sendable {
  struct Character: Codable, Equatable, Sendable {
    let id: String
    let version: Int64
    let name: String
  }
  struct Approval: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let description: String
  }
  struct Command: Codable, Equatable, Sendable {
    let command: String
    let exitCode: Int?
    let output: String
  }
  let id: String
  let prompt: String
  let character: Character
  let project: String
  let status: String
  let sequence: Int
  let result: String
  let activity: String
  let error: String?
  let threadId: String?
  let turnId: String?
  let approvals: [Approval]
  let commands: [Command]
  var continuity: TaskContinuity? = nil
  var finished: Bool { ["completed", "failed", "interrupted"].contains(status) }
  var statusKey: String {
    switch status {
    case "queued", "running", "completed", "failed", "interrupted": "task.status.\(status)"
    case "needsApproval": "task.status.approval"
    default: "task.status.unknown"
    }
  }
  var nextActionKey: String {
    switch status {
    case "queued", "running", "completed", "failed", "interrupted": "task.next.\(status)"
    case "needsApproval": "task.next.approval"
    default: "task.next.unknown"
    }
  }
  var statusSymbol: String {
    switch status {
    case "completed": "checkmark.circle"
    case "needsApproval": "hand.raised"
    case "failed": "exclamationmark.circle"
    case "interrupted": "pause.circle"
    default: "clock"
    }
  }
  var label: String {
    switch status {
    case "queued": "전송됨"
    case "running": "작업 중"
    case "needsApproval": "승인 필요"
    case "completed": "완료"
    case "failed": "실패"
    case "interrupted": "중단됨"
    default: "상태 확인 필요"
    }
  }
}

/// Server-owned personality and explicit memory, independent of image variants.
struct CompanionProfile: Codable, Equatable, Sendable {
  let id: String
  let version: Int64
  let name: String
  let identity: CharacterPack.Identity
  let personality: CharacterPack.Personality

  init(_ pack: CharacterPack) {
    id = pack.id; version = pack.version; name = pack.name
    identity = pack.identity; personality = pack.personality
  }

  var character: CompanionTask.Character { .init(id: id, version: version, name: name) }
}

struct CompanionContext: Codable, Equatable, Identifiable, Sendable {
  let characterId: String
  let profile: CompanionProfile
  let profileDigest: String
  let revision: Int
  let memory: String
  let generation: Int
  let updatedAt: String
  var id: String { characterId }
}

struct TaskContinuity: Codable, Equatable, Sendable {
  let serverId: String
  let conversationId: String
  let parentTaskId: String?
  let companionRevision: Int
  let generation: Int
  let profileDigest: String
  let memoryApplied: Bool
  let historyCount: Int
  let historyTruncated: Bool
}
