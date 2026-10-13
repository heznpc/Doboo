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
  var error: String?
  var connected = false
  var submitting = false
  var address = ""
  var connectionToken = ""
  var prompt = ""
  private var connection: ComputerConnection?
  private var pending: Submission?
  private var acknowledged: [String: Int] = [:]
  private let credentialAccount = "doboo.computer.connection"
  private let storage: URL
  private struct Submission: Codable { let id: String; let prompt: String; let character: CompanionTask.Character }
  private struct ListResponse: Decodable { let project: String; let tasks: [CompanionTask] }
  private struct Failure: Decodable { let error: String }

  init() {
    storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DobooTasks")
    try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: storage.appendingPathComponent("tasks.json")) { tasks = (try? JSONDecoder().decode([CompanionTask].self, from: data)) ?? [] }
    if let data = try? Data(contentsOf: storage.appendingPathComponent("pending.json")) { pending = try? JSONDecoder().decode(Submission.self, from: data) }
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
  }

  var hasConnection: Bool { connection != nil }
  var canSubmit: Bool { connected && !submitting && !tasks.contains(where: { !$0.finished }) }
  var pendingRetry: Bool { pending != nil }

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

  func connect() async {
    guard let url = URL(string: address), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")), connectionToken.count >= 32 else {
      error = "HTTPS 주소와 연결 키를 확인해 주세요. 시뮬레이터에서는 localhost도 허용합니다."; return
    }
    let previous = connection
    connection = ComputerConnection(url: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: connectionToken)
    do {
      let list: ListResponse = try await request("/v1/tasks")
      try saveCredential(connection!)
      tasks = list.tasks; project = list.project; connected = true; error = nil; acknowledged = [:]
    } catch { connection = previous; self.error = error.localizedDescription; connected = false }
  }

  private func request<T: Decodable>(_ path: String, body: Data? = nil) async throws -> T {
    guard let connection, let url = URL(string: connection.url + path) else { throw URLError(.userAuthenticationRequired) }
    var request = URLRequest(url: url); request.timeoutInterval = 12
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "컴퓨터 응답을 확인하지 못했습니다."
      throw NSError(domain: "DobooTask", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  func refresh() async {
    guard connection != nil else { return }
    do {
      let list: ListResponse = try await request("/v1/tasks")
      #if os(watchOS)
      if let latest = list.tasks.first, let old = tasks.first(where: { $0.id == latest.id }), latest.status != old.status {
        if latest.status == "completed" { WKInterfaceDevice.current().play(.success) }
        if latest.status == "needsApproval" || latest.status == "failed" { WKInterfaceDevice.current().play(.notification) }
      }
      #endif
      tasks = list.tasks; project = list.project; connected = true; error = nil
      try JSONEncoder().encode(tasks).write(to: storage.appendingPathComponent("tasks.json"), options: .atomic)
      for task in tasks.prefix(1) where acknowledged[task.id] != task.sequence {
        #if os(watchOS)
        let surface = "watch"
        #else
        let surface = "phone"
        #endif
        let body = try JSONSerialization.data(withJSONObject: ["surface": surface, "sequence": task.sequence])
        let _: [String: Bool] = try await request("/v1/tasks/\(task.id)/receipt", body: body)
        acknowledged[task.id] = task.sequence
      }
    } catch { self.error = error.localizedDescription; connected = false }
  }

  func submit(character: CharacterPack) async {
    guard !submitting else { return }
    if pending == nil {
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      pending = Submission(id: UUID().uuidString.lowercased(), prompt: prompt,
        character: .init(id: character.id, version: character.version, name: character.name))
      do { try JSONEncoder().encode(pending!).write(to: storage.appendingPathComponent("pending.json"), options: .atomic) }
      catch { pending = nil; self.error = error.localizedDescription; return }
    }
    submitting = true; defer { submitting = false }
    do {
      let _: CompanionTask = try await request("/v1/tasks", body: JSONEncoder().encode(pending!))
      try? FileManager.default.removeItem(at: storage.appendingPathComponent("pending.json"))
      pending = nil; prompt = ""; await refresh()
    } catch { self.error = "요청 접수를 확인하지 못했습니다. 같은 요청 ID로 다시 확인할 수 있습니다. " + error.localizedDescription }
  }

  func cancel(_ task: CompanionTask) async {
    do { let _: CompanionTask = try await request("/v1/tasks/\(task.id)/cancel", body: Data("{}".utf8)); await refresh() }
    catch { self.error = error.localizedDescription }
  }
  func approve(_ task: CompanionTask, approval: CompanionTask.Approval, accept: Bool) async {
    do {
      let body = try JSONSerialization.data(withJSONObject: ["id": approval.id, "decision": accept ? "accept" : "decline"])
      let _: CompanionTask = try await request("/v1/tasks/\(task.id)/approval", body: body); await refresh()
    } catch { self.error = error.localizedDescription }
  }
}
