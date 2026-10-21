import Foundation
import CryptoKit

struct CharacterPack: Codable, Equatable, Sendable, Identifiable {
  static let formatName = "doboo.character.v1"
  static let maximumJSONBytes = 32 * 1024 * 1024
  static let maximumImageBytes = 20 * 1024 * 1024

  struct Identity: Codable, Equatable, Sendable {
    var backstory: String
    var voice: String
  }
  struct Personality: Codable, Equatable, Sendable {
    var traits: [String]
    var instructions: [String]
  }
  struct Characterization: Codable, Equatable, Sendable {
    struct WorkStyle: Codable, Equatable, Sendable {
      var initiative: String = ""
      var updates: String = ""
      var recovery: String = ""
    }
    struct Example: Codable, Equatable, Sendable {
      var situation: String
      var response: String
    }
    struct Origin: Codable, Equatable, Sendable {
      var schema: String
      var id: String
      var version: String
      var personalityId: String? = nil
      var personalityVersion: String? = nil
      var personalityName: String? = nil
    }
    var appearanceDescription: String = ""
    var perspective: String = ""
    var principles: [String] = []
    var workStyle: WorkStyle = .init()
    var examples: [Example] = []
    // Provenance remains the source of the import after editing, not a claim
    // that the current settings still exactly match that source revision.
    var origin: Origin? = nil
  }
  struct Appearance: Codable, Equatable, Sendable {
    enum Renderer: String, Codable, Sendable { case nativeDoboo = "native-doboo", spritesheet }
    struct Sprite: Codable, Equatable, Sendable {
      enum Layout: String, Codable, Sendable {
        case petsV1 = "pets-v1", petsV2 = "pets-v2"
        var rows: Int { self == .petsV1 ? 9 : 11 }
        var pixelHeight: Int { rows * 208 }
      }
      var layout: Layout
      var mimeType: String
      var base64: String
    }
    struct Watch: Codable, Equatable, Sendable {
      var renderer: Renderer
      var tint: String
      var sprite: Sprite?
    }
    var watch: Watch? = nil
    var renderer: Renderer
    var tint: String
    var sprite: Sprite?
  }

  var format: String
  var id: String
  // Watch arm64_32 uses a 32-bit Int. The interchange format allows every
  // JavaScript-safe integer, so revisions need a fixed-width representation.
  var version: Int64
  var name: String
  var description: String
  var creator: String
  var identity: Identity
  var personality: Personality
  var appearance: Appearance
  var characterization: Characterization? = nil

  var spriteData: Data? {
    appearance.sprite.flatMap { Data(base64Encoded: $0.base64) }
  }

  /// Same identity/revision; a host-specific representation, not a new character.
  var watchRepresentation: CharacterPack {
    guard let watch = appearance.watch else { return self }
    var copy = self
    copy.appearance = .init(renderer: watch.renderer, tint: watch.tint, sprite: watch.sprite)
    return copy
  }

