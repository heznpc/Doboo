import Foundation

/// Writes a new file before replacing the manifest, so a failed import cannot
/// replace an existing pack or selection. Superseded files are removed afterward.
struct CharacterStore {
  private struct Manifest: Codable {
    var entries: [String: String]
    var selectedID: String
  }
  let directory: URL
  private var manifest: Manifest
  private(set) var packs: [CharacterPack]
  var selectedID: String { manifest.selectedID }
  var selected: CharacterPack { packs.first(where: { $0.id == selectedID }) ?? .builtin }

  init(directory: URL, bundled: [CharacterPack] = [.builtin]) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestURL = directory.appendingPathComponent("library.json")
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      let decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
      var loaded: [CharacterPack] = []
      for (id, filename) in decoded.entries {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.contains("..") else {
          throw CharacterPackError.storageUnavailable
        }
        let pack = try CharacterPack.decode(Data(contentsOf: directory.appendingPathComponent(filename)))
        guard pack.id == id else { throw CharacterPackError.storageUnavailable }
        loaded.append(pack)
      }
      guard loaded.contains(where: { $0.id == decoded.selectedID }) else { throw CharacterPackError.storageUnavailable }
      manifest = decoded
      packs = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    } else {
      manifest = Manifest(entries: [:], selectedID: bundled.first?.id ?? CharacterPack.builtin.id)
      packs = []
      for pack in bundled.isEmpty ? [.builtin] : bundled { _ = try importPack(pack) }
    }
  }

  @discardableResult
  mutating func importPack(_ pack: CharacterPack) throws -> CharacterPack {
    let data = try pack.encoded()
    if let current = packs.first(where: { $0.id == pack.id }) {
      if current == pack { return current }
      guard pack.version > current.version else { throw CharacterPackError.conflictingVersion }
    }
    let filename = "\(UUID().uuidString).doboo.json"
    let packURL = directory.appendingPathComponent(filename)
    try data.write(to: packURL, options: .atomic)
    let oldFilename = manifest.entries[pack.id]
    var next = manifest
    next.entries[pack.id] = filename
    if packs.isEmpty { next.selectedID = pack.id }
    do { try writeManifest(next) }
    catch {
      try? FileManager.default.removeItem(at: packURL)
      throw error
    }
    manifest = next
    packs.removeAll { $0.id == pack.id }
    packs.append(pack)
    packs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if let oldFilename {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldFilename))
    }
    return pack
  }

  mutating func select(id: String) throws {
    guard packs.contains(where: { $0.id == id }) else { throw CharacterPackError.missingCharacter }
    var next = manifest
    next.selectedID = id
    try writeManifest(next)
    manifest = next
  }

  private func writeManifest(_ value: Manifest) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
  }
}
