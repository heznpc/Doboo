import Foundation

private struct Failure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(description: message) }
}

// URLSession still creates and cancels real data tasks, but this protocol serves
// every response locally and records stopLoading when cancellation reaches it.
private final class ControlledResponse: @unchecked Sendable {
  private let lock = NSLock()
  private var active: ControlledURLProtocol?
  private var didStart = false
  private var didStop = false
  private var count = 0
  var started: Bool { lock.withLock { didStart } }
  var stopped: Bool { lock.withLock { didStop } }
  var startCount: Int { lock.withLock { count } }

  func start(_ transport: ControlledURLProtocol) {
    lock.withLock { active = transport; didStart = true; count += 1 }
  }

  func stop() {
    lock.withLock { active = nil; didStop = true }
  }

  func reply(project: String, tasks: [[String: Any]] = [], status: Int = 200) throws {
    let body: [String: Any] = status == 200
      ? ["project": project, "tasks": tasks] : ["error": "delayed test failure"]
    try reply(body: body, status: status)
  }

  func reply(body: [String: Any], status: Int = 200) throws {
    let transport = lock.withLock { () -> ControlledURLProtocol? in
      defer { active = nil }
      return active
    }
    guard let transport, let url = transport.request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    else { throw Failure(description: "No active request for the controlled reply") }
    let data = try JSONSerialization.data(withJSONObject: body)
    transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
    transport.client?.urlProtocol(transport, didLoad: data)
    transport.client?.urlProtocolDidFinishLoading(transport)
  }
}

private final class Responses: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: ControlledResponse] = [:]
  func register(_ host: String, response: ControlledResponse) { lock.withLock { values[host] = response } }
  func remove(_ host: String) { lock.withLock { _ = values.removeValue(forKey: host) } }
  func response(for request: URLRequest) -> ControlledResponse? {
    lock.withLock { request.url?.host.flatMap { values[$0] } }
  }
}

private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
  static let responses = Responses()
  private var response: ControlledResponse?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let response = Self.responses.response(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    self.response = response
    response.start(self)
  }
  override func stopLoading() { response?.stop() }
}

@MainActor
private final class CredentialLog {
  var urls: [String] = []
}

@MainActor
private final class Harness {
  let connection: TaskConnection
  let credentials = CredentialLog()
  private let session: URLSession
  private var hosts: [String] = []
  let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let clock = TestClock()

  init(persistFails: Bool = false) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledURLProtocol.self]
    session = URLSession(configuration: configuration)
    let credentials = self.credentials
    let clock = self.clock
    connection = TaskConnection(storage: storage,
      session: session, persistCredential: {
        if persistFails { throw URLError(.cannotWriteToFile) }
        credentials.urls.append($0.url)
      }, now: { clock.date })
    connection.connectionToken = String(repeating: "a", count: 64)
    connection.setSceneActive(true)
  }

  func prepare() -> (String, ControlledResponse) {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let response = ControlledResponse()
    hosts.append(host)
    ControlledURLProtocol.responses.register(host, response: response)
    let address = "https://" + host
    connection.address = address
    return (address, response)
  }

  func close() {
    session.invalidateAndCancel()
    for host in hosts { ControlledURLProtocol.responses.remove(host) }
    try? FileManager.default.removeItem(at: storage)
  }

  func nextResponse() -> ControlledResponse {
    let response = ControlledResponse()
    ControlledURLProtocol.responses.register(URL(string: connection.address)!.host!, response: response)
    return response
  }

  func restoreCache() -> TaskConnection {
    TaskConnection(storage: storage, session: session, persistCredential: { _ in }, now: { self.clock.date })
  }
}

