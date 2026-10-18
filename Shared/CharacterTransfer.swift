import Foundation
import WatchConnectivity
import CryptoKit

/// A successful transport callback is not an import receipt. Only the receiver's
/// acknowledgement after validation and atomic persistence marks a delivery.
@MainActor
final class CharacterTransfer: NSObject, WCSessionDelegate {
  private weak var library: CharacterLibrary?
  private weak var tasks: TaskConnection?
  private let session: WCSession?
  private var pendingID: String?
  private struct Pending: Codable {
    var token: String
    var characterID: String
    var version: Int64
    var sha256: String
    var definitionSHA256: String
  }
  private var pending: Pending?

  init(library: CharacterLibrary) {
    self.library = library
    self.session = WCSession.isSupported() ? .default : nil
    super.init()
    session?.delegate = self
    session?.activate()
    if session == nil { library.transferStatus = String(localized: "transfer.unavailable") }
  }

  func attachConnection(_ connection: TaskConnection) {
    tasks = connection
    #if os(iOS)
    connection.watchConnectionSender = { [weak self] envelope in
      guard let self else { throw URLError(.networkConnectionLost) }
      return try await self.sendConnection(envelope)
    }
    #endif
  }

  private func sendConnection(_ envelope: WatchConnectionEnvelope) async throws -> WatchConnectionReceipt {
    guard let session, session.activationState == .activated, session.isReachable, envelope.isValid else {
      throw URLError(.notConnectedToInternet)
    }
    let data = try JSONEncoder().encode(envelope)
    // Reachability messages are deliberately used instead of queued transfers:
    // an old secret must not replace a later connection after delayed delivery.
    let receiptData: Data = try await withCheckedThrowingContinuation { continuation in
      session.sendMessage(["dobooComputerConnection": data], replyHandler: { reply in
        guard let data = reply["dobooComputerReceipt"] as? Data else {
          continuation.resume(throwing: URLError(.badServerResponse)); return
        }
        continuation.resume(returning: data)
      }, errorHandler: { error in continuation.resume(throwing: error) })
    }
    return try JSONDecoder().decode(WatchConnectionReceipt.self, from: receiptData)
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                           replyHandler: @escaping ([String: Any]) -> Void) {
    guard let data = message["dobooComputerConnection"] as? Data, data.count <= 8192,
      let envelope = try? JSONDecoder().decode(WatchConnectionEnvelope.self, from: data), envelope.isValid else {
      replyHandler(["rejected": true]); return
    }
    // WCSession invokes this delegate off the main actor. Wrap its one-shot
    // callback so only immutable Sendable input crosses to the connection owner.
    let reply = ConnectionReply(replyHandler)
    Task { @MainActor [weak self] in
      #if os(watchOS)
      do {
        guard let tasks = self?.tasks else { throw URLError(.notConnectedToInternet) }
        let receipt = try await tasks.receiveWatchConnection(envelope)
        reply.finish(["dobooComputerReceipt": try JSONEncoder().encode(receipt)])
      } catch { reply.finish(["rejected": true]) }
      #else
      reply.finish(["rejected": true])
      #endif
    }
  }

