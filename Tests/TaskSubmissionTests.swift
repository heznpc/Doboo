import Foundation
import Testing
#if canImport(Doboo)
@testable import Doboo
#else
@testable import DobooCore
#endif

struct TaskSubmissionTests {
  private let token = String(repeating: "a", count: 64)
  private func submission(_ prompt: String) -> TaskSubmission {
    .init(id: "12345678-1234-1234-1234-123456789abc", prompt: prompt,
      character: .init(id: "doboo", version: 4, name: "Doboo"))
  }

  @Test func limitsUseJavaScriptUTF16UnitsAndActualJSONBytes() throws {
    #expect(try submission(String(repeating: "a", count: 8000)).encodedRequest().count < 20000)
    #expect(throws: TaskSubmission.ValidationError.promptTooLong) {
      try submission(String(repeating: "a", count: 8001)).encodedRequest()
    }
    #expect(try submission(String(repeating: "😀", count: 4000)).encodedRequest().count < 20000)
    #expect(throws: TaskSubmission.ValidationError.promptTooLong) {
      try submission(String(repeating: "😀", count: 4001)).encodedRequest()
    }
    #expect(throws: TaskSubmission.ValidationError.requestTooLarge) {
      try submission(String(repeating: "가", count: 8000)).encodedRequest()
    }
    #expect(throws: TaskSubmission.ValidationError.requestTooLarge) {
      try submission(String(repeating: "\0", count: 4000)).encodedRequest()
    }
    #expect(throws: TaskSubmission.ValidationError.emptyPrompt) { try submission(" \n\t").encodedRequest() }
  }

  @Test func encodedRequestHonorsExactByteBoundary() throws {
    let overhead = try JSONEncoder().encode(submission("")).count
    let available = 20000 - overhead
    let prompt = String(repeating: "가", count: available / 3) + String(repeating: "a", count: available % 3)
    let value = submission(prompt)
    let body = try value.encodedRequest()
    #expect(body.count == 20000)
    #expect(try JSONDecoder().decode(TaskSubmission.self, from: body) == value)
    #expect(throws: TaskSubmission.ValidationError.requestTooLarge) { try submission(prompt + "a").encodedRequest() }
  }

  @Test func persistedPendingBindsRequestToComputerAndCredentialWithoutSavingToken() throws {
    let origin = try #require(TaskEndpointIdentity(url: "https://computer.example/bridge", token: token))
    let value = PendingTaskSubmission(submission: submission("keep the same request ID"), origin: origin)
    let data = try JSONEncoder().encode(value)
    #expect(!String(decoding: data, as: UTF8.self).contains(token))
    let restored = try JSONDecoder().decode(PendingTaskSubmission.self, from: data)
    #expect(restored == value)
    #expect(restored.permitsRetry(on: origin))
    #expect(restored.permitsConnection(to: origin, current: nil))
    for candidate in [
      TaskEndpointIdentity(url: "https://other.example/bridge", token: token),
      TaskEndpointIdentity(url: "https://computer.example/other", token: token),
      TaskEndpointIdentity(url: "https://computer.example/bridge", token: String(repeating: "b", count: 64)),
    ] {
      let candidate = try #require(candidate)
      #expect(!restored.permitsRetry(on: candidate))
      #expect(!restored.permitsConnection(to: candidate, current: candidate))
    }
    let request = try #require(JSONSerialization.jsonObject(with: value.submission.encodedRequest()) as? [String: Any])
    #expect(Set(request.keys) == ["id", "prompt", "character"])
  }

  @Test func legacyPendingCanOnlyReconcileWithTheExistingConnection() throws {
    let request = submission("recover original text")
    let legacy = try JSONDecoder().decode(PendingTaskSubmission.self, from: JSONEncoder().encode(request))
    let current = try #require(TaskEndpointIdentity(url: "https://computer.example", token: token))
    let other = try #require(TaskEndpointIdentity(url: "https://other.example", token: token))
    #expect(legacy.submission == request)
    #expect(legacy.origin == nil)
    #expect(!legacy.permitsRetry(on: current))
    #expect(!legacy.permitsRetry(on: other))
    #expect(legacy.permitsConnection(to: current, current: current))
    #expect(!legacy.permitsConnection(to: other, current: current))
    #expect(!legacy.permitsConnection(to: current, current: nil))
    #expect(try JSONDecoder().decode(PendingTaskSubmission.self, from: JSONEncoder().encode(legacy)) == legacy)
  }

  @Test func onlyExplicitPreAdmissionFailuresReleaseTheRequest() {
    #expect(PendingTaskSubmission.isDefinitiveRejection(status: 400, submissionRejected: true))
    for status in [200, 401, 403, 408, 413, 429, 500, 502, 504] {
      #expect(!PendingTaskSubmission.isDefinitiveRejection(status: status, submissionRejected: true))
    }
    #expect(!PendingTaskSubmission.isDefinitiveRejection(status: 400, submissionRejected: nil))
    #expect(!PendingTaskSubmission.isDefinitiveRejection(status: 409, submissionRejected: false))
  }

  @Test func reconciliationRequiresTheOriginalIDPromptAndCharacterRevision() {
    let request = submission("original request")
    func task(id: String = request.id, prompt: String = request.prompt, version: Int64 = request.character.version) -> CompanionTask {
      .init(id: id, prompt: prompt, character: .init(id: "doboo", version: version, name: "Doboo"),
        project: "test", status: "running", sequence: 1, result: "", activity: "", error: nil,
        threadId: nil, turnId: nil, approvals: [], commands: [])
    }
    #expect(request.matches(task()))
    #expect(!request.matches(task(id: UUID().uuidString)))
    #expect(!request.matches(task(prompt: "another request")))
    #expect(!request.matches(task(version: 3)))
  }

  @Test func endpointCanonicalizationPreservesDestinationBoundaries() throws {
    let expected = try #require(TaskEndpointIdentity(url: "https://computer.example/bridge", token: token))
    #expect(TaskEndpointIdentity(url: "HTTPS://COMPUTER.EXAMPLE:443/bridge/", token: token) == expected)
    for address in ["https:///missing-host", "http://computer.example", "https://user@computer.example", "https://computer.example?token=x", "https://computer.example#fragment"] {
      #expect(TaskEndpointIdentity(url: address, token: token) == nil)
    }
    #expect(TaskEndpointIdentity(url: "http://localhost:1234", token: token) != nil)
  }
  @Test func continuityRetryRequiresExactServerRevisionAndParent() throws {
    var request = submission("continue this conversation")
    request.continuity = .init(serverId: "server-a", companionRevision: 3, parentTaskId: "previous-turn")
    func task(server: String = "server-a", revision: Int = 3, parent: String? = "previous-turn") -> CompanionTask {
      .init(id: request.id, prompt: request.prompt, character: request.character, project: "test", status: "completed",
        sequence: 1, result: "result", activity: "", error: nil, threadId: nil, turnId: nil, approvals: [], commands: [],
        continuity: .init(serverId: server, conversationId: "conversation", parentTaskId: parent,
          companionRevision: revision, generation: 1, profileDigest: "digest", memoryApplied: true,
          historyCount: 1, historyTruncated: false))
    }
    #expect(request.matches(task()))
    #expect(!request.matches(task(server: "server-b")))
    #expect(!request.matches(task(revision: 4)))
    #expect(!request.matches(task(parent: nil)))
    let pending = PendingTaskSubmission(submission: request,
      origin: try #require(TaskEndpointIdentity(url: "https://computer.example", token: token)))
    let restored = try JSONDecoder().decode(PendingTaskSubmission.self, from: JSONEncoder().encode(pending))
    #expect(try restored.submission.encodedRequest() == request.encodedRequest())
  }

  @Test func presentationChangesDoNotChangeTheExecutionProfile() {
    let original = CharacterPack.builtin
    var changed = original
    changed.appearance.tint = "#000000"
    changed.description = "Different presentation"
    #expect(CompanionProfile(original) == CompanionProfile(changed))
    changed.identity.voice = "A distinct speaking style"
    #expect(CompanionProfile(original) != CompanionProfile(changed))
  }

  @Test func onlyMatchingVerifiedWatchReceiptConfirmsSharing() {
    let requestID = UUID().uuidString
    let envelope = WatchConnectionEnvelope(requestId: requestID, url: "https://computer.example",
      token: token, serverId: "server-a")
    #expect(envelope.isValid)
    #expect(WatchConnectionReceipt(requestId: requestID, serverId: "server-a",
      url: envelope.url, saved: true).confirms(envelope))
    for receipt in [
      WatchConnectionReceipt(requestId: UUID().uuidString, serverId: "server-a", url: envelope.url, saved: true),
      WatchConnectionReceipt(requestId: requestID, serverId: "server-b", url: envelope.url, saved: true),
      WatchConnectionReceipt(requestId: requestID, serverId: "server-a", url: "https://other.example", saved: true),
      WatchConnectionReceipt(requestId: requestID, serverId: "server-a", url: envelope.url, saved: false),
    ] { #expect(!receipt.confirms(envelope)) }
    #expect(!WatchConnectionEnvelope(requestId: requestID, url: "http://localhost:1234",
      token: token, serverId: "server-a").isValid)
    #expect(!WatchConnectionEnvelope(requestId: requestID, url: envelope.url,
      token: token, serverId: "").isValid)
    #expect(!WatchConnectionEnvelope(requestId: "invalid", url: envelope.url,
      token: token, serverId: "server-a").isValid)
  }

}
