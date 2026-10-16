import Foundation
import Observation
#if os(watchOS)
import WidgetKit
#endif

@MainActor @Observable
final class CharacterLibrary {
  private(set) var packs: [CharacterPack] = [.builtin]
  private(set) var selected: CharacterPack = .builtin
  var errorMessage: String?
  var notice: String?
  var widgetSyncError: String?
  var transferStatus = String(localized: "transfer.idle")
  @ObservationIgnored private var store: CharacterStore?
  @ObservationIgnored private(set) var transfer: CharacterTransfer?
  #if os(watchOS)
  @ObservationIgnored private var widgetSnapshotPack: CharacterPack?
  @ObservationIgnored private var widgetSnapshot: WatchWidgetSnapshot?
  #endif

  init(directory: URL? = nil) {
    do {
      let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CharacterLibrary", isDirectory: true)
      let resourceURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Characters") ?? []
      let bundled = resourceURLs.compactMap { try? CharacterPack.decode(Data(contentsOf: $0)) }
      store = try CharacterStore(directory: root, bundled: bundled.isEmpty ? [.builtin] : bundled)
      refresh()
    } catch {
      errorMessage = CharacterPackError.storageUnavailable.localizedDescription
      refreshWidgetSnapshot()
    }
  }

  func startTransfer() {
    guard transfer == nil else { return }
    transfer = CharacterTransfer(library: self)
  }

  @discardableResult
  func importData(_ data: Data) throws -> CharacterPack {
    let pack = try CharacterPack.decode(data)
    try SpriteAtlas.validate(pack)
    guard store != nil else { throw CharacterPackError.storageUnavailable }
    let saved = try store!.importPack(pack)
    refresh()
    notice = String(localized: "library.imported") + " “\(pack.name)”"
    return saved
  }

  func importFile(_ url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Self.readBoundedFile(url)
      _ = try importData(data)
    } catch { errorMessage = error.localizedDescription }
  }

  nonisolated static func readBoundedFile(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: CharacterPack.maximumJSONBytes + 1) ?? Data()
    guard data.count <= CharacterPack.maximumJSONBytes else { throw CharacterPackError.jsonTooLarge }
    return data
  }

  func select(_ pack: CharacterPack) {
    do {
      try SpriteAtlas.validate(pack)
      guard store != nil else { throw CharacterPackError.storageUnavailable }
      try store!.select(id: pack.id)
      refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  func exportURL(for pack: CharacterPack) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CharacterExports", isDirectory: true)
      .appendingPathComponent("\(pack.id)-v\(pack.version)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(pack.id).doboo.json")
    try pack.encoded().write(to: url, options: .atomic)
    return url
  }

  private func refresh() {
    guard let store else { return }
    packs = store.packs
    selected = store.selected
    refreshWidgetSnapshot()
  }

  func refreshWidgetSnapshot(forceReload: Bool = false) {
    #if os(watchOS)
    let snapshot: WatchWidgetSnapshot
    if widgetSnapshotPack == selected, let cached = widgetSnapshot {
      snapshot = cached
    } else {
      snapshot = (try? WatchWidgetSnapshot.make(for: selected)) ?? .unavailable
      if !snapshot.needsSync {
        widgetSnapshotPack = selected
        widgetSnapshot = snapshot
      }
    }
    do {
      let changed = try WatchWidgetSnapshotStore.shared.save(snapshot)
      if changed || (forceReload && !snapshot.needsSync) {
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetSnapshot.widgetKind)
      }
      widgetSyncError = snapshot.needsSync ? String(localized: "widget.syncError") : nil
    } catch {
      widgetSyncError = String(localized: "widget.syncError")
    }
    #endif
  }

  #if DEBUG
  func importLaunchArgument() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--import-character"), index + 1 < arguments.count else { return }
    importFile(URL(fileURLWithPath: arguments[index + 1]))
  }
  #endif
}
