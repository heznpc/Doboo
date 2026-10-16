import Foundation
import CoreGraphics
import ImageIO

/// A host-only executable keeps shared storage/image regression checks independent
/// of a running Simulator, signing account, or physical Watch.
@main
struct WatchWidgetSnapshotTests {
  static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
  }

  struct Failure: Error { let message: String }

  static func sheet() throws -> Data {
    guard let context = CGContext(data: nil, width: 1536, height: 2288, bitsPerComponent: 8,
      bytesPerRow: 1536 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw Failure(message: "Could not create the test sprite sheet")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1536, height: 2288))
    // The CGContext origin is bottom-left; encode green at PNG row zero.
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 2288 - 208, width: 192, height: 208))
    guard let image = context.makeImage() else { throw Failure(message: "No test image") }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
      throw Failure(message: "No PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "Could not encode test PNG")
    return bytes as Data
  }

  static func main() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doboo-widget-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WatchWidgetSnapshotStore(directory: directory)
    try require(store.load() == .unavailable, "Missing snapshots must use an explicit fallback")

    var pack = CharacterPack.builtin
    pack.id = "native-test"
    pack.name = "Selected Friend"
    pack.version = 9_007_199_254_740_991
    pack.appearance.watch = .init(renderer: .nativeDoboo, tint: "#123456")
    let native = try WatchWidgetSnapshot.make(for: pack)
    try require(native.characterID == pack.id && native.characterVersion == pack.version && native.name == pack.name,
                "Selected identity and 64-bit revision must be preserved")
    try require(native.tint == "#123456", "Watch representation tint must override the base tint")
    try require(try store.save(native), "First publication must request a timeline reload")
    try require(store.load() == native, "Native metadata must round-trip through storage")
    try require(try !store.save(native), "Unchanged payload must not write or request another reload")

    let png = try sheet()
    pack.appearance.watch = .init(renderer: .spritesheet, tint: "#654321",
      sprite: .init(layout: .petsV2, mimeType: "image/png", base64: png.base64EncodedString()))
    let sprite = try WatchWidgetSnapshot.make(for: pack)
    let firstFrame = try sprite.idleImage()
    try require(firstFrame.width == 192 && firstFrame.height == 208, "Only one idle frame may be published")
    let pixels = try pixel(firstFrame)
    try require(pixels[0] < 5 && pixels[1] > 240 && pixels[2] < 5 && pixels[3] > 250,
                "The snapshot must use the top-left idle frame; pixel = \(pixels)")
    try require(try store.save(sprite) && store.load() == sprite, "A renderer change must replace metadata and image together")

    try require(CommandLine.arguments.count == 2, "Run this regression suite through Widgets/Tests/run.py")
    let sixteenBitPNG = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let source = CGImageSourceCreateWithData(sixteenBitPNG as CFData, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw Failure(message: "The 16-bit fixture must be a decodable PNG")
    }
    try require(sourceImage.bitsPerComponent == 16, "The regression input must retain its 16-bit channels")
    var deepPack = pack
    deepPack.appearance.watch?.sprite?.base64 = sixteenBitPNG.base64EncodedString()
    _ = try deepPack.validated()
    let normalized = try WatchWidgetSnapshot.make(for: deepPack)
    let normalizedFrame = try normalized.idleImage()
    try require(!normalized.needsSync && normalized.characterID == pack.id,
                "A valid 16-bit character must not fall back to the builtin")
    try require(normalizedFrame.bitsPerComponent == 8 && normalizedFrame.width == 192 && normalizedFrame.height == 208,
                "High-depth PNGs must normalize to an 8-bit frame without reducing its dimensions")
    try require((normalized.idlePNG?.count ?? .max) <= WatchWidgetSnapshot.maximumPNGBytes,
                "High-entropy 16-bit frames must stay within the snapshot budget")
    let red = try pixel(normalizedFrame, x: 0, y: 0)
    let green = try pixel(normalizedFrame, x: 1, y: 0)
    let clear = try pixel(normalizedFrame, x: 2, y: 0)
    try require(red[0] > 240 && red[1] < 45 && red[2] < 5 && red[3] > 250,
                "Normalization must preserve the opaque red pixel")
    try require(green[1] > 110 && (125...130).contains(green[3]) && clear[3] == 0,
                "Normalization must preserve partial and full transparency")
    try require(try store.save(normalized) && store.load() == normalized,
                "Normalized frames must round-trip through the bounded snapshot store")
    try store.save(sprite)

    var broken = sprite
    broken.idlePNG = Data(png.prefix(33))
    do {
      _ = try store.save(broken)
      throw Failure(message: "Invalid image was accepted")
    } catch is WatchWidgetSnapshot.SnapshotError {}
    try require(store.load() == sprite, "Failed validation must preserve the previously complete snapshot")

    let file = directory.appendingPathComponent(WatchWidgetSnapshotStore.filename)
    try JSONEncoder().encode(broken).write(to: file, options: .atomic)
    try require(store.load() == .unavailable, "A corrupt image must not retain the selected character's label")
    broken = native
    broken.schemaVersion = 99
    try JSONEncoder().encode(broken).write(to: file, options: .atomic)
    try require(store.load() == .unavailable, "Unknown snapshot versions must fall back")
    try Data(repeating: 0, count: WatchWidgetSnapshot.maximumJSONBytes + 1).write(to: file, options: .atomic)
    try require(store.load() == .unavailable, "Unbounded snapshot input must be rejected")

    pack.appearance.watch?.sprite?.base64 = Data(png.prefix(33)).base64EncodedString()
    do {
      _ = try WatchWidgetSnapshot.make(for: pack)
      throw Failure(message: "A PNG header without a decoded image was accepted")
    } catch is WatchWidgetSnapshot.SnapshotError {}

    try store.save(native)
    let allConsistent = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      for index in 0..<4 {
        group.addTask {
          for _ in 0..<80 {
            if index < 2 {
              do { try store.save(index == 0 ? native : sprite) } catch { return false }
            } else {
              let current = store.load()
              if current != native && current != sprite { return false }
            }
          }
          return true
        }
      }
      var passed = true
      for await result in group { passed = passed && result }
      return passed
    }
    try require(allConsistent, "Concurrent readers must only see complete revisions")
    try require(WatchWidgetSnapshotStore(directory: nil).load() == .unavailable,
                "An unavailable App Group must fail to the builtin snapshot")
    print("Watch widget snapshot regressions passed (metadata, idle crop, 16-bit normalization, bounds, fallback, atomic reads).")
  }

  static func pixel(_ image: CGImage, x: Int? = nil, y: Int? = nil) throws -> [UInt8] {
    guard let sample = image.cropping(to: CGRect(x: x ?? image.width / 2, y: y ?? image.height / 2, width: 1, height: 1)) else {
      throw Failure(message: "No pixel at the requested coordinate")
    }
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure(message: "No pixel reader")
      }
      context.interpolationQuality = .none
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
  }
}