  var definitionSHA256: String {
    get throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(self)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  static let builtin = CharacterPack(
    format: formatName, id: "doboo", version: 1, name: "Doboo",
    description: "손목에서는 말랑하게, 작업할 때는 차분하게 곁에 있는 두부.", creator: "Heznpc",
    identity: .init(backstory: "복숭아빛 작은 생물 두부는 책상과 손목 사이를 오가며 친구의 하루를 함께합니다. 눌리면 잠깐 찡그렸다가 다시 둥글게 돌아옵니다. 이 설정은 Doboo의 기본 예제 캐릭터입니다.", voice: "한국어 존댓말로 짧고 따뜻하게 말합니다. 과장된 칭찬보다 구체적인 도움을 건넵니다."),
    personality: .init(traits: ["온화함", "호기심", "끈기"], instructions: ["맡은 일의 목적과 사용자가 정한 범위를 유지합니다.", "필수 정보가 비어 있으면 그 정보를 구체적으로 묻고, 이미 할 수 있는 부분은 진행합니다.", "확인한 사실과 추측을 구분하고, 실제로 하지 않은 일을 했다고 말하지 않습니다.", "다른 캐릭터와 함께 일할 때는 맡은 부분과 결과를 간결하게 전달합니다."]),
    appearance: .init(renderer: .nativeDoboo, tint: "#FF8F62")
  )

  static func decode(_ data: Data) throws -> CharacterPack {
    guard data.count <= maximumJSONBytes else { throw CharacterPackError.jsonTooLarge }
    let pack: CharacterPack
    do {
      try validateKeys(JSONSerialization.jsonObject(with: data))
      pack = try JSONDecoder().decode(Self.self, from: data)
    }
    catch { throw CharacterPackError.invalidJSON }
    return try pack.validated()
  }

  private static func validateKeys(_ raw: Any) throws {
    func object(_ value: Any?, allowed: Set<String>) throws -> [String: Any] {
      guard let value = value as? [String: Any], Set(value.keys).isSubset(of: allowed) else {
        throw CharacterPackError.invalidJSON
      }
      return value
    }
    let root = try object(raw, allowed: ["format", "id", "version", "name", "description", "creator", "identity", "personality", "appearance", "characterization"])
    _ = try object(root["identity"], allowed: ["backstory", "voice"])
    _ = try object(root["personality"], allowed: ["traits", "instructions"])
    if let characterization = root["characterization"] {
      let value = try object(characterization, allowed: ["appearanceDescription", "perspective", "principles", "workStyle", "examples", "origin"])
      _ = try object(value["workStyle"], allowed: ["initiative", "updates", "recovery"])
      guard let examples = value["examples"] as? [Any] else { throw CharacterPackError.invalidJSON }
      for example in examples { _ = try object(example, allowed: ["situation", "response"]) }
      if let origin = value["origin"] {
        let source = try object(origin, allowed: ["schema", "id", "version", "personalityId", "personalityVersion", "personalityName"])
        for key in ["personalityId", "personalityVersion", "personalityName"] where source[key] != nil {
          guard source[key] is String else { throw CharacterPackError.invalidJSON }
        }
      }
    }
    let appearance = try object(root["appearance"], allowed: ["renderer", "tint", "sprite", "watch"])
    if let watch = appearance["watch"] {
      let value = try object(watch, allowed: ["renderer", "tint", "sprite"])
      if let sprite = value["sprite"] { _ = try object(sprite, allowed: ["layout", "mimeType", "base64"]) }
    }
    if let sprite = appearance["sprite"] {
      _ = try object(sprite, allowed: ["layout", "mimeType", "base64"])
    }
  }

  func encoded() throws -> Data {
    _ = try validated()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumJSONBytes else { throw CharacterPackError.jsonTooLarge }
    return data
  }

  @discardableResult
  func validated() throws -> CharacterPack {
    guard format == Self.formatName else { throw CharacterPackError.invalidField("format") }
    guard (1...64).contains(id.utf8.count), id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
      throw CharacterPackError.invalidField("id")
    }
    guard version >= 1, version <= 9_007_199_254_740_991 else { throw CharacterPackError.invalidField("version") }
    try Self.text(name, field: "name", limit: 80, required: true)
    try Self.text(description, field: "description", limit: 500)
    try Self.text(creator, field: "creator", limit: 80, required: true)
    let lineBreaks: Set<UInt32> = [9, 10, 13, 0x85, 0x2028, 0x2029]
    guard !name.unicodeScalars.contains(where: { lineBreaks.contains($0.value) }),
      !creator.unicodeScalars.contains(where: { lineBreaks.contains($0.value) }) else {
      throw CharacterPackError.invalidField("name / creator")
    }
    try Self.text(identity.backstory, field: "identity.backstory", limit: 4000)
    try Self.text(identity.voice, field: "identity.voice", limit: 4000)
    guard personality.traits.count <= 20, personality.instructions.count <= 30 else {
      throw CharacterPackError.invalidField("personality")
    }
    for value in personality.traits { try Self.text(value, field: "traits", limit: 160, required: true) }
    for value in personality.instructions { try Self.text(value, field: "instructions", limit: 500, required: true) }
    if let detail = characterization {
      try Self.text(detail.appearanceDescription, field: "characterization.appearanceDescription", limit: 4000)
      try Self.text(detail.perspective, field: "characterization.perspective", limit: 4000)
      guard detail.principles.count <= 16, detail.examples.count <= 8 else {
        throw CharacterPackError.invalidField("characterization")
      }
      for value in detail.principles { try Self.text(value, field: "characterization.principles", limit: 4000, required: true) }
      try Self.text(detail.workStyle.initiative, field: "characterization.workStyle.initiative", limit: 4000)
      try Self.text(detail.workStyle.updates, field: "characterization.workStyle.updates", limit: 4000)
      try Self.text(detail.workStyle.recovery, field: "characterization.workStyle.recovery", limit: 4000)
      for example in detail.examples {
        try Self.text(example.situation, field: "characterization.examples.situation", limit: 4000, required: true)
        try Self.text(example.response, field: "characterization.examples.response", limit: 4000, required: true)
      }
      if let origin = detail.origin {
        func sourceID(_ value: String) -> Bool {
          (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
        func sourceVersion(_ value: String) -> Bool {
          value.utf8.count <= 80 && value.range(of: "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil
        }
        guard ["innercast.character.v1", "troupe.character.v1", "troupe.personality.v1"].contains(origin.schema),
          sourceID(origin.id), sourceVersion(origin.version),
          origin.personalityId.map(sourceID) ?? true, origin.personalityVersion.map(sourceVersion) ?? true else {
          throw CharacterPackError.invalidField("characterization.origin")
        }
        if let value = origin.personalityName {
          try Self.text(value, field: "characterization.origin.personalityName", limit: 80, required: true)
          guard !value.unicodeScalars.contains(where: { lineBreaks.contains($0.value) }) else {
            throw CharacterPackError.invalidField("characterization.origin.personalityName")
          }
        }
      }
    }
    let tint = appearance.tint
    guard tint.utf8.count == 7, tint.first == "#", tint.dropFirst().allSatisfy(\.isHexDigit), tint.unicodeScalars.allSatisfy(\.isASCII) else {
      throw CharacterPackError.invalidField("appearance.tint")
    }
    switch appearance.renderer {
    case .nativeDoboo:
      guard appearance.sprite == nil else { throw CharacterPackError.invalidField("appearance.sprite") }
    case .spritesheet:
      guard let sprite = appearance.sprite, sprite.mimeType == "image/png",
        sprite.base64.utf8.count <= ((Self.maximumImageBytes + 2) / 3) * 4,
        let data = Data(base64Encoded: sprite.base64), data.count <= Self.maximumImageBytes
      else { throw CharacterPackError.invalidImage }
      let dimensions = try PNGDimensions(data: data)
      guard dimensions.width == 1536, dimensions.height == sprite.layout.pixelHeight else {
        throw CharacterPackError.invalidImageDimensions
      }
    }
    if appearance.watch != nil { _ = try watchRepresentation.validated() }
    return self
  }

  private static func text(_ value: String, field: String, limit: Int, required: Bool = false) throws {
    // Unicode scalar count matches the browser contract's code-point limits.
    // ECMAScript trim differs from Foundation for U+0085 and U+FEFF; identical
    // imported text must pass or fail on both the browser and native hosts.
    let trimScalars: Set<UInt32> = [9, 10, 11, 12, 13, 32, 0xA0, 0x1680,
      0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
      0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    guard value.unicodeScalars.count <= limit,
      !required || value.unicodeScalars.contains(where: { !trimScalars.contains($0.value) }),
      !value.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) || $0.value == 127 })
    else { throw CharacterPackError.invalidField(field) }
  }


}

struct PNGDimensions: Equatable, Sendable {
  let width: Int
  let height: Int