@MainActor
private final class TestClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@main
struct TaskConnectionTests {
  @MainActor
  private static func wait(for condition: @autoclosure () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw Failure(description: "Timed out waiting for URLSession lifecycle") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @MainActor
  static func main() async throws {
    try await cancellationStopsRequestAndAllowsNewAttempt()
    try await cancellationAfterReplyCannotCommit()
    try await inputChangesRejectDelayedReply(changeToken: false)
    try await inputChangesRejectDelayedReply(changeToken: true)
    try await supersededFailureCannotOverwriteSuccess()
    try await freshnessRequiresActiveSessionAndRecentSuccess()
    try await failedRefreshKeepsLastCheckButInvalidatesStatus()
    try await oldForegroundResponseCannotReviveStatus()
    try await refreshCoalescesConcurrentRequests()
    try await savedRunningTaskIsNeverLiveOnRelaunch()
    try await backgroundMutationCannotReviveStatus()
    try await staleActionsSendNoRequests()
    try await changedActionTargetsSendNoRequests()
    try await currentApprovalStillWorks()
    try await receiptFailureDoesNotInvalidateStatus()
    try await serverIdentityChangeCannotReplaceContext()
    try await staleMemoryEditDoesNotOverwriteNewRevision()
    try await missingProfileCannotStartLegacyTask()
    try await continuityGenerationInvalidatesOldFollowup()
    try await watchConnectionRequiresVerifiedPersistence()
    try await delayedWatchVerificationCannotOverrideNewSession()
    try await senderRejectsMismatchedWatchReceipt()
    try await memorySaveKeepsItsOriginalComputer()
    try await watchPersistenceFailureEmitsNoReceipt()
    try await profileCharacterizationSurvivesNativeTransportAndCache()
    print("Passed 25 connection, continuity, and handoff regressions (URLProtocol; no network, WCSession, or Keychain).")
  }

  @MainActor
  private static func cancellationStopsRequestAndAllowsNewAttempt() async throws {
    let harness = Harness()
    defer { harness.close() }
    let (_, oldResponse) = harness.prepare()
    let first = Task { await harness.connection.connect() }
    try await wait(for: oldResponse.started)
    first.cancel()
    try await wait(for: oldResponse.stopped)
    let oldResult = await first.value
    try require(!oldResult && !harness.connection.hasConnection && harness.credentials.urls.isEmpty,
                "Closing a form must cancel URLSession and must not save the old connection")
    try require(harness.connection.error == nil, "A canceled request must not leave a user-facing connection error")

    let (address, newResponse) = harness.prepare()
    let next = Task { await harness.connection.connect() }
    try await wait(for: newResponse.started)
    try newResponse.reply(project: "New computer")
    let result = await next.value
    try require(result && harness.connection.project == "New computer" && harness.credentials.urls == [address],
                "Reopening the form must allow a new attempt without retaining the canceled connection")
  }

  @MainActor
  private static func cancellationAfterReplyCannotCommit() async throws {
    let harness = Harness()
    defer { harness.close() }
    let (_, response) = harness.prepare()
    let attempt = Task { await harness.connection.connect() }
    try await wait(for: response.started)
    try response.reply(project: "Canceled completion")
    // Keep the MainActor until cancellation is set, even if data(for:) has finished.
    attempt.cancel()
    let result = await attempt.value
    try require(!result && harness.credentials.urls.isEmpty && !harness.connection.hasConnection,
                "Cancellation after transport completion must be checked before credentials or state commit")
  }

  @MainActor
  private static func inputChangesRejectDelayedReply(changeToken: Bool) async throws {
    let harness = Harness()
    defer { harness.close() }
    let (_, response) = harness.prepare()
    let attempt = Task { await harness.connection.connect() }
    try await wait(for: response.started)
    if changeToken { harness.connection.connectionToken = String(repeating: "b", count: 64) }
    else { harness.connection.address = "https://edited.invalid" }
    let editedAddress = harness.connection.address
    try response.reply(project: "Stale form")
    let result = await attempt.value
    try require(!result && harness.credentials.urls.isEmpty && harness.connection.address == editedAddress,
                "A delayed response must not overwrite edited address or credential input")
  }

  @MainActor
  private static func supersededFailureCannotOverwriteSuccess() async throws {
    let harness = Harness()
    defer { harness.close() }
    let (_, oldResponse) = harness.prepare()
    let first = Task { await harness.connection.connect() }
    try await wait(for: oldResponse.started)
    let (address, response) = harness.prepare()
    let next = Task { await harness.connection.connect() }
    try await wait(for: response.started)
    try response.reply(project: "Latest computer")
    let result = await next.value
    try oldResponse.reply(project: "", status: 500)
    let oldResult = await first.value
    try require(result && !oldResult && harness.connection.error == nil && harness.credentials.urls == [address]
                && harness.connection.project == "Latest computer",
                "An older response must not change the current form's saved computer or error")
  }

  @MainActor
  private static func establish(_ harness: Harness, tasks: [[String: Any]] = []) async throws {
    let (_, response) = harness.prepare()
    let attempt = Task { await harness.connection.connect() }
    try await wait(for: response.started)
    try response.reply(project: "Computer", tasks: tasks)
    let success = await attempt.value
    try require(success, "Test connection must be established")
  }

  @MainActor
  private static func freshnessRequiresActiveSessionAndRecentSuccess() async throws {
    let harness = Harness(); defer { harness.close() }
    try require(!harness.connection.hasFreshStatus, "An empty launch must not imply live status")
    try await establish(harness)
    let checkedAt = harness.connection.lastSuccessfulRefreshAt
    try require(harness.connection.hasFreshStatus && checkedAt == harness.clock.date,
                "A successful foreground check must record its time")
    harness.clock.date.addTimeInterval(15)
    try require(!harness.connection.hasFreshStatus, "A stalled check must expire instead of showing endless live progress")
    harness.connection.setSceneActive(false)
    let response = harness.nextResponse()
    await harness.connection.refresh()
    try require(!response.started && !harness.connection.hasFreshStatus,
                "Background refresh must not create a live foreground claim")
    harness.connection.setSceneActive(true)
    try require(!harness.connection.hasFreshStatus && harness.connection.lastSuccessfulRefreshAt == checkedAt,
                "Returning to the app must preserve last-check evidence but require a new check")
    let refresh = Task { await harness.connection.refresh() }
    try await wait(for: response.started)
    try response.reply(project: "Computer")
    await refresh.value
    try require(harness.connection.hasFreshStatus && harness.connection.lastSuccessfulRefreshAt == harness.clock.date,
                "The first foreground refresh must restore live status")
  }

  @MainActor
  private static func failedRefreshKeepsLastCheckButInvalidatesStatus() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness)
    let checkedAt = harness.connection.lastSuccessfulRefreshAt
    let response = harness.nextResponse()
    let refresh = Task { await harness.connection.refresh() }
    try await wait(for: response.started)
    try response.reply(project: "", status: 503)
    await refresh.value
    try require(!harness.connection.hasFreshStatus && !harness.connection.connected,
                "A failed network check must invalidate live status")
    try require(harness.connection.lastSuccessfulRefreshAt == checkedAt,
                "A failure must not replace the last successful check with its failure time")
  }

  @MainActor
  private static func oldForegroundResponseCannotReviveStatus() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness)
    let old = harness.nextResponse()
    let oldRequest = Task { await harness.connection.refresh() }
    try await wait(for: old.started)
    harness.connection.setSceneActive(false)
    harness.connection.setSceneActive(true)
    let next = harness.nextResponse()
    let newRequest = Task { await harness.connection.refresh() }
    try await wait(for: next.started)
    try next.reply(project: "Fresh session")
    await newRequest.value
    try old.reply(project: "Old session")
    await oldRequest.value
    try require(harness.connection.hasFreshStatus && harness.connection.project == "Fresh session",
                "An old session reply cannot overwrite a new session's verified task state")
  }

  @MainActor
  private static func refreshCoalescesConcurrentRequests() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness)
    let response = harness.nextResponse()
    let first = Task { await harness.connection.refresh() }
    try await wait(for: response.started)
    await harness.connection.refresh()
    try require(response.startCount == 1, "Home and task views must not start duplicate list requests")
    try response.reply(project: "Computer")
    await first.value
  }

  private static var runningTask: [String: Any] {
    ["id": "12345678-1234-1234-1234-123456789abc", "prompt": "A saved request",
     "character": ["id": "doboo", "version": 1, "name": "Doboo"], "project": "Computer",
     "status": "running", "sequence": 2, "result": "", "activity": "Old activity", "approvals": [], "commands": []]
  }

  @MainActor
  private static func savedRunningTaskIsNeverLiveOnRelaunch() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness, tasks: [runningTask])
    let restored = harness.restoreCache()
    try require(restored.tasks.first?.status == "running" && restored.project == "Computer",
                "The new cache must preserve the task and its execution context")
    try require(restored.lastSuccessfulRefreshAt == harness.connection.lastSuccessfulRefreshAt,
                "The timestamp must survive process restart with the same task snapshot")
    restored.setSceneActive(true)
    try require(!restored.hasFreshStatus && !restored.connected,
                "Even a very recent saved running task is a record, not live execution evidence")
  }

  @MainActor
  private static func backgroundMutationCannotReviveStatus() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness, tasks: [runningTask])
    let response = harness.nextResponse()
    let task = harness.connection.tasks[0]
    let cancel = Task { await harness.connection.cancel(task) }
    try await wait(for: response.started)
    harness.connection.setSceneActive(false)
    var stoppedTask = runningTask; stoppedTask["status"] = "interrupted"
    try response.reply(body: stoppedTask)
    await cancel.value
    try require(response.startCount == 1 && !harness.connection.hasFreshStatus,
                "A late cancel response must not start a new live refresh in the background")
    harness.connection.setSceneActive(true)
    try require(!harness.connection.hasFreshStatus, "A late mutation cannot pre-verify the next foreground session")
  }

  private static var approvalTask: [String: Any] {
    var task = runningTask
    task["status"] = "needsApproval"
    task["approvals"] = [["id": "approval-1", "description": "Change the requested file"]]
    return task
  }

  private static func decodedTask(_ fields: [String: Any]) throws -> CompanionTask {
    try JSONDecoder().decode(CompanionTask.self, from: JSONSerialization.data(withJSONObject: fields))
  }

  @MainActor
  private static func staleActionsSendNoRequests() async throws {
    for reason in ["expired", "failed", "background"] {
      let harness = Harness(); defer { harness.close() }
      try await establish(harness, tasks: [approvalTask])
      let shownTask = harness.connection.tasks[0]
      if reason == "expired" { harness.clock.date.addTimeInterval(15) }
      if reason == "background" { harness.connection.setSceneActive(false) }
      if reason == "failed" {
        let failure = harness.nextResponse()
        let refresh = Task { await harness.connection.refresh() }
        try await wait(for: failure.started)
        try failure.reply(project: "", status: 503)
        await refresh.value
      }
      let unexpected = harness.nextResponse()
      await harness.connection.cancel(shownTask)
      await harness.connection.approve(shownTask, approval: shownTask.approvals[0], accept: true)
      try require(!unexpected.started && harness.connection.error != nil,
                  "A \(reason) confirmation or approval must show guidance without sending a mutation")
    }
  }

  @MainActor
  private static func changedActionTargetsSendNoRequests() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness, tasks: [approvalTask])
    let shownTask = harness.connection.tasks[0]
    let unexpected = harness.nextResponse()
    var changed = approvalTask
    changed["sequence"] = 3
    changed["approvals"] = [["id": "approval-1", "description": "A different operation"]]
    harness.connection.tasks = [try decodedTask(changed)]
    await harness.connection.approve(shownTask, approval: shownTask.approvals[0], accept: true)
    changed["approvals"] = []
    harness.connection.tasks = [try decodedTask(changed)]
    await harness.connection.approve(shownTask, approval: shownTask.approvals[0], accept: true)
    changed["sequence"] = 1
    harness.connection.tasks = [try decodedTask(changed)]
    await harness.connection.cancel(shownTask)
    changed["sequence"] = 3; changed["status"] = "completed"
    harness.connection.tasks = [try decodedTask(changed)]
    await harness.connection.cancel(shownTask)
    harness.connection.tasks = []
    await harness.connection.cancel(shownTask)
    try require(!unexpected.started,
                "Changed approvals, older sequences, finished tasks, and missing task IDs must reject stale actions")
  }

  @MainActor
  private static func currentApprovalStillWorks() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness, tasks: [approvalTask])
    let shownTask = harness.connection.tasks[0]
    var current = approvalTask; current["sequence"] = 3
    harness.connection.tasks = [try decodedTask(current)]
    let response = harness.nextResponse()
    let approve = Task { await harness.connection.approve(shownTask, approval: shownTask.approvals[0], accept: true) }
    try await wait(for: response.started)
    try response.reply(body: runningTask)
    try await wait(for: response.startCount == 2)
    try response.reply(project: "Computer")
    await approve.value
    try require(harness.connection.error == nil && harness.connection.hasFreshStatus,
                "A still-current approval must remain actionable after unrelated sequence progress")
  }

  @MainActor
  private static func receiptFailureDoesNotInvalidateStatus() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness, tasks: [runningTask])
    for _ in 0..<2 {
      harness.clock.date.addTimeInterval(4)
      let response = harness.nextResponse()
      let refresh = Task { await harness.connection.refresh() }
      try await wait(for: response.started)
      try response.reply(project: "Computer", tasks: [runningTask])
      try await wait(for: response.startCount == 2)
      try response.reply(body: ["error": "The server sequence advanced before receipt"], status: 400)
      await refresh.value
      try require(harness.connection.hasFreshStatus && harness.connection.error == nil
                    && harness.connection.lastSuccessfulRefreshAt == harness.clock.date,
                  "Receipt rejection must retain the successful GET's freshness and retry receipt on the next poll")
    }
  }
  private static func context(revision: Int = 1, generation: Int = 1, memory: String = "Explicit preference") -> CompanionContext {
    .init(characterId: "doboo", profile: CompanionProfile(.builtin), profileDigest: "profile-digest",
      revision: revision, memory: memory, generation: generation, updatedAt: "2026-10-19T00:00:00Z")
  }

  private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
  }

  private static func continuityList(serverId: String = "server-a", context: CompanionContext = context(),
                                     tasks: [[String: Any]] = []) throws -> [String: Any] {
    ["project": "Computer", "serverId": serverId, "companions": [try object(context)], "tasks": tasks]
  }

  @MainActor
  private static func establishContinuity(_ harness: Harness, context: CompanionContext = context(),
                                          tasks: [[String: Any]] = []) async throws {
    let (_, response) = harness.prepare()
    let attempt = Task { await harness.connection.connect() }
    try await wait(for: response.started)
    try response.reply(body: continuityList(context: context, tasks: tasks))
    let success = await attempt.value
    try require(success && harness.connection.supportsContinuity, "Continuity server must be verified")
  }

  @MainActor
  private static func serverIdentityChangeCannotReplaceContext() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establishContinuity(harness)
    let response = harness.nextResponse()
    let refresh = Task { await harness.connection.refresh() }
    try await wait(for: response.started)
    try response.reply(body: continuityList(serverId: "replacement-server", context: context(memory: "Other user's note")))
    await refresh.value
    try require(!harness.connection.hasFreshStatus && harness.connection.serverId == "server-a"
      && harness.connection.companions.first?.memory == "Explicit preference",
      "A different store behind the same endpoint cannot replace or revive the remembered context")
  }

  @MainActor
  private static func staleMemoryEditDoesNotOverwriteNewRevision() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establishContinuity(harness, context: context(revision: 2, memory: "New remote memory"))
    let response = harness.nextResponse()
    let saved = await harness.connection.saveCompanion(character: .builtin, memory: "Draft from older editor", expectedRevision: 1)
    try require(!saved && !response.started && harness.connection.companions.first?.memory == "New remote memory",
      "An editor must submit the revision from when it opened, never silently overwrite newer device memory")
    let wrongServer = await harness.connection.saveCompanion(character: .builtin, memory: "Draft from another server",
      expectedRevision: 2, expectedServerId: "old-computer")
    try require(!wrongServer && !response.started,
      "A same-revision draft from a different server must not overwrite this computer's memory")
  }

  @MainActor
  private static func missingProfileCannotStartLegacyTask() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establish(harness)
    let response = harness.nextResponse()
    harness.connection.prompt = "Do this as my character"
    let saved = await harness.connection.submit(character: .builtin)
    try require(!saved && !response.started && !harness.connection.pendingRetry,
      "An old server or unapplied character cannot silently fall back to metadata-only execution")
  }

  @MainActor
  private static func continuityGenerationInvalidatesOldFollowup() async throws {
    let harness = Harness(); defer { harness.close() }
    var task = runningTask
    task["status"] = "completed"
    task["continuity"] = ["serverId": "server-a", "conversationId": "conversation", "companionRevision": 1,
      "generation": 1, "profileDigest": "profile-digest", "memoryApplied": true,
      "historyCount": 0, "historyTruncated": false]
    try await establishContinuity(harness, context: context(revision: 2, generation: 2, memory: ""), tasks: [task])
    let shown = harness.connection.tasks[0]
    try require(!harness.connection.canContinue(task: shown),
      "Clearing or editing memory must block replay through a task from the old generation")
    let response = harness.nextResponse()
    harness.connection.prompt = "Continue the old result"
    let accepted = await harness.connection.submit(companion: harness.connection.companions[0], parentTask: shown)
    try require(!accepted && !response.started, "Old context must require an explicit new conversation")
  }

  @MainActor
  private static func watchConnectionRequiresVerifiedPersistence() async throws {
    let harness = Harness(); defer { harness.close() }
    let (url, response) = harness.prepare()
    let envelope = WatchConnectionEnvelope(requestId: UUID().uuidString, url: url,
      token: harness.connection.connectionToken, serverId: "server-a")
    let failed = Task { try? await harness.connection.receiveWatchConnection(envelope) }
    try await wait(for: response.started)
    try response.reply(body: continuityList(serverId: "other-server"))
    let rejection = await failed.value
    try require(rejection == nil && harness.credentials.urls.isEmpty && !harness.connection.hasConnection,
      "A message transport success cannot save an unverified server or emit a successful receipt")
    let next = harness.nextResponse()
    let success = Task { try await harness.connection.receiveWatchConnection(envelope) }
    try await wait(for: next.started)
    try next.reply(body: continuityList())
    let receipt = try await success.value
    try require(receipt.confirms(envelope) && harness.credentials.urls == [url]
      && harness.connection.hasFreshStatus && harness.connection.companions.first?.memory == "Explicit preference",
      "A receipt must follow server verification, Keychain persistence, and actual context receipt")
  }

  @MainActor
  private static func delayedWatchVerificationCannotOverrideNewSession() async throws {
    let harness = Harness(); defer { harness.close() }
    let (url, response) = harness.prepare()
    let envelope = WatchConnectionEnvelope(requestId: UUID().uuidString, url: url,
      token: harness.connection.connectionToken, serverId: "server-a")
    let attempt = Task { try? await harness.connection.receiveWatchConnection(envelope) }
    try await wait(for: response.started)
    harness.connection.setSceneActive(false)
    harness.connection.setSceneActive(true)
    try response.reply(body: continuityList())
    let result = await attempt.value
    try require(result == nil && harness.credentials.urls.isEmpty,
      "An old pairing reply must not apply credentials after its receiving foreground session ends")
  }

  @MainActor
  private static func senderRejectsMismatchedWatchReceipt() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establishContinuity(harness)
    harness.connection.watchConnectionSender = { envelope in
      WatchConnectionReceipt(requestId: envelope.requestId, serverId: "other-server", url: envelope.url, saved: true)
    }
    await harness.connection.sendConnectionToWatch()
    try require(harness.connection.watchConnectionStatus == String(localized: "continuity.watchUnverified"),
      "The phone must not show shared connection success for a receipt from a different computer")
  }

  @MainActor
  private static func memorySaveKeepsItsOriginalComputer() async throws {
    let harness = Harness(); defer { harness.close() }
    try await establishContinuity(harness)
    let original = harness.connection.verifiedAddress
    let response = harness.nextResponse()
    let save = Task { await harness.connection.saveCompanion(character: .builtin, memory: "Updated memory", expectedRevision: 1) }
    try await wait(for: response.started)
    let (_, unexpected) = harness.prepare()
    let changed = await harness.connection.connect()
    try require(!changed && !unexpected.started && harness.connection.verifiedAddress == original,
      "A memory save must not switch destination while its original request is being verified")
    let updated = context(revision: 2, generation: 2, memory: "Updated memory")
    try response.reply(body: object(updated))
    try await wait(for: response.startCount == 2)
    try response.reply(body: continuityList(context: updated))
    let success = await save.value
    try require(success && harness.connection.companions.first == updated && harness.connection.hasFreshStatus && harness.connection.error == nil,
      "Rejecting a connection change must not invalidate the in-flight memory save")
  }

  @MainActor
  private static func watchPersistenceFailureEmitsNoReceipt() async throws {
    let harness = Harness(persistFails: true); defer { harness.close() }
    let (url, response) = harness.prepare()
    let envelope = WatchConnectionEnvelope(requestId: UUID().uuidString, url: url,
      token: harness.connection.connectionToken, serverId: "server-a")
    let attempt = Task { try? await harness.connection.receiveWatchConnection(envelope) }
    try await wait(for: response.started)
    try response.reply(body: continuityList())
    let receipt = await attempt.value
    try require(receipt == nil && !harness.connection.hasConnection && harness.credentials.urls.isEmpty,
      "Verified HTTP alone cannot emit a paired-connection receipt when credential persistence failed")
  }

  @MainActor
  private static func profileCharacterizationSurvivesNativeTransportAndCache() async throws {
    let old = CompanionProfile(.builtin)
    let legacyBytes = try JSONEncoder().encode(old)
    let legacyFields = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
    try require(legacyFields["characterization"] == nil,
      "Legacy profiles must omit absent characterization instead of introducing null or empty fields")
    let restoredLegacy = try JSONDecoder().decode(CompanionProfile.self, from: legacyBytes)
    try require(restoredLegacy == old && restoredLegacy.characterization == nil,
      "Existing stored profiles without characterization must still decode unchanged")
    var pack = CharacterPack.builtin
    pack.identity.voice = String(repeating: "말", count: 4000)
    pack.characterization = .init(appearanceDescription: "A soft peach silhouette", perspective: "Find the smallest useful next step",
      principles: ["Preserve user changes", "Explain verified results"],
      workStyle: .init(initiative: "Proceed on reversible work", updates: "Share meaningful changes", recovery: "Keep the last useful result"),
      examples: [.init(situation: "A test fails", response: "Isolate the failing case first")],
      origin: .init(schema: "troupe.character.v1", id: "peach-helper", version: "1.2.3",
        personalityId: "careful-helper", personalityVersion: "2.0.0", personalityName: "Careful helper"))
    _ = try pack.validated()
    let rich = CompanionProfile(pack)
    try require(rich.characterization == pack.characterization && rich.identity.voice == pack.identity.voice,
      "Native execution profiles must preserve complete character settings and the expanded voice")
    let richBytes = try JSONEncoder().encode(rich)
    let decoded = try JSONDecoder().decode(CompanionProfile.self, from: richBytes)
    try require(decoded == rich, "Encoding a profile for the bridge must retain every characterization field")
    let context = CompanionContext(characterId: pack.id, profile: rich, profileDigest: "rich-digest", revision: 1,
      memory: "Explicit note", generation: 1, updatedAt: "2026-10-21T00:00:00Z")
    let harness = Harness(); defer { harness.close() }
    try await establishContinuity(harness, context: context)
    try require(harness.connection.companion(for: pack)?.profile == rich,
      "The authenticated task list must restore full characterization on another device")
    let cached = harness.restoreCache()
    try require(cached.companion(for: pack)?.profile == rich && !cached.hasFreshStatus,
      "The native cache must retain character settings without claiming a live connection")
  }

}