  private final class ConnectionReply: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func finish(_ value: [String: Any]) { callback(value) }
  }

  func send(_ pack: CharacterPack, originalData: Data? = nil) {
    defer { recordDiagnostic("send") }
    guard let session, session.activationState == .activated else {
      library?.transferStatus = String(localized: "transfer.notReady")
      return
    }
    #if os(iOS)
    guard session.isPaired, session.isWatchAppInstalled else {
      library?.transferStatus = String(localized: "transfer.noWatch")
      return
    }
    #endif
    do {
      let directory = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CharacterTransfers")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let token = UUID().uuidString
      let url = directory.appendingPathComponent("\(token).doboo.json")
      let data = try originalData ?? pack.encoded()
      guard try CharacterPack.decode(data) == pack else { throw CharacterPackError.invalidJSON }
      try data.write(to: url, options: .atomic)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let next = Pending(token: token, characterID: pack.id, version: pack.version, sha256: digest, definitionSHA256: try pack.definitionSHA256)
      pending = next
      UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: "doboo.transfer.expected")
      pendingID = token
      UserDefaults.standard.set(token, forKey: "doboo.transfer.pending")
      session.transferFile(url, metadata: ["characterID": pack.id, "version": pack.version, "receiptID": token, "sha256": digest, "definitionSHA256": next.definitionSHA256])
      library?.transferStatus = String(localized: "transfer.queued")
    } catch { library?.errorMessage = error.localizedDescription }
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    let errorMessage = error?.localizedDescription
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingID = UserDefaults.standard.string(forKey: "doboo.transfer.pending")
      if let data = UserDefaults.standard.data(forKey: "doboo.transfer.expected") {
        self.pending = try? JSONDecoder().decode(Pending.self, from: data)
      }
      if let errorMessage { self.library?.transferStatus = errorMessage }
      else if self.pendingID != nil { self.library?.transferStatus = String(localized: "transfer.awaiting") }
      self.recordDiagnostic("activation")
      #if DEBUG && os(iOS)
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--character-transfer-diagnostics"), activationState == .activated,
        let index = arguments.firstIndex(of: "--send-character"), index + 1 < arguments.count,
        let pack = self.library?.packs.first(where: { $0.id == arguments[index + 1] }) {
        self.send(pack)
      }
      #endif
    }
  }

  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    let receiptID = file.metadata?["receiptID"] as? String ?? ""
    let expectedID = file.metadata?["characterID"] as? String
    let expectedVersion = (file.metadata?["version"] as? NSNumber)?.int64Value
    let expectedHash = file.metadata?["sha256"] as? String
    let expectedDefinition = file.metadata?["definitionSHA256"] as? String
    // WC owns this temporary URL only for the duration of this callback.
    let result: Result<Data, Error>
    do { result = .success(try CharacterLibrary.readBoundedFile(file.fileURL)) }
    catch { result = .failure(error) }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let library = self.library else { return }
        let data = try result.get()
        let candidate = try CharacterPack.decode(data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard candidate.id == expectedID, candidate.version == expectedVersion, digest == expectedHash, try candidate.definitionSHA256 == expectedDefinition else {
          throw CharacterPackError.invalidJSON
        }
        let pack = try library.importData(data)
        library.select(pack)
        let selected = library.selected.id == pack.id && library.selected.version == pack.version
        self.session?.transferUserInfo(["dobooReceipt": receiptID, "result": "imported", "characterID": pack.id,
          "version": pack.version, "sha256": digest, "definitionSHA256": try pack.definitionSHA256, "selected": selected])
        self.recordDiagnostic("imported")
      } catch {
        self.library?.errorMessage = error.localizedDescription
        self.session?.transferUserInfo(["dobooReceipt": receiptID, "result": "rejected", "reason": error.localizedDescription])
        self.recordDiagnostic("rejected")
      }
    }
  }

  nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    let receiptID = fileTransfer.file.metadata?["receiptID"] as? String
    let url = fileTransfer.file.fileURL
    let errorMessage = error?.localizedDescription
    Task { @MainActor [weak self] in
      guard let self else { return }
      // These URLs were created exclusively in our own transfer directory.
      if url.deletingLastPathComponent().lastPathComponent == "CharacterTransfers" {
        try? FileManager.default.removeItem(at: url)
      }
      guard receiptID == self.pendingID else { return }
      if let errorMessage {
        self.library?.transferStatus = String(localized: "transfer.failed") + " " + errorMessage
        self.pendingID = nil
        UserDefaults.standard.removeObject(forKey: "doboo.transfer.pending")
      }
      else { self.library?.transferStatus = String(localized: "transfer.awaiting") }
      self.recordDiagnostic("transport-finished")
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let token = userInfo["dobooReceipt"] as? String
    let result = userInfo["result"] as? String
    let reason = userInfo["reason"] as? String
    let characterID = userInfo["characterID"] as? String
    let version = (userInfo["version"] as? NSNumber)?.int64Value
    let digest = userInfo["sha256"] as? String
    let definition = userInfo["definitionSHA256"] as? String
    let selected = userInfo["selected"] as? Bool ?? false
    Task { @MainActor [weak self] in
      guard let self, let token, token == self.pendingID else { return }
      if result == "imported" {
        guard let expected = self.pending, expected.token == token,
          characterID == expected.characterID, version == expected.version, digest == expected.sha256, definition == expected.definitionSHA256 else {
          self.library?.transferStatus = String(localized: "transfer.rejected")
          return
        }
        do {
          let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          let receipts = documents.appendingPathComponent("DobooReceipts", isDirectory: true)
          try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
          let receipt: [String: Any] = ["receiptID": token, "result": "imported", "characterID": expected.characterID,
            "version": expected.version, "sha256": expected.sha256, "definitionSHA256": expected.definitionSHA256, "selected": selected]
          let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
          try bytes.write(to: receipts.appendingPathComponent("\(expected.characterID)-v\(expected.version).json"), options: .atomic)
        } catch { self.library?.errorMessage = error.localizedDescription; return }
        self.library?.transferStatus = selected
          ? String(localized: "transfer.deliveredSelected")
          : String(localized: "transfer.delivered")
      } else {
        self.library?.transferStatus = String(localized: "transfer.rejected") + " " + (reason ?? "")
      }
      self.pendingID = nil
      self.pending = nil
      UserDefaults.standard.removeObject(forKey: "doboo.transfer.expected")
      UserDefaults.standard.removeObject(forKey: "doboo.transfer.pending")
      self.recordDiagnostic(result == "imported" ? "receipt-imported" : "receipt-rejected")
    }
  }

  #if os(iOS)
  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.recordDiagnostic("watch-state-changed") }
  }
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  #endif

  /// Opt-in local evidence for device testing; never emits character contents.
  /// Release builds and normal launches do not write diagnostic files.
  private func recordDiagnostic(_ event: String) {
    #if DEBUG
    guard ProcessInfo.processInfo.arguments.contains("--character-transfer-diagnostics"),
      let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true) else { return }
    var values: [String: Any] = ["event": event, "status": library?.transferStatus ?? "",
      "activationState": session?.activationState.rawValue ?? -1,
      "reachable": session?.isReachable ?? false,
      "outstandingFileTransfers": session?.outstandingFileTransfers.count ?? 0,
      "awaitingReceipt": pendingID != nil]
    #if os(iOS)
    values["paired"] = session?.isPaired ?? false
    values["watchAppInstalled"] = session?.isWatchAppInstalled ?? false
    #endif
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: directory.appendingPathComponent("CharacterTransferDiagnostics.json"), options: .atomic)
    }
    #endif
  }
}
