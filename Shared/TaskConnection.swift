import Foundation
import Observation
import Security
#if os(watchOS)
import WatchKit
#endif

struct ComputerConnection: Codable {
  var url: String
  var token: String
}

@MainActor @Observable
final class TaskConnection {
  var tasks: [CompanionTask] = []
  var project = ""
  var error: String? { operationError ?? refreshError }
  private var operationError: String?
  private var refreshError: String?
  var connected = false
  var submitting = false
  var address = ""
  var connectionToken = ""
  var prompt = ""
  private var connection: ComputerConnection?
  private var pending: PendingTaskSubmission?
  private var pendingRecordUnreadable = false
  private var connectionAttempt = UUID()
  private var acknowledged: [String: Int] = [:]
  private let credentialAccount = "doboo.computer.connection"
  private let storage: URL
  private struct ListResponse: Decodable { let project: String; let tasks: [CompanionTask] }
  private struct Failure: Decodable { let error: String; let submissionRejected: Bool? }
  private struct RequestFailure: LocalizedError {
    let status: Int
    let message: String
    let submissionRejected: Bool?
    var errorDescription: String? { message }
    var isDefinitiveRejection: Bool { PendingTaskSubmission.isDefinitiveRejection(status: status, submissionRejected: submissionRejected) }
  }

