import Foundation
import Observation
import Security
#if os(watchOS)
import WatchKit
#endif

struct ComputerConnection: Codable {
  var url: String
  var token: String
  var serverId: String? = nil
}

@MainActor @Observable
final class TaskConnection {
  var tasks: [CompanionTask] = []
  private(set) var companions: [CompanionContext] = []
  private(set) var workCastSupported = false
  private(set) var serverId: String?
  private(set) var savingCompanion = false
  private(set) var story: StoryState?
  private(set) var storyError: String?
  private(set) var loadingStory = false
  private(set) var savingStory = false
  private(set) var pendingStoryTurn: PendingStoryTurn?
  private var pendingStoryUnreadable = false
  private(set) var isSendingWatchConnection = false
  private(set) var watchConnectionStatus: String?
  @ObservationIgnored var watchConnectionSender: (@MainActor (WatchConnectionEnvelope) async throws -> WatchConnectionReceipt)?
  var project = ""
  var error: String? { operationError ?? refreshError }
  private var operationError: String?
  private var refreshError: String?
  var connected = false
  private(set) var lastSuccessfulRefreshAt: Date?
  private var liveStatusValid = false
  private var isSceneActive = false
  private var statusGeneration = UUID()
  private var refreshID: UUID?
  var submitting = false
  var address = ""
  var connectionToken = ""
  var prompt = ""
  private var connection: ComputerConnection?
  private var cachedEndpoint: TaskEndpointIdentity?
  private var pending: PendingTaskSubmission?
  private var pendingRecordUnreadable = false
  private var connectionAttempt = UUID()
  private var acknowledged: [String: Int] = [:]
  private static let credentialAccount = "doboo.computer.connection"
  private let storage: URL
  @ObservationIgnored private let session: URLSession
  @ObservationIgnored private let persistCredential: @MainActor (ComputerConnection) throws -> Void
  @ObservationIgnored private let now: @MainActor () -> Date
  private struct ListResponse: Decodable {
    let project: String
    let tasks: [CompanionTask]
    let serverId: String?
    let companions: [CompanionContext]?
    let workCastSupported: Bool?
  }
  private struct TaskCache: Codable {
    let project: String
    let tasks: [CompanionTask]
    let checkedAt: Date
    var endpoint: TaskEndpointIdentity? = nil
    var serverId: String? = nil
    var companions: [CompanionContext]? = nil
    var workCastSupported: Bool? = nil
  }
  private struct Failure: Decodable { let error: String; let submissionRejected: Bool? }
  private struct RequestFailure: LocalizedError {
    let status: Int
    let message: String
    let submissionRejected: Bool?
    var errorDescription: String? { message }
    var isDefinitiveRejection: Bool { PendingTaskSubmission.isDefinitiveRejection(status: status, submissionRejected: submissionRejected) }
  }

