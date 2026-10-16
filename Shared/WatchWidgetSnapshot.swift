import Foundation
import CoreGraphics
import ImageIO

/// A single atomic payload keeps the widget's name, tint, and image on the same
/// character revision. The full character definition stays in the app's library.
struct WatchWidgetSnapshot: Codable, Equatable, Sendable {
  static let appGroup = "group.app.doboo.watch"
  static let widgetKind = "DobooCompanion"
  static let maximumPNGBytes = 256 * 1024
  static let maximumJSONBytes = 384 * 1024

  var schemaVersion = 1
  var characterID: String
  var characterVersion: Int64
  var name: String
  var renderer: CharacterPack.Appearance.Renderer
  var tint: String
  var idlePNG: Data?
  var needsSync = false

  static let builtin = WatchWidgetSnapshot(
    characterID: CharacterPack.builtin.id, characterVersion: CharacterPack.builtin.version,
    name: CharacterPack.builtin.name, renderer: .nativeDoboo, tint: CharacterPack.builtin.appearance.tint)

  static var unavailable: WatchWidgetSnapshot {
    var snapshot = builtin
    snapshot.needsSync = true
    return snapshot
  }

  static func make(for pack: CharacterPack) throws -> WatchWidgetSnapshot {
    _ = try pack.validated()
    let representation = pack.watchRepresentation
    var snapshot = WatchWidgetSnapshot(characterID: pack.id, characterVersion: pack.version,
      name: pack.name, renderer: representation.appearance.renderer, tint: representation.appearance.tint)
    if representation.appearance.renderer == .spritesheet {
      guard let sprite = representation.appearance.sprite, let data = representation.spriteData else {
        throw SnapshotError.invalidImage
      }
      let atlas = try decodePNG(data, width: 1536, height: sprite.layout.pixelHeight,
                                limit: CharacterPack.maximumImageBytes)
      let rect = CGRect(x: 0, y: 0, width: SpriteFrame.width, height: SpriteFrame.height)
      guard let frame = atlas.cropping(to: rect) else { throw SnapshotError.invalidImage }
      // Valid character PNGs may use 16-bit channels or a large color profile.
      // Normalize the display-sized frame so its PNG stays within the snapshot
      // budget without reducing dimensions or dropping transparency.
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: SpriteFrame.width, height: SpriteFrame.height,
          bitsPerComponent: 8, bytesPerRow: SpriteFrame.width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { throw SnapshotError.invalidImage }
      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      context.draw(frame, in: rect)
      guard let normalized = context.makeImage() else { throw SnapshotError.invalidImage }
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        throw SnapshotError.invalidImage
      }
      CGImageDestinationAddImage(destination, normalized, nil)
      guard CGImageDestinationFinalize(destination) else { throw SnapshotError.invalidImage }
      snapshot.idlePNG = output as Data
    }
    return try snapshot.validated()
  }

  func validated() throws -> WatchWidgetSnapshot {
    let lineBreaks: Set<UInt32> = [9, 10, 13, 0x85, 0x2028, 0x2029]
    guard schemaVersion == 1,
      (1...64).contains(characterID.utf8.count),
      characterID.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
      (1...9_007_199_254_740_991).contains(characterVersion),
      (1...80).contains(name.unicodeScalars.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || lineBreaks.contains($0.value) }),
      tint.utf8.count == 7, tint.first == "#", tint.unicodeScalars.allSatisfy(\.isASCII),
      tint.dropFirst().allSatisfy(\.isHexDigit)
    else { throw SnapshotError.invalidMetadata }
    if needsSync, self != Self.unavailable { throw SnapshotError.invalidMetadata }
    switch renderer {
    case .nativeDoboo:
      guard idlePNG == nil else { throw SnapshotError.invalidImage }
    case .spritesheet:
      _ = try idleImage()
    }
    return self
  }

  func idleImage() throws -> CGImage {
    guard let idlePNG else { throw SnapshotError.invalidImage }
    return try Self.decodePNG(idlePNG, width: SpriteFrame.width, height: SpriteFrame.height,
                              limit: Self.maximumPNGBytes)
  }

  func encoded() throws -> Data {
    _ = try validated()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumJSONBytes else { throw SnapshotError.tooLarge }
    return data
  }

  static func decode(_ data: Data) throws -> WatchWidgetSnapshot {
    guard data.count <= maximumJSONBytes else { throw SnapshotError.tooLarge }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }

  private static func decodePNG(_ data: Data, width: Int, height: Int, limit: Int) throws -> CGImage {
    guard data.count <= limit,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetType(source) as String? == "public.png",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyPixelWidth] as? Int == width,
      properties[kCGImagePropertyPixelHeight] as? Int == height,
      let image = CGImageSourceCreateImageAtIndex(source, 0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      CGImageSourceGetStatus(source) == .statusComplete,
      image.width == width, image.height == height
    else { throw SnapshotError.invalidImage }
    return image
  }

  enum SnapshotError: Error { case invalidMetadata, invalidImage, tooLarge, unavailableContainer }
}

struct WatchWidgetSnapshotStore: Sendable {
  let directory: URL?
  static let filename = "selected-character-v1.json"

  static var shared: WatchWidgetSnapshotStore {
    .init(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WatchWidgetSnapshot.appGroup)?
      .appendingPathComponent("Widget", isDirectory: true))
  }

  func load() -> WatchWidgetSnapshot {
    guard let data = try? readBounded(), let snapshot = try? WatchWidgetSnapshot.decode(data) else {
      return .unavailable
    }
    return snapshot
  }

  /// The caller reloads WidgetKit only when the payload actually changes.
  @discardableResult
  func save(_ snapshot: WatchWidgetSnapshot) throws -> Bool {
    let data = try snapshot.encoded()
    guard let directory else { throw WatchWidgetSnapshot.SnapshotError.unavailableContainer }
    if let previous = try? readBounded(), previous == data { return false }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    return true
  }

  private func readBounded() throws -> Data {
    guard let directory else { throw WatchWidgetSnapshot.SnapshotError.unavailableContainer }
    let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(Self.filename))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: WatchWidgetSnapshot.maximumJSONBytes + 1) ?? Data()
    guard data.count <= WatchWidgetSnapshot.maximumJSONBytes else { throw WatchWidgetSnapshot.SnapshotError.tooLarge }
    return data
  }
}
