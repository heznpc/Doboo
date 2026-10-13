import Foundation
import WatchConnectivity

/// A successful transport callback is not an import receipt. Only the receiver's
/// acknowledgement after validation and atomic persistence marks a delivery.
@MainActor
final class CharacterTransfer: NSObject, WCSessionDelegate {
  private weak var library: CharacterLibrary?
  private let session: WCSession?
  private var pendingID: String?

  init(library: CharacterLibrary) {
    self.library = library
    self.session = WCSession.isSupported() ? .default : nil
    super.init()
    session?.delegate = self
    session?.activate()
    if session == nil { library.transferStatus = String(localized: "transfer.unavailable") }
  }

  func send(_ pack: CharacterPack) {
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
      try pack.encoded().write(to: url, options: .atomic)
      pendingID = token
      UserDefaults.standard.set(token, forKey: "doboo.transfer.pending")
      session.transferFile(url, metadata: ["characterID": pack.id, "version": pack.version, "receiptID": token])
      library?.transferStatus = String(localized: "transfer.queued")
    } catch { library?.errorMessage = error.localizedDescription }
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    let errorMessage = error?.localizedDescription
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingID = UserDefaults.standard.string(forKey: "doboo.transfer.pending")
      if let errorMessage { self.library?.transferStatus = errorMessage }
      else if self.pendingID != nil { self.library?.transferStatus = String(localized: "transfer.awaiting") }
    }
  }

  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    let receiptID = file.metadata?["receiptID"] as? String ?? ""
    // WC owns this temporary URL only for the duration of this callback.
    let result: Result<Data, Error>
    do { result = .success(try CharacterLibrary.readBoundedFile(file.fileURL)) }
    catch { result = .failure(error) }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let library = self.library else { return }
        let pack = try library.importData(result.get())
        self.session?.transferUserInfo(["dobooReceipt": receiptID, "result": "imported", "characterID": pack.id])
      } catch {
        self.library?.errorMessage = error.localizedDescription
        self.session?.transferUserInfo(["dobooReceipt": receiptID, "result": "rejected", "reason": error.localizedDescription])
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
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let token = userInfo["dobooReceipt"] as? String
    let result = userInfo["result"] as? String
    let reason = userInfo["reason"] as? String
    Task { @MainActor [weak self] in
      guard let self, let token, token == self.pendingID else { return }
      if result == "imported" {
        self.library?.transferStatus = String(localized: "transfer.delivered")
      } else {
        self.library?.transferStatus = String(localized: "transfer.rejected") + " " + (reason ?? "")
      }
      self.pendingID = nil
      UserDefaults.standard.removeObject(forKey: "doboo.transfer.pending")
    }
  }

  #if os(iOS)
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  #endif
}