  init() {
    session = .shared
    persistCredential = Self.saveCredential
    now = Date.init
    storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DobooTasks")
    try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    loadTaskCache()
    loadPending()
    loadPendingStory()
    var result: CFTypeRef?
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.credentialAccount,
      kSecAttrAccount as String: "computer", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
      connection = try? JSONDecoder().decode(ComputerConnection.self, from: data)
    }
    #if DEBUG && targetEnvironment(simulator)
    // Simulator bootstrap supplies only connection details, never a task or a success result.
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("doboo-connection.json")
    if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(ComputerConnection.self, from: data) {
      // SwiftUI may create more than one initial State value. Keep the simulator-only
      // bootstrap available when unsigned simulator builds cannot use Keychain.
      connection = value; try? persistCredential(value)
    }
    #endif
    if let cachedEndpoint, cachedEndpoint != endpoint {
      tasks = []; companions = []; project = ""; serverId = nil; lastSuccessfulRefreshAt = nil
      workCastSupported = false
    }
    address = connection?.url ?? ""
    connectionToken = connection?.token ?? ""
    prompt = pending?.submission.prompt ?? ""
  }

  // Host-only regression tests provide isolated transport and credential storage.
  init(storage: URL, session: URLSession,
       persistCredential: @escaping @MainActor (ComputerConnection) throws -> Void,
       now: @escaping @MainActor () -> Date = Date.init) {
    self.storage = storage
    self.session = session
    self.persistCredential = persistCredential
    self.now = now
    loadTaskCache()
    loadPending()
    loadPendingStory()
  }

  var hasConnection: Bool { connection != nil }
  var verifiedAddress: String? { connection?.url }
  var supportsContinuity: Bool { serverId != nil && connection?.serverId == serverId }
  var canSendWatchConnection: Bool {
    hasFreshStatus && serverId != nil && !isSendingWatchConnection && watchConnectionSender != nil
      && URL(string: connection?.url ?? "")?.scheme == "https"
  }
  func companion(for character: CharacterPack) -> CompanionContext? {
    companions.first { $0.characterId == character.id }
  }
  func canEditCompanion(characterId: String) -> Bool {
    hasFreshStatus && supportsContinuity && !savingCompanion && !savingStory && !hasPendingStory && !submitting && !pendingRetry
      && !tasks.contains { $0.involvedCharacterIds.contains(characterId) && !$0.finished }
  }
  func canContinue(task: CompanionTask) -> Bool {
    guard canSubmit, let current = tasks.first(where: { $0.id == task.id }), current == task,
      current.status == "completed", let continuity = current.continuity,
      continuity.serverId == serverId,
      let context = companions.first(where: { $0.characterId == current.character.id }),
      context.profileDigest == continuity.profileDigest, context.generation == continuity.generation,
      current.work == nil || workCastSupported, current.hasCurrentWorkCast(in: companions) else { return false }
    // Only the latest turn in this conversation is a valid continuation point.
    return !tasks.contains { other in
      other.id != current.id && other.continuity?.parentTaskId == current.id
        && !["failed", "interrupted"].contains(other.status)
    }
  }
  var hasFreshStatus: Bool {
    guard liveStatusValid, let lastSuccessfulRefreshAt else { return false }
    let age = now().timeIntervalSince(lastSuccessfulRefreshAt)
    return age >= 0 && age < 15
  }
  var canSubmit: Bool { hasFreshStatus && connected && !submitting && !savingCompanion && !savingStory && !hasPendingStory && !pendingRetry && !tasks.contains(where: { !$0.finished }) }
  var pendingRetry: Bool { pending != nil || pendingRecordUnreadable }
  private var endpoint: TaskEndpointIdentity? { connection.flatMap { TaskEndpointIdentity(url: $0.url, token: $0.token) } }

  func setSceneActive(_ active: Bool) {
    guard isSceneActive != active else { return }
    isSceneActive = active
    invalidateLiveStatus()
  }

  /// A cached task remains useful, but cannot claim to be current after leaving
  /// the app. An older in-flight response must not revive the previous session.
  func invalidateLiveStatus() {
    statusGeneration = UUID()
    refreshID = nil
    liveStatusValid = false
    connected = false
  }

  private func recordSuccessfulRefresh() {
    lastSuccessfulRefreshAt = now()
    liveStatusValid = isSceneActive
    connected = isSceneActive
  }

  private func loadPending() {
    let file = storage.appendingPathComponent("pending.json")
    if FileManager.default.fileExists(atPath: file.path) {
      do { pending = try JSONDecoder().decode(PendingTaskSubmission.self, from: Data(contentsOf: file)) }
      catch { pendingRecordUnreadable = true }
    }
  }

  private func loadTaskCache() {
    if let data = try? Data(contentsOf: storage.appendingPathComponent("task-cache.json")),
      let cache = try? JSONDecoder().decode(TaskCache.self, from: data) {
      tasks = cache.tasks; project = cache.project; lastSuccessfulRefreshAt = cache.checkedAt
      serverId = cache.serverId; companions = cache.companions ?? []; cachedEndpoint = cache.endpoint
      workCastSupported = cache.workCastSupported ?? false
    } else if let data = try? Data(contentsOf: storage.appendingPathComponent("tasks.json")) {
      tasks = (try? JSONDecoder().decode([CompanionTask].self, from: data)) ?? []
    }
  }

  private func saveTaskCache() throws {
    guard let checkedAt = lastSuccessfulRefreshAt else { return }
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    try JSONEncoder().encode(TaskCache(project: project, tasks: tasks, checkedAt: checkedAt, endpoint: endpoint, serverId: serverId, companions: companions, workCastSupported: workCastSupported))
      .write(to: storage.appendingPathComponent("task-cache.json"), options: .atomic)
  }

  private static func saveCredential(_ value: ComputerConnection) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: credentialAccount, kSecAttrAccount as String: "computer"]
    let data = try JSONEncoder().encode(value)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var entry = query; entry[kSecValueData as String] = data
      entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotCreateFile) }
    } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
  }

  @discardableResult func connect() async -> Bool {
    guard !Task.isCancelled, isSceneActive else { return false }
    guard !submitting, !savingCompanion, !savingStory, !isSendingWatchConnection else {
      operationError = String(localized: "continuity.connectionBusy"); return false
    }
    operationError = nil
    invalidateLiveStatus()
    let attempt = UUID(); connectionAttempt = attempt
    let generation = statusGeneration
    let requestedAddress = address, requestedToken = connectionToken
    guard !submitting else { operationError = "요청 접수를 확인한 뒤 연결을 변경해 주세요."; return false }
    guard let candidate = TaskEndpointIdentity(url: address, token: connectionToken) else {
      operationError = "HTTPS 주소와 연결 키를 확인해 주세요. 시뮬레이터에서는 localhost도 허용합니다."; return false
    }
    guard permitsConnection(to: candidate) else { operationError = "접수를 확인하지 못한 요청이 있습니다. 원래 컴퓨터에서 확인한 뒤 연결을 변경해 주세요."; return false }
    var value = ComputerConnection(url: candidate.url, token: connectionToken)
    do {
      let list: ListResponse = try await request("/v1/tasks", using: value)
      guard !Task.isCancelled, connectionAttempt == attempt, statusGeneration == generation,
        address == requestedAddress, connectionToken == requestedToken else { return false }
      // A submission can start while this connection check is awaiting its reply.
      guard !submitting, !savingCompanion, !savingStory, !isSendingWatchConnection, permitsConnection(to: candidate) else {
        operationError = "접수를 확인하지 못한 요청이 있습니다. 원래 컴퓨터에서 확인한 뒤 연결을 변경해 주세요."; return false
      }
      if let expected = pendingStoryTurn?.serverId, expected != list.serverId { throw URLError(.userAuthenticationRequired) }
      if let expected = pending?.submission.continuity?.serverId, expected != list.serverId {
        throw URLError(.userAuthenticationRequired)
      }
      value.serverId = list.serverId
      try persistCredential(value)
      if endpoint != candidate || serverId != list.serverId { story = nil; storyError = nil }
      connection = value
      serverId = list.serverId; companions = list.companions ?? []; workCastSupported = list.workCastSupported ?? false
      tasks = list.tasks; project = list.project; refreshError = nil; acknowledged = [:]
      recordSuccessfulRefresh()
      try saveTaskCache()
      try reconcileListedTask()
      address = value.url
      operationError = nil
      return true
    } catch {
      guard !Task.isCancelled, connectionAttempt == attempt, statusGeneration == generation,
        address == requestedAddress, connectionToken == requestedToken else { return false }
      liveStatusValid = false; connected = false
      operationError = error.localizedDescription; return false
    }
  }

  private func permitsConnection(to candidate: TaskEndpointIdentity) -> Bool {
    guard !pendingRecordUnreadable, !pendingStoryUnreadable else { return false }
    if let pendingStoryTurn, pendingStoryTurn.origin != candidate { return false }
    return pending?.permitsConnection(to: candidate, current: endpoint) ?? true
  }

  func sendConnectionToWatch() async {
    guard canSendWatchConnection, let connection, let serverId, let sender = watchConnectionSender else { return }
    let envelope = WatchConnectionEnvelope(requestId: UUID().uuidString, url: connection.url,
      token: connection.token, serverId: serverId)
    guard envelope.isValid else { return }
    isSendingWatchConnection = true
    watchConnectionStatus = String(localized: "continuity.watchVerifying")
    defer { isSendingWatchConnection = false }
    do {
      let receipt = try await sender(envelope)
      guard receipt.confirms(envelope), self.connection?.url == envelope.url,
        self.connection?.token == envelope.token, self.serverId == envelope.serverId else {
        throw URLError(.badServerResponse)
      }
      watchConnectionStatus = String(localized: "continuity.watchSaved")
    } catch { watchConnectionStatus = String(localized: "continuity.watchUnverified") }
  }

  func receiveWatchConnection(_ envelope: WatchConnectionEnvelope) async throws -> WatchConnectionReceipt {
    guard envelope.isValid, isSceneActive, !submitting, !pendingRetry, !savingCompanion, !savingStory, !hasPendingStory else {
      throw URLError(.userAuthenticationRequired)
    }
    let origin = endpoint, generation = statusGeneration
    let candidate = ComputerConnection(url: envelope.url, token: envelope.token, serverId: envelope.serverId)
    let list: ListResponse = try await request("/v1/tasks", using: candidate)
    guard !Task.isCancelled, isSceneActive, statusGeneration == generation, endpoint == origin,
      !submitting, !pendingRetry, !savingCompanion, !savingStory, !hasPendingStory, list.serverId == envelope.serverId else {
      throw URLError(.userAuthenticationRequired)
    }
    try persistCredential(candidate)
    invalidateLiveStatus()
    story = nil; storyError = nil
    connection = candidate; address = candidate.url; connectionToken = candidate.token
    serverId = list.serverId; companions = list.companions ?? []; workCastSupported = list.workCastSupported ?? false; tasks = list.tasks; project = list.project
    acknowledged = [:]; refreshError = nil; operationError = nil
    recordSuccessfulRefresh(); try saveTaskCache()
    return WatchConnectionReceipt(requestId: envelope.requestId, serverId: envelope.serverId,
      url: envelope.url, saved: true)
  }

  private func request<T: Decodable>(_ path: String, body: Data? = nil, using explicitConnection: ComputerConnection? = nil) async throws -> T {
    guard let connection = explicitConnection ?? connection, let url = URL(string: connection.url + path) else { throw URLError(.userAuthenticationRequired) }
    #if (os(iOS) || os(watchOS)) && !targetEnvironment(simulator)
    guard url.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
    #endif
    var request = URLRequest(url: url); request.timeoutInterval = 12
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard http.statusCode == 200 else {
      let failure = try? JSONDecoder().decode(Failure.self, from: data)
      throw RequestFailure(status: http.statusCode, message: failure?.error ?? "컴퓨터 응답을 확인하지 못했습니다.", submissionRejected: failure?.submissionRejected)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  func refresh() async {
    guard isSceneActive, refreshID == nil, let current = connection, let origin = endpoint else { return }
    let id = UUID(), generation = statusGeneration
    refreshID = id
    defer { if refreshID == id { refreshID = nil } }
    do {
      let list: ListResponse = try await request("/v1/tasks", using: current)
      guard !Task.isCancelled, statusGeneration == generation, endpoint == origin else { return }
      guard list.serverId == current.serverId || current.serverId == nil else {
        throw URLError(.userAuthenticationRequired)
      }
      if current.serverId == nil, let verified = list.serverId {
        var pinned = current; pinned.serverId = verified
        try persistCredential(pinned); connection = pinned
      }
      #if os(watchOS)
      if let latest = list.tasks.first, let old = tasks.first(where: { $0.id == latest.id }), latest.status != old.status {
        if latest.status == "completed" { WKInterfaceDevice.current().play(.success) }
        if latest.status == "needsApproval" || latest.status == "failed" { WKInterfaceDevice.current().play(.notification) }
      }
      #endif
      serverId = list.serverId; companions = list.companions ?? []; workCastSupported = list.workCastSupported ?? false
      tasks = list.tasks; project = list.project; refreshError = nil
      recordSuccessfulRefresh()
      try saveTaskCache()
      try reconcileListedTask()
      for task in tasks.prefix(1) where acknowledged[task.id] != task.sequence {
        #if os(watchOS)
        let surface = "watch"
        #else
        let surface = "phone"
        #endif
        let body = try JSONSerialization.data(withJSONObject: ["surface": surface, "sequence": task.sequence])
        do {
          let _: [String: Bool] = try await request("/v1/tasks/\(task.id)/receipt", body: body, using: current)
          guard !Task.isCancelled, statusGeneration == generation, endpoint == origin else { return }
          acknowledged[task.id] = task.sequence
        } catch {
          // Output can advance the server's sequence between GET and receipt.
          // A failed receipt is retried next poll; it cannot erase the successful
          // status check above or claim that its delivery was acknowledged.
          guard !Task.isCancelled, statusGeneration == generation, endpoint == origin else { return }
        }
      }
    } catch {
      guard !Task.isCancelled, statusGeneration == generation, endpoint == origin else { return }
      refreshError = error.localizedDescription; connected = false; liveStatusValid = false
    }
  }

  @discardableResult
  func submit(character: CharacterPack, castIds: Set<String> = []) async -> Bool {
    if pendingRetry { return await submitPrepared(nil) }
    guard let context = companion(for: character), context.profile == CompanionProfile(character) else {
      operationError = String(localized: "continuity.applyFirst")
      return false
    }
    let requestedIds = castIds.union([character.id])
    guard requestedIds.count <= 6 else {
      operationError = TaskSubmission.ValidationError.invalidWorkCast.localizedDescription; return false
    }
    let cast = companions.filter { requestedIds.contains($0.characterId) }
    guard cast.count == requestedIds.count else {
      operationError = String(localized: "continuity.applyFirst"); return false
    }
    return await submit(companion: context, cast: cast)
  }

  @discardableResult
  func submit(companion: CompanionContext, parentTask: CompanionTask? = nil, cast: [CompanionContext]? = nil) async -> Bool {
    if pendingRetry { return await submitPrepared(nil) }
    guard canSubmit, let serverId, companions.contains(companion),
      parentTask == nil || (parentTask?.character.id == companion.characterId && canContinue(task: parentTask!)) else {
      operationError = String(localized: "continuity.refreshBeforeSubmit")
      return false
    }
    let selectedCast: [CompanionContext]
    if let inherited = parentTask?.work {
      selectedCast = inherited.cast.compactMap { member in companions.first { $0.characterId == member.character.id } }
      guard selectedCast.count == inherited.cast.count else { return false }
    } else {
      selectedCast = cast ?? [companion]
    }
    guard selectedCast.contains(companion), selectedCast.allSatisfy({ companions.contains($0) }),
      Set(selectedCast.map(\.characterId)).count == selectedCast.count else {
      operationError = String(localized: "continuity.refreshBeforeSubmit"); return false
    }
    // The server freezes cast order as part of the parent context. Preserve
    // it for tasks started by another surface as well as this client.
    let orderedCast = parentTask?.work == nil ? selectedCast.sorted { $0.characterId < $1.characterId } : selectedCast
    let work: WorkRequest? = orderedCast.count > 1
      ? WorkRequest(cast: orderedCast.map {
        .init(character: $0.profile.character, companionRevision: $0.revision)
      }) : nil
    guard work.map({ workCastSupported && $0.isValid(host: companion.profile.character) && $0.matches(companions: companions) }) ?? true else {
      operationError = "이 컴퓨터에서 작업 캐스트를 지원하는지 확인하고 캐릭터 2~6명을 선택해 주세요."; return false
    }
    let submission = TaskSubmission(id: UUID().uuidString.lowercased(), prompt: prompt,
      character: companion.profile.character,
      continuity: .init(serverId: serverId, companionRevision: companion.revision, parentTaskId: parentTask?.id), work: work)
    return await submitPrepared(submission)
  }

  @discardableResult
  func saveCompanion(character: CharacterPack, memory: String, expectedRevision: Int, resetHistory: Bool = false, expectedServerId: String? = nil) async -> Bool {
    operationError = nil
    guard canEditCompanion(characterId: character.id), let serverId, let origin = endpoint,
      expectedServerId == nil || expectedServerId == serverId,
      (companion(for: character)?.revision ?? 0) == expectedRevision else {
      operationError = String(localized: "continuity.memoryChanged")
      return false
    }
    guard memory.utf16.count <= 4000 else {
      operationError = String(localized: "continuity.memoryTooLong")
      return false
    }
    struct Update: Encodable {
      let serverId: String; let expectedRevision: Int; let profile: CompanionProfile
      let memory: String; let resetHistory: Bool
    }
    savingCompanion = true
    defer { savingCompanion = false }
    let generation = statusGeneration
    do {
      let body = try JSONEncoder().encode(Update(serverId: serverId, expectedRevision: expectedRevision,
        profile: CompanionProfile(character), memory: memory, resetHistory: resetHistory))
      let saved: CompanionContext = try await request("/v1/companions/\(character.id)", body: body)
      guard !Task.isCancelled, isSceneActive, statusGeneration == generation, endpoint == origin,
        self.serverId == serverId, saved.characterId == character.id,
        saved.profile == CompanionProfile(character), saved.memory == memory, saved.revision > expectedRevision else { return false }
      companions.removeAll { $0.characterId == saved.characterId }; companions.append(saved)
      operationError = nil
      invalidateLiveStatus(); await refresh()
      return true
    } catch {
      guard statusGeneration == generation, endpoint == origin else { return false }
      operationError = error.localizedDescription
      invalidateLiveStatus(); await refresh()
      return false
    }
  }

  private func submitPrepared(_ candidate: TaskSubmission?) async -> Bool {
    guard !submitting else { return false }
    operationError = nil
    guard !pendingRecordUnreadable else {
      operationError = "저장된 요청을 읽을 수 없습니다. 원래 컴퓨터의 작업을 확인한 뒤 이 기기의 미확인 요청을 해제해 주세요."; return false
    }
    if pending == nil {
      guard canSubmit, let endpoint, let submission = candidate else { return false }
      do {
        _ = try submission.encodedRequest()
        let value = PendingTaskSubmission(submission: submission, origin: endpoint)
        try JSONEncoder().encode(value).write(to: storage.appendingPathComponent("pending.json"), options: .atomic)
        pending = value
      } catch { operationError = error.localizedDescription; return false }
    }
    guard let pending, let endpoint else { operationError = "원래 컴퓨터의 연결 정보를 확인해 주세요."; return false }
    submitting = true; defer { submitting = false }
    do {
      let task: CompanionTask
      if pending.origin == nil {
        // A legacy request has no trustworthy destination. Only read its ID;
        // a missing task is not permission to replay it on this computer.
        task = try await request("/v1/tasks/\(pending.submission.id)")
      } else {
        guard pending.permitsRetry(on: endpoint),
          pending.submission.continuity == nil || pending.submission.continuity?.serverId == connection?.serverId else {
          operationError = "이 요청은 다른 컴퓨터에 보낸 요청입니다. 원래 연결에서 접수를 확인해 주세요."; return false
        }
        task = try await request("/v1/tasks", body: pending.submission.encodedRequest())
      }
      guard pending.submission.matches(task) else { throw URLError(.badServerResponse) }
      if self.pending == pending { try resolvePending(restoringPrompt: false) }
      operationError = nil
      invalidateLiveStatus()
      await refresh()
      return true
    } catch let failure as RequestFailure where pending.origin != nil && failure.isDefinitiveRejection {
      guard self.pending == pending else { return true }
      do {
        try resolvePending(restoringPrompt: true)
        operationError = failure.localizedDescription
      } catch { operationError = error.localizedDescription }
    } catch {
      // Polling may already have confirmed this exact request while the POST
      // response was delayed or lost. A late transport failure cannot undo it.
      guard self.pending == pending else { return true }
      let guidance = pending.origin == nil
        ? "이전 버전의 요청은 원래 컴퓨터에서 접수 여부를 확인해야 합니다. 자동으로 다시 실행하지 않습니다. "
        : "요청 접수를 확인하지 못했습니다. 같은 요청 ID로 다시 확인할 수 있습니다. "
      operationError = guidance + error.localizedDescription
    }
    return false
  }

  private func reconcileListedTask() throws {
    guard let pending, let endpoint,
      pending.permitsConnection(to: endpoint, current: endpoint),
      let task = tasks.first(where: { $0.id == pending.submission.id }), pending.submission.matches(task) else { return }
    try resolvePending(restoringPrompt: false)
    operationError = nil
  }

  private func resolvePending(restoringPrompt: Bool) throws {
    let file = storage.appendingPathComponent("pending.json")
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    prompt = restoringPrompt ? pending?.submission.prompt ?? prompt : ""
    pending = nil; pendingRecordUnreadable = false
  }

  /// The UI must explain that forgetting a local request does not cancel its task.
  func forgetPending() {
    guard !submitting else { operationError = "요청 확인이 끝난 뒤 해제해 주세요."; return }
    operationError = nil
    do { try resolvePending(restoringPrompt: true) }
    catch { operationError = error.localizedDescription }
  }

  func cancel(_ task: CompanionTask) async {
    operationError = nil
    guard let current = currentActionTarget(task), ["queued", "running", "needsApproval"].contains(current.status) else {
      operationError = String(localized: "task.actionNeedsRefresh")
      return
    }
    do {
      let _: CompanionTask = try await request("/v1/tasks/\(task.id)/cancel", body: Data("{}".utf8))
      operationError = nil; invalidateLiveStatus(); await refresh()
    } catch { operationError = error.localizedDescription }
  }
  func approve(_ task: CompanionTask, approval: CompanionTask.Approval, accept: Bool) async {
    operationError = nil
    guard let current = currentActionTarget(task), current.status == "needsApproval",
      current.approvals.contains(approval) else {
      operationError = String(localized: "task.actionNeedsRefresh")
      return
    }
    do {
      let body = try JSONSerialization.data(withJSONObject: ["id": approval.id, "decision": accept ? "accept" : "decline"])
      let _: CompanionTask = try await request("/v1/tasks/\(task.id)/approval", body: body)
      operationError = nil; invalidateLiveStatus(); await refresh()
    } catch { operationError = error.localizedDescription }
  }

  var hasPendingStory: Bool { pendingStoryTurn != nil || pendingStoryUnreadable }
  var canEditStory: Bool {
    isSceneActive && hasFreshStatus && supportsContinuity && story?.serverId == serverId
      && !loadingStory && !savingStory && !savingCompanion && !submitting && !pendingRetry && !hasPendingStory
      && !tasks.contains { !$0.finished }
  }

  private func loadPendingStory() {
    let file = storage.appendingPathComponent("pending-story.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do { pendingStoryTurn = try JSONDecoder().decode(PendingStoryTurn.self, from: Data(contentsOf: file)) }
    catch { pendingStoryUnreadable = true; storyError = String(localized: "story.pendingUnreadable") }
  }

  func refreshStory() async {
    guard isSceneActive, !loadingStory, !savingStory, let origin = endpoint,
      let current = connection, let serverId, current.serverId == serverId else { return }
    let generation = statusGeneration
    loadingStory = true
    defer { loadingStory = false }
    do {
      let value: StoryState = try await request("/v1/story", using: current)
      guard !Task.isCancelled, isSceneActive, statusGeneration == generation, endpoint == origin,
        self.serverId == serverId else { return }
      guard value.serverId == serverId else { throw URLError(.userAuthenticationRequired) }
      if story == nil || value.revision >= story!.revision { story = value }
      if !hasPendingStory { storyError = nil }
    } catch {
      guard !Task.isCancelled, statusGeneration == generation, endpoint == origin else { return }
      storyError = error.localizedDescription
    }
  }

  @discardableResult
  func createStoryEpisode(title: String, castIds: [String], predecessorEpisodeId: String? = nil) async -> Bool {
    var values: [String: Any] = ["title": title, "castIds": castIds]
    if let predecessorEpisodeId { values["predecessorEpisodeId"] = predecessorEpisodeId }
    return await mutateStory("/v1/story/episodes", values: values,
      expectedRevision: story?.revision ?? -1, expectedServerId: serverId ?? "")
  }

  @discardableResult
  func saveStoryRelationship(episodeId: String, from: String, to: String, summary: String,
      sourceEventId: String? = nil, expectedRevision: Int, expectedServerId: String) async -> Bool {
    var values: [String: Any] = ["episodeId": episodeId, "fromCharacterId": from, "toCharacterId": to, "summary": summary]
    if let sourceEventId { values["sourceEventId"] = sourceEventId }
    return await mutateStory("/v1/story/relationships", values: values,
      expectedRevision: expectedRevision, expectedServerId: expectedServerId)
  }

  @discardableResult
  func saveStoryEvent(_ event: StoryEvent, summary: String, forgotten: Bool,
      expectedRevision: Int, expectedServerId: String) async -> Bool {
    await mutateStory("/v1/story/events/\(event.id)", values: ["summary": summary, "forgotten": forgotten],
      expectedRevision: expectedRevision, expectedServerId: expectedServerId)
  }

  private func mutateStory(_ path: String, values: [String: Any], expectedRevision: Int,
      expectedServerId: String) async -> Bool {
    guard canEditStory, let serverId, serverId == expectedServerId, let origin = endpoint,
      story?.revision == expectedRevision else {
      storyError = String(localized: "story.changed"); return false
    }
    savingStory = true; storyError = nil
    let generation = statusGeneration
    defer { savingStory = false }
    do {
      var body = values; body["serverId"] = serverId; body["expectedRevision"] = expectedRevision
      let value: StoryState = try await request(path, body: JSONSerialization.data(withJSONObject: body))
      guard !Task.isCancelled, isSceneActive, statusGeneration == generation, endpoint == origin,
        self.serverId == serverId, value.serverId == serverId else { return false }
      story = value
      return true
    } catch {
      guard endpoint == origin, self.serverId == serverId else { return false }
      storyError = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func submitStoryTurn(episodeId: String, prompt: String) async -> Bool {
    guard !savingStory, let origin = endpoint, let serverId else { return false }
    if pendingStoryTurn == nil {
      guard canEditStory, let story, story.episodes.contains(where: { $0.id == episodeId }),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      let pending = PendingStoryTurn(origin: origin, serverId: serverId, episodeId: episodeId,
        expectedRevision: story.revision, requestId: UUID().uuidString, prompt: prompt)
      do {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: storage.appendingPathComponent("pending-story.json"), options: .atomic)
        pendingStoryTurn = pending
      } catch { storyError = error.localizedDescription; return false }
    }
    guard let pending = pendingStoryTurn, pending.origin == origin, pending.serverId == serverId,
      pending.episodeId == episodeId else { storyError = String(localized: "story.pendingOther"); return false }
    savingStory = true; storyError = nil
    defer { savingStory = false }
    do {
      let task: CompanionTask = try await request("/v1/story/episodes/\(episodeId)/turns", body: pending.encodedRequest())
      guard task.id == pending.requestId, task.episodeId == episodeId, task.prompt == pending.prompt,
        endpoint == origin, self.serverId == serverId else { throw URLError(.badServerResponse) }
      try clearPendingStory()
      tasks.removeAll { $0.id == task.id }; tasks.insert(task, at: 0)
      return true
    } catch let failure as RequestFailure where failure.isDefinitiveRejection {
      do { try clearPendingStory() } catch { storyError = error.localizedDescription; return false }
      storyError = failure.localizedDescription
    } catch { storyError = String(localized: "story.retryHelp") + " " + error.localizedDescription }
    return false
  }

  private func clearPendingStory() throws {
    let file = storage.appendingPathComponent("pending-story.json")
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    pendingStoryTurn = nil; pendingStoryUnreadable = false
  }

  func forgetPendingStory() {
    guard !savingStory else { return }
    do { try clearPendingStory(); storyError = nil }
    catch { storyError = error.localizedDescription }
  }

  private func currentActionTarget(_ task: CompanionTask) -> CompanionTask? {
    guard isSceneActive, hasFreshStatus,
      let current = tasks.first(where: { $0.id == task.id }),
      !current.finished, current.sequence >= task.sequence,
      current.prompt == task.prompt, current.character == task.character,
      current.project == task.project, current.continuity == task.continuity, current.work == task.work,
      current.hasCurrentWorkCast(in: companions) else { return nil }
    return current
  }
}
