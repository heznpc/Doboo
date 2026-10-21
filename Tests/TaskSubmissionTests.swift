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
    let originalBytes = try request.encodedRequest()
    #expect(String(decoding: originalBytes, as: UTF8.self) == #"{"character":{"id":"doboo","name":"Doboo","version":4},"continuity":{"companionRevision":3,"parentTaskId":"previous-turn","serverId":"server-a"},"id":"12345678-1234-1234-1234-123456789abc","prompt":"continue this conversation"}"#)
    #expect(try restored.submission.encodedRequest() == originalBytes)
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

struct WorkTaskTests {
  private func context(_ id: String, revision: Int = 1, generation: Int = 1, digest: String? = nil,
                       version: Int64 = 1) -> CompanionContext {
    var pack = CharacterPack.builtin
    pack.id = id; pack.name = id; pack.version = version
    return .init(characterId: id, profile: CompanionProfile(pack), profileDigest: digest ?? "digest-\(id)",
      revision: revision, memory: "Saved memory", generation: generation, updatedAt: "2026-10-22")
  }

  private func request(_ contexts: [CompanionContext]) -> TaskSubmission {
    .init(id: "12345678-1234-1234-1234-123456789abc", prompt: "Implement and verify this change",
      character: contexts[0].profile.character,
      continuity: .init(serverId: "server", companionRevision: contexts[0].revision, parentTaskId: "parent"),
      work: .init(cast: contexts.map { .init(character: $0.profile.character, companionRevision: $0.revision) }))
  }

  private func task(_ request: TaskSubmission, contexts: [CompanionContext]) -> CompanionTask {
    .init(id: request.id, prompt: request.prompt, character: request.character, project: "project", status: "completed",
      sequence: 1, result: "Actual result", activity: "", error: nil, threadId: "host", turnId: "turn",
      approvals: [], commands: [], continuity: .init(serverId: "server", conversationId: "conversation",
        parentTaskId: "parent", companionRevision: contexts[0].revision, generation: contexts[0].generation,
        profileDigest: contexts[0].profileDigest, memoryApplied: true, historyCount: 1, historyTruncated: false,
        workCast: contexts.map { .init(characterId: $0.characterId, revision: $0.revision,
          generation: $0.generation, profileDigest: $0.profileDigest) }), work: request.work)
  }

  @Test func persistedCastRetriesRetainExactIdentityAndRejectChangedAdvisor() throws {
    let contexts = [context("host"), context("advisor", revision: 3)]
    let request = request(contexts)
    let origin = try #require(TaskEndpointIdentity(url: "https://computer.example", token: String(repeating: "a", count: 64)))
    let pending = PendingTaskSubmission(submission: request, origin: origin)
    let restored = try JSONDecoder().decode(PendingTaskSubmission.self, from: JSONEncoder().encode(pending))
    #expect(try restored.submission.encodedRequest() == request.encodedRequest())
    let admitted = task(request, contexts: contexts)
    #expect(request.matches(admitted))
    var changed = admitted
    changed.work = self.request([contexts[0], context("advisor", revision: 4)]).work
    #expect(!request.matches(changed))
    changed.work = self.request([contexts[0], context("advisor", revision: 3, version: 2)]).work
    #expect(!request.matches(changed))
    changed.work = nil
    #expect(!request.matches(changed))
  }

  @Test func workCastRequiresUniqueRegisteredRevisionsAndHost() throws {
    let host = context("host"), advisor = context("advisor")
    #expect(try request([host, advisor]).encodedRequest().count > 0)
    for invalid in [request([host]), request([host, host]), request([host, context("advisor", revision: 0)]),
                    request((0...6).map { context("member-\($0)") })] {
      #expect(throws: TaskSubmission.ValidationError.invalidWorkCast) { try invalid.encodedRequest() }
    }
    var missingHost = request([host, advisor])
    missingHost.work = request([advisor, context("other")]).work
    #expect(throws: TaskSubmission.ValidationError.invalidWorkCast) { try missingHost.encodedRequest() }
    #expect(request([host, advisor]).work?.matches(companions: [host, advisor]) == true)
    #expect(request([host, advisor]).work?.matches(companions: [host, context("advisor", revision: 2)]) == false)
  }

