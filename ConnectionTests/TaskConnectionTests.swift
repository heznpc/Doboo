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
  var started: Bool { lock.withLock { didStart } }
  var stopped: Bool { lock.withLock { didStop } }

  func start(_ transport: ControlledURLProtocol) {
    lock.withLock { active = transport; didStart = true }
  }

  func stop() {
    lock.withLock { active = nil; didStop = true }
  }

  func reply(project: String, status: Int = 200) throws {
    let transport = lock.withLock { () -> ControlledURLProtocol? in
      defer { active = nil }
      return active
    }
    guard let transport, let url = transport.request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    else { throw Failure(description: "No active request for the controlled reply") }
    let body: [String: Any] = status == 200
      ? ["project": project, "tasks": []] : ["error": "delayed test failure"]
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

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledURLProtocol.self]
    session = URLSession(configuration: configuration)
    let credentials = self.credentials
    connection = TaskConnection(storage: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      session: session, persistCredential: { credentials.urls.append($0.url) })
    connection.connectionToken = String(repeating: "a", count: 64)
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
  }
}

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
    print("Passed 5 connection lifecycle regressions (URLProtocol; no network or Keychain).")
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
}
