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
  var episodeId: String? = nil
  var castExecution: StoryCastExecution? = nil
  var work: WorkRequest? = nil
  var workRecord: WorkRecord? = nil
  var partialRepositoryEvidence: WorkRecord.Repository? = nil
  var fileChanges: [WorkRecord.FileChange]? = nil

  /// Partial runtime evidence is visible without becoming a saved work outcome.
  var showsUnverifiedWorkEvidence: Bool {
    work != nil && workRecord == nil
      && (finished || !commands.isEmpty || fileChanges?.isEmpty == false || partialRepositoryEvidence != nil)
  }
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
  let characterization: CharacterPack.Characterization?

  init(_ pack: CharacterPack) {
    id = pack.id; version = pack.version; name = pack.name
    identity = pack.identity; personality = pack.personality
    characterization = pack.characterization
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
  var workCast: [WorkCastContext]? = nil
}

struct WorkCastContext: Codable, Equatable, Sendable {
  let characterId: String
  let revision: Int
  let generation: Int
  let profileDigest: String
}

extension CompanionTask {
  var involvedCharacterIds: Set<String> {
    Set(work?.cast.map { $0.character.id } ?? [character.id])
  }

  /// Saving unchanged context may advance revisions. A new personality or
  /// history generation invalidates continuation for every advisor and the host.
  func hasCurrentWorkCast(in companions: [CompanionContext]) -> Bool {
    guard let work else { return true }
    guard work.isValid(host: character), let frozen = continuity?.workCast,
      frozen.count == work.cast.count,
      Set(frozen.map(\.characterId)) == involvedCharacterIds else { return false }
    return work.cast.allSatisfy { member in
      guard let saved = frozen.first(where: { $0.characterId == member.character.id }),
        let current = companions.first(where: { $0.characterId == member.character.id }) else { return false }
      return saved.revision == member.companionRevision
        && current.profile.character == member.character
        && current.generation == saved.generation && current.profileDigest == saved.profileDigest
    }
  }
}

struct WorkRecord: Codable, Equatable, Sendable {
  struct Decision: Codable, Equatable, Sendable {
    let characterId: String
    let proposalId: String
    let disposition: String
    let rationale: String

    var label: String {
      switch disposition {
      case "adopted": "채택"
      case "rejected": "기각"
      case "deferred": "보류"
      default: "확인 필요"
      }
    }
  }
  struct Proposal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let summary: String
    let rationale: String
    let paths: [String]
  }
  struct Contribution: Codable, Identifiable, Equatable, Sendable {
    let characterId: String
    let proposals: [Proposal]
    let rememberedTaskIds: [String]
    let commands: [Command]
    var id: String { characterId }
  }
  struct Command: Codable, Equatable, Sendable {
    let itemId: String
    let threadId: String
    let turnId: String
    let command: String
    let output: String
    let exitCode: Int?
    let status: String
    var cwd: String? = nil
    var purpose: String? = nil
  }
  struct FileChange: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
      struct Kind: Codable, Equatable, Sendable {
        let type: String
        var move_path: String? = nil
      }
      let path: String
      let kind: Kind
      let diff: String
    }
    let itemId: String
    let threadId: String
    let turnId: String
    let status: String
    let changes: [Change]
  }
  struct Repository: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
      let path: String
      var beforeSHA256: String? = nil
      var afterSHA256: String? = nil
    }
    let available: Bool
    var headBefore: String? = nil
    var headAfter: String? = nil
    let truncated: Bool
    let changes: [Change]
  }
  struct Evidence: Codable, Equatable, Sendable {
    let commands: [Command]
    let fileChanges: [FileChange]
    var repository: Repository? = nil

    var hasRecordedFileChanges: Bool {
      fileChanges.contains { !$0.changes.isEmpty } || repository?.changes.isEmpty == false
    }
  }
  let taskId: String
  let summary: String
  let decisions: [Decision]
  let contributions: [Contribution]
  let remainingRisks: [String]
  let evidence: Evidence
  let sourceTaskIds: [String]
  let contextDigest: String
  let project: String
  let recordedAt: String
}