  @Test func continuationChecksEveryAdvisorAndAllowsUnchangedContextRevisions() {
    let original = [context("host"), context("advisor")]
    let completed = task(request(original), contexts: original)
    #expect(completed.involvedCharacterIds == ["host", "advisor"])
    #expect(completed.hasCurrentWorkCast(in: original))
    #expect(completed.hasCurrentWorkCast(in: [original[0], context("advisor", revision: 2)]))
    #expect(!completed.hasCurrentWorkCast(in: [original[0]]))
    #expect(!completed.hasCurrentWorkCast(in: [original[0], context("advisor", generation: 2)]))
    #expect(!completed.hasCurrentWorkCast(in: [original[0], context("advisor", digest: "new-personality")]))
    #expect(!completed.hasCurrentWorkCast(in: [original[0], context("advisor", version: 2)]))
    var missingFingerprint = completed
    missingFingerprint.continuity?.workCast = nil
    #expect(!missingFingerprint.hasCurrentWorkCast(in: original))
  }

  @Test func legacyTaskAndSubmissionDecodeWithoutWorkFields() throws {
    let contexts = [context("host"), context("advisor")]
    var legacy = task(request(contexts), contexts: contexts)
    legacy.work = nil; legacy.continuity?.workCast = nil
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(CompanionTask.self, from: data)
    #expect(decoded.work == nil && decoded.workRecord == nil && decoded.continuity?.workCast == nil)
    #expect(decoded.hasCurrentWorkCast(in: []))
    var legacyRequest = request(contexts); legacyRequest.work = nil
    let body = try legacyRequest.encodedRequest()
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["work"] == nil)
    #expect(try JSONDecoder().decode(TaskSubmission.self, from: body) == legacyRequest)
  }

  @Test func workRecordDecodesRuntimeEvidenceWithoutInventingSuccess() throws {
    let json = #"""
    {"taskId":"task","summary":"Implemented","decisions":[{"characterId":"advisor","proposalId":"p1","disposition":"deferred","rationale":"Needs more evidence"}],
    "contributions":[{"characterId":"advisor","proposals":[{"id":"p1","summary":"Change a file","rationale":"Fix behavior","paths":["src/app.swift"]}],"rememberedTaskIds":["prior"],"commands":[]}],
    "remainingRisks":["Device run pending"],"evidence":{"commands":[{"itemId":"command-1","threadId":"host","turnId":"turn","command":"swift test","output":"failure","exitCode":1,"status":"completed","purpose":"verification"}],
    "fileChanges":[{"itemId":"file-1","threadId":"host","turnId":"turn","status":"completed","changes":[{"path":"src/app.swift","kind":{"type":"update","unknownFutureField":true},"diff":"+ fixed"}]}]},
    "sourceTaskIds":["prior"],"contextDigest":"digest","project":"project","recordedAt":"2026-10-22"}
    """#
    let record = try JSONDecoder().decode(WorkRecord.self, from: Data(json.utf8))
    #expect(record.decisions[0].label == "보류")
    #expect(record.evidence.commands[0].exitCode == 1)
    #expect(record.evidence.repository == nil)
    #expect(record.evidence.fileChanges[0].changes[0].path == "src/app.swift")
    #expect(record.contributions[0].rememberedTaskIds == record.sourceTaskIds)
    #expect(try JSONDecoder().decode(WorkRecord.self, from: JSONEncoder().encode(record)) == record)
  }

  @Test func repositoryHashesRemainEvidenceWhenRuntimeFileEventsAreMissing() throws {
    let json = #"""
    {"commands":[],"fileChanges":[],"repository":{"available":true,"headBefore":"old-head","headAfter":"new-head","truncated":true,
    "changes":[{"path":"src/app.swift","beforeSHA256":"before-hash","afterSHA256":"after-hash"},{"path":"new-file.swift","afterSHA256":"new-hash"},{"path":"deleted-file.swift","beforeSHA256":"old-hash"}]}}
    """#
    let evidence = try JSONDecoder().decode(WorkRecord.Evidence.self, from: Data(json.utf8))
    #expect(evidence.fileChanges.isEmpty)
    #expect(evidence.hasRecordedFileChanges)
    let repository = try #require(evidence.repository)
    #expect(repository.available && repository.truncated)
    #expect(repository.headBefore == "old-head" && repository.headAfter == "new-head")
    #expect(repository.changes[0].beforeSHA256 == "before-hash")
    #expect(repository.changes[0].afterSHA256 == "after-hash")
    #expect(repository.changes[1].beforeSHA256 == nil)
    #expect(repository.changes[2].afterSHA256 == nil)
    #expect(try JSONDecoder().decode(WorkRecord.Evidence.self, from: JSONEncoder().encode(evidence)) == evidence)
    let unavailable = try JSONDecoder().decode(WorkRecord.Evidence.self, from: Data(
      #"{"commands":[],"fileChanges":[],"repository":{"available":false,"truncated":false,"changes":[]}}"#.utf8))
    #expect(unavailable.repository?.available == false)
    #expect(!unavailable.hasRecordedFileChanges)
  }


  @Test func failedAndInterruptedWorkRetainPartialEvidenceWithoutSavingMemory() throws {
    let contexts = [context("host"), context("advisor")]
    let original = task(request(contexts), contexts: contexts)
    var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    payload["commands"] = [["command": "swift test", "output": "Interrupted after changes", "exitCode": NSNull()]]
    payload["fileChanges"] = [["itemId": "edit-1", "threadId": "host", "turnId": "turn", "status": "completed",
      "changes": [["path": "src/app.swift", "kind": ["type": "update"], "diff": "+ partial change"]]]]
    payload["partialRepositoryEvidence"] = ["available": true, "truncated": true,
      "changes": [["path": "src/app.swift", "beforeSHA256": "before", "afterSHA256": "after"]]]
    for status in ["failed", "interrupted"] {
      payload["status"] = status
      var partial = try JSONDecoder().decode(CompanionTask.self, from: JSONSerialization.data(withJSONObject: payload))
      #expect(partial.finished && partial.showsUnverifiedWorkEvidence)
      #expect(partial.workRecord == nil && partial.castExecution == nil)
      #expect(partial.commands[0].output == "Interrupted after changes")
      #expect(partial.commands[0].exitCode == nil)
      #expect(partial.fileChanges?.first?.changes.first?.path == "src/app.swift")
      #expect(partial.partialRepositoryEvidence?.changes.first?.afterSHA256 == "after")
      #expect(partial.partialRepositoryEvidence?.truncated == true)
      #expect(try JSONDecoder().decode(CompanionTask.self, from: JSONEncoder().encode(partial)) == partial)
      partial.workRecord = .init(taskId: partial.id, summary: "Saved outcome", decisions: [], contributions: [],
        remainingRisks: [], evidence: .init(commands: [], fileChanges: []), sourceTaskIds: [],
        contextDigest: "digest", project: partial.project, recordedAt: "2026-10-22")
      #expect(!partial.showsUnverifiedWorkEvidence)
    }
    payload["status"] = "running"
    payload["commands"] = []
    payload.removeValue(forKey: "fileChanges")
    payload.removeValue(forKey: "partialRepositoryEvidence")
    let running = try JSONDecoder().decode(CompanionTask.self, from: JSONSerialization.data(withJSONObject: payload))
    #expect(!running.showsUnverifiedWorkEvidence)
  }

}