  init() {
    storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DobooTasks")
    try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: storage.appendingPathComponent("tasks.json")) { tasks = (try? JSONDecoder().decode([CompanionTask].self, from: data)) ?? [] }
    let pendingFile = storage.appendingPathComponent("pending.json")
    if FileManager.default.fileExists(atPath: pendingFile.path) {
      do { pending = try JSONDecoder().decode(PendingTaskSubmission.self, from: Data(contentsOf: pendingFile)) }
      catch { pendingRecordUnreadable = true }
    }
    var result: CFTypeRef?
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: credentialAccount,
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
      connection = value; try? saveCredential(value)
    }
    #endif
    address = connection?.url ?? ""
    connectionToken = connection?.token ?? ""
    prompt = pending?.submission.prompt ?? ""
  }

  var hasConnection: Bool { connection != nil }
  var canSubmit: Bool { connected && !submitting && !pendingRetry && !tasks.contains(where: { !$0.finished }) }
  var pendingRetry: Bool { pending != nil || pendingRecordUnreadable }
  private var endpoint: TaskEndpointIdentity? { connection.flatMap { TaskEndpointIdentity(url: $0.url, token: $0.token) } }

  private func saveCredential(_ value: ComputerConnection) throws {
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
    operationError = nil
    let attempt = UUID(); connectionAttempt = attempt
    guard !submitting else { operationError = "요청 접수를 확인한 뒤 연결을 변경해 주세요."; return false }
    guard let candidate = TaskEndpointIdentity(url: address, token: connectionToken) else {
      operationError = "HTTPS 주소와 연결 키를 확인해 주세요. 시뮬레이터에서는 localhost도 허용합니다."; return false
    }
    guard permitsConnection(to: candidate) else { operationError = "접수를 확인하지 못한 요청이 있습니다. 원래 컴퓨터에서 확인한 뒤 연결을 변경해 주세요."; return false }
    let value = ComputerConnection(url: candidate.url, token: connectionToken)
    do {
      let list: ListResponse = try await request("/v1/tasks", using: value)
      guard connectionAttempt == attempt else { return false }
      // A submission can start while this connection check is awaiting its reply.
      guard !submitting, permitsConnection(to: candidate) else {
        operationError = "접수를 확인하지 못한 요청이 있습니다. 원래 컴퓨터에서 확인한 뒤 연결을 변경해 주세요."; return false
      }
      try saveCredential(value)
      connection = value; address = value.url
      tasks = list.tasks; project = list.project; connected = true; refreshError = nil; acknowledged = [:]
      try reconcileListedTask()
      operationError = nil
      return true
    } catch {
      guard connectionAttempt == attempt else { return false }
      operationError = error.localizedDescription; return false
    }
  }

  private func permitsConnection(to candidate: TaskEndpointIdentity) -> Bool {
    guard !pendingRecordUnreadable else { return false }
    return pending?.permitsConnection(to: candidate, current: endpoint) ?? true
  }

  private func request<T: Decodable>(_ path: String, body: Data? = nil, using explicitConnection: ComputerConnection? = nil) async throws -> T {
    guard let connection = explicitConnection ?? connection, let url = URL(string: connection.url + path) else { throw URLError(.userAuthenticationRequired) }
    var request = URLRequest(url: url); request.timeoutInterval = 12
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard http.statusCode == 200 else {
      let failure = try? JSONDecoder().decode(Failure.self, from: data)
      throw RequestFailure(status: http.statusCode, message: failure?.error ?? "컴퓨터 응답을 확인하지 못했습니다.", submissionRejected: failure?.submissionRejected)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  func refresh() async {
    guard let current = connection, let origin = endpoint else { return }
    do {
      let list: ListResponse = try await request("/v1/tasks", using: current)
      guard endpoint == origin else { return }
      #if os(watchOS)
      if let latest = list.tasks.first, let old = tasks.first(where: { $0.id == latest.id }), latest.status != old.status {
        if latest.status == "completed" { WKInterfaceDevice.current().play(.success) }
        if latest.status == "needsApproval" || latest.status == "failed" { WKInterfaceDevice.current().play(.notification) }
      }
      #endif
      tasks = list.tasks; project = list.project; connected = true; refreshError = nil
      try JSONEncoder().encode(tasks).write(to: storage.appendingPathComponent("tasks.json"), options: .atomic)
      try reconcileListedTask()
      for task in tasks.prefix(1) where acknowledged[task.id] != task.sequence {
        #if os(watchOS)
        let surface = "watch"
        #else
        let surface = "phone"
        #endif
        let body = try JSONSerialization.data(withJSONObject: ["surface": surface, "sequence": task.sequence])
        let _: [String: Bool] = try await request("/v1/tasks/\(task.id)/receipt", body: body, using: current)
        guard endpoint == origin else { return }
        acknowledged[task.id] = task.sequence
      }
    } catch {
      guard endpoint == origin else { return }
      refreshError = error.localizedDescription; connected = false
    }
  }

  func submit(character: CharacterPack) async {
    guard !submitting else { return }
    operationError = nil
    guard !pendingRecordUnreadable else {
      operationError = "저장된 요청을 읽을 수 없습니다. 원래 컴퓨터의 작업을 확인한 뒤 이 기기의 미확인 요청을 해제해 주세요."; return
    }
    if pending == nil {
      guard canSubmit, let endpoint else { return }
      let submission = TaskSubmission(id: UUID().uuidString.lowercased(), prompt: prompt,
        character: .init(id: character.id, version: character.version, name: character.name))
      do {
        _ = try submission.encodedRequest()
        let value = PendingTaskSubmission(submission: submission, origin: endpoint)
        try JSONEncoder().encode(value).write(to: storage.appendingPathComponent("pending.json"), options: .atomic)
        pending = value
      } catch { operationError = error.localizedDescription; return }
    }
    guard let pending, let endpoint else { operationError = "원래 컴퓨터의 연결 정보를 확인해 주세요."; return }
    submitting = true; defer { submitting = false }
    do {
      let task: CompanionTask
      if pending.origin == nil {
        // A legacy request has no trustworthy destination. Only read its ID;
        // a missing task is not permission to replay it on this computer.
        task = try await request("/v1/tasks/\(pending.submission.id)")
      } else {
        guard pending.permitsRetry(on: endpoint) else {
          operationError = "이 요청은 다른 컴퓨터에 보낸 요청입니다. 원래 연결에서 접수를 확인해 주세요."; return
        }
        task = try await request("/v1/tasks", body: pending.submission.encodedRequest())
      }
      guard pending.submission.matches(task) else { throw URLError(.badServerResponse) }
      if self.pending == pending { try resolvePending(restoringPrompt: false) }
      operationError = nil
      await refresh()
    } catch let failure as RequestFailure where pending.origin != nil && failure.isDefinitiveRejection {
      guard self.pending == pending else { return }
      do {
        try resolvePending(restoringPrompt: true)
        operationError = failure.localizedDescription
      } catch { operationError = error.localizedDescription }
    } catch {
      // Polling may already have confirmed this exact request while the POST
      // response was delayed or lost. A late transport failure cannot undo it.
      guard self.pending == pending else { return }
      let guidance = pending.origin == nil
        ? "이전 버전의 요청은 원래 컴퓨터에서 접수 여부를 확인해야 합니다. 자동으로 다시 실행하지 않습니다. "
        : "요청 접수를 확인하지 못했습니다. 같은 요청 ID로 다시 확인할 수 있습니다. "
      operationError = guidance + error.localizedDescription
    }
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
    do {
      let _: CompanionTask = try await request("/v1/tasks/\(task.id)/cancel", body: Data("{}".utf8))
      operationError = nil; await refresh()
    } catch { operationError = error.localizedDescription }
  }
  func approve(_ task: CompanionTask, approval: CompanionTask.Approval, accept: Bool) async {
    operationError = nil
    do {
      let body = try JSONSerialization.data(withJSONObject: ["id": approval.id, "decision": accept ? "accept" : "decline"])
      let _: CompanionTask = try await request("/v1/tasks/\(task.id)/approval", body: body)
      operationError = nil; await refresh()
    } catch { operationError = error.localizedDescription }
  }
}