  init(data: Data) throws {
    let bytes = [UInt8](data.prefix(33))
    guard bytes.count == 33,
      Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
      Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82]
    else { throw CharacterPackError.invalidImage }
    func number(_ start: Int) -> Int {
      bytes[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    width = number(16)
    height = number(20)
    guard width > 0, height > 0, bytes[26] == 0, bytes[27] == 0, bytes[28] <= 1 else {
      throw CharacterPackError.invalidImage
    }
  }
}

enum CharacterPackError: Error, LocalizedError, Equatable {
  case invalidJSON, jsonTooLarge, invalidImage, invalidImageDimensions
  case invalidField(String), conflictingVersion, missingCharacter, storageUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidJSON: "This file is not a valid Doboo character pack."
    case .jsonTooLarge: "Choose a character file no larger than 32 MiB."
    case .invalidImage: "The character must contain a valid PNG sprite sheet no larger than 20 MiB."
    case .invalidImageDimensions: "The sprite sheet size does not match its Pets layout."
    case .invalidField(let field): "The character has an invalid \(field) field."
    case .conflictingVersion: "A different version of this character is already saved. Import a higher version to replace it."
    case .missingCharacter: "This character is no longer in the library."
    case .storageUnavailable: "The character library could not be opened. Your saved files have been kept."
    }
  }
}
