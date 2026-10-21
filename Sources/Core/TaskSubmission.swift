import Foundation
import CryptoKit

struct TaskEndpointIdentity: Codable, Equatable, Sendable {
  let url: String
  private let credentialDigest: String

  init?(url: String, token: String) {
    guard token.count >= 32, var components = URLComponents(string: url),
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
      scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(host)) else { return nil }
    components.scheme = scheme; components.host = host
    if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
    while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
    guard let normalized = components.url?.absoluteString else { return nil }
    self.url = normalized
    credentialDigest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct TaskSubmission: Codable, Equatable, Sendable {
  let id: String
  let prompt: String
  let character: CompanionTask.Character
  var continuity: Continuity? = nil
  var work: WorkRequest? = nil

  struct Continuity: Codable, Equatable, Sendable {
    let serverId: String
    let companionRevision: Int
    let parentTaskId: String?
  }

  enum ValidationError: LocalizedError, Equatable {
    case emptyPrompt, promptTooLong, requestTooLarge, invalidWorkCast

    var errorDescription: String? {
      switch self {
      case .emptyPrompt: "부탁할 작업을 입력해 주세요."
      case .promptTooLong: "작업 내용이 너무 깁니다. 8,000자 이내로 줄여 주세요. 이모지는 두 글자로 계산될 수 있습니다."
      case .requestTooLarge: "작업 요청이 20,000바이트를 넘습니다. 내용을 줄여 주세요."
      case .invalidWorkCast: "진행 캐릭터를 포함해 적용된 캐릭터 2~6명을 선택해 주세요."
      }
    }
  }

  /// Return the exact bytes sent to the bridge, which uses JavaScript's UTF-16 length.
  func encodedRequest() throws -> Data {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptyPrompt }
    guard prompt.utf16.count <= 8000 else { throw ValidationError.promptTooLong }
    if let work, !work.isValid(host: character) { throw ValidationError.invalidWorkCast }
    // Reconstructing a pending request must retain its wire representation;
    // JSONEncoder's default object-key order can change between encodes.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = try encoder.encode(self)
    guard body.count <= 20000 else { throw ValidationError.requestTooLarge }
    return body
  }

  func matches(_ task: CompanionTask) -> Bool {
    guard id == task.id, prompt == task.prompt, character == task.character, work == task.work else { return false }
    guard let continuity else { return task.continuity == nil }
    return task.continuity?.serverId == continuity.serverId
      && task.continuity?.companionRevision == continuity.companionRevision
      && task.continuity?.parentTaskId == continuity.parentTaskId
  }
}

/// The cast advises the host; selecting a character does not grant execution authority.
struct WorkRequest: Codable, Equatable, Sendable {
  struct Member: Codable, Equatable, Sendable {
    let character: CompanionTask.Character
    let companionRevision: Int
  }
  let cast: [Member]

  func isValid(host: CompanionTask.Character) -> Bool {
    (2...6).contains(cast.count)
      && Set(cast.map { $0.character.id }).count == cast.count
      && cast.contains { $0.character == host }
      && cast.allSatisfy { $0.companionRevision > 0 && $0.character.version > 0 && !$0.character.id.isEmpty }
  }

  func matches(companions: [CompanionContext]) -> Bool {
    cast.allSatisfy { member in
      companions.contains { $0.profile.character == member.character && $0.revision == member.companionRevision }
    }
  }
}

struct PendingTaskSubmission: Codable, Equatable, Sendable {
  let submission: TaskSubmission
  let origin: TaskEndpointIdentity?

  init(submission: TaskSubmission, origin: TaskEndpointIdentity) {
    self.submission = submission; self.origin = origin
  }

  private enum CodingKeys: String, CodingKey { case submission, origin }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.submission) {
      submission = try container.decode(TaskSubmission.self, forKey: .submission)
      origin = try container.decodeIfPresent(TaskEndpointIdentity.self, forKey: .origin)
    } else {
      // Old pending records did not identify their computer. They can only be
      // reconciled by reading an existing matching task, never replayed blindly.
      submission = try TaskSubmission(from: decoder)
      origin = nil
    }
  }

  func permitsConnection(to candidate: TaskEndpointIdentity, current: TaskEndpointIdentity?) -> Bool {
    guard let expected = origin ?? current else { return false }
    return candidate == expected
  }

  func permitsRetry(on endpoint: TaskEndpointIdentity) -> Bool {
    origin == endpoint
  }

  static func isDefinitiveRejection(status: Int, submissionRejected: Bool?) -> Bool {
    // The bridge only asserts this marker after establishing non-admission.
    // A generic 4xx, ID conflict, proxy failure, or undecodable response is not proof.
    [400, 409, 422].contains(status) && submissionRejected == true
  }
}

/// One-shot paired-device envelope. It is never stored in preferences or queued
/// for background delivery; only a verified Keychain save merits a receipt.
struct WatchConnectionEnvelope: Codable, Equatable, Sendable {
  let requestId: String
  let url: String
  let token: String
  let serverId: String

  var endpoint: TaskEndpointIdentity? { TaskEndpointIdentity(url: url, token: token) }
  var isValid: Bool {
    guard UUID(uuidString: requestId) != nil, url.utf8.count <= 2048, token.utf8.count <= 4096, let endpoint,
      endpoint.url == url, URL(string: url)?.scheme == "https",
      !serverId.isEmpty, serverId.utf8.count <= 128 else { return false }
    return true
  }
}

struct WatchConnectionReceipt: Codable, Equatable, Sendable {
  let requestId: String
  let serverId: String
  let url: String
  let saved: Bool

  func confirms(_ envelope: WatchConnectionEnvelope) -> Bool {
    saved && requestId == envelope.requestId && serverId == envelope.serverId && url == envelope.url
  }
}
