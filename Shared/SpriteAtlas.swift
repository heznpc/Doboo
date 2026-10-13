import SwiftUI
import ImageIO

/// Decode once per selected pack. Each frame is a view of a validated PNG image;
/// the animation loop never decodes file bytes or reads disk.
@MainActor
final class SpriteAtlas {
  let image: CGImage
  let layout: CharacterPack.Appearance.Sprite.Layout
  private var frames: [Int: CGImage] = [:]

  init(pack: CharacterPack) throws {
    guard let sprite = pack.appearance.sprite, let data = pack.spriteData,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetType(source) as String? == "public.png",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyPixelWidth] as? Int == 1536,
      properties[kCGImagePropertyPixelHeight] as? Int == sprite.layout.pixelHeight,
      let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      CGImageSourceGetStatus(source) == .statusComplete,
      decoded.width == 1536, decoded.height == sprite.layout.pixelHeight
    else { throw CharacterPackError.invalidImage }
    image = decoded
    layout = sprite.layout
    for row in 0..<layout.rows {
      for column in 0..<8 {
        let rect = CGRect(x: column * SpriteFrame.width, y: row * SpriteFrame.height,
                          width: SpriteFrame.width, height: SpriteFrame.height)
        guard let frame = decoded.cropping(to: rect) else { throw CharacterPackError.invalidImage }
        frames[row * 8 + column] = frame
      }
    }
  }

  func image(for frame: SpriteFrame) -> CGImage? { frames[frame.row * 8 + frame.column] }

  static func validate(_ pack: CharacterPack) throws {
    if pack.appearance.renderer == .spritesheet { _ = try SpriteAtlas(pack: pack) }
    if pack.appearance.watch != nil, pack.watchRepresentation.appearance.renderer == .spritesheet {
      _ = try SpriteAtlas(pack: pack.watchRepresentation)
    }
  }
}

struct PackCharacterView: View {
  let pack: CharacterPack
  let interaction: BlobInteractionState
  let phase: TimeInterval
  let motionEnabled: Bool
  var taskStatus: String? = nil
  @State private var atlas: SpriteAtlas?
  @State private var failed = false

  var body: some View {
    Group {
      if pack.appearance.renderer == .nativeDoboo {
        DobooCharacterView(interaction: interaction, recoil: 0, phase: phase,
                           motionEnabled: motionEnabled, tint: Color(hex: pack.appearance.tint))
      } else if let atlas {
        let frame = SpriteFrame.frame(layout: atlas.layout, elapsed: phase,
          touchX: interaction.touch.x, touchY: interaction.touch.y,
          pressed: interaction.isPressed, motionEnabled: motionEnabled, taskStatus: taskStatus)
        if let image = atlas.image(for: frame) {
          Image(decorative: image, scale: 1)
            .resizable().interpolation(.high).scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .scaleEffect(x: interaction.isPressed ? 1.04 : 1,
                         y: interaction.isPressed ? 0.94 : 1)
            .offset(x: interaction.touch.x * interaction.intensity * 5,
                    y: interaction.touch.y * interaction.intensity * 4)
            .animation(motionEnabled ? .spring(response: 0.4, dampingFraction: 0.6) : nil,
                       value: interaction)
        }
      } else if failed {
        Label("library.imageError", systemImage: "exclamationmark.triangle")
          .font(.caption)
      } else {
        ProgressView()
      }
    }
    .task(id: "\(pack.id)@\(pack.version)") {
      atlas = nil
      failed = false
      guard pack.appearance.renderer == .spritesheet else { return }
      do { atlas = try SpriteAtlas(pack: pack) }
      catch { failed = true }
    }
    .accessibilityHidden(true)
  }
}

extension Color {
  init(hex: String) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFF8B68
    self.init(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
  }
}
