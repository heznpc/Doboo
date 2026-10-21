import Foundation
import CoreFoundation

/// Restores an authored legacy definition into an editor draft. It never installs
/// files or treats source text as executable instructions.
enum CharacterLegacyImport {
  private static let schemas: Set<String> = [
    "troupe.character.v1", "troupe.personality.v1", "innercast.character.v1"
  ]

  static func convert(_ data: Data, version: Int64, creator: String) throws -> CharacterPack {
    guard data.count <= CharacterPack.maximumJSONBytes else { throw CharacterPackError.jsonTooLarge }
    guard (1...9_007_199_254_740_991).contains(version) else {
      throw CharacterPackError.invalidField("version")
    }
    try text(creator, limit: 80, field: "creator", required: true, singleLine: true)
    let decoded: Any
    do { decoded = try JSONSerialization.jsonObject(with: data) }
    catch { throw CharacterPackError.invalidJSON }
    guard let container = decoded as? [String: Any] else { throw CharacterPackError.invalidJSON }
    let source = try unwrapReport(container)
    let schema = try string(source["schema"], limit: 80, field: "schema", required: true)
    guard schemas.contains(schema) else { throw CharacterPackError.invalidField("schema") }
    let cast = schema == "troupe.character.v1"
    let innercast = schema == "innercast.character.v1"
    let allowed: Set<String> = cast
      ? ["schema", "id", "version", "identity", "personality"]
      : innercast
        ? ["schema", "id", "version", "name", "perspective", "voice", "principles", "workStyle"]
        : ["schema", "id", "version", "name", "perspective", "principles", "workStyle", "examples"]
    _ = try object(source, keys: allowed, field: "source")
    let id = try identifier(source["id"], field: "id")
    let originalVersion = try semver(source["version"], field: "version")
    var name: String
    var backstory = "", voice = "", appearanceDescription = ""
    if cast {
      let identity = try object(source["identity"], keys: ["name", "appearance", "backstory", "voice"], field: "identity")
      name = try string(identity["name"], limit: 4000, field: "identity.name", required: true)
      appearanceDescription = try string(identity["appearance"], limit: 4000, field: "identity.appearance", required: true)
      backstory = try string(identity["backstory"], limit: 4000, field: "identity.backstory", required: true)
      voice = try string(identity["voice"], limit: 4000, field: "identity.voice", required: true)
    } else {
      name = try string(source["name"], limit: 80, field: "name", required: true)
      if innercast { voice = try string(source["voice"], limit: 4000, field: "voice", required: true) }
    }
    var detail = CharacterPack.Characterization(appearanceDescription: appearanceDescription)
    var origin = CharacterPack.Characterization.Origin(schema: schema, id: id, version: originalVersion)
    let personality: [String: Any]?
    if cast {
      if let value = source["personality"], !(value is NSNull) {
        personality = try object(value, keys: ["schema", "id", "version", "name", "perspective", "principles", "workStyle", "examples"], field: "personality")
      } else { personality = nil }
    } else { personality = source }
    if let personality {
      let personalityName = try string(personality["name"], limit: 80, field: "personality.name", required: true)
      if cast {
        guard personality["schema"] as? String == "troupe.personality.v1" else {
          throw CharacterPackError.invalidField("personality.schema")
        }
        origin.personalityId = try identifier(personality["id"], field: "personality.id", startsWithLetter: true)
        origin.personalityVersion = try semver(personality["version"], field: "personality.version")
        origin.personalityName = personalityName
      }
      detail.perspective = try string(personality["perspective"], limit: 4000, field: "perspective", required: true)
      detail.principles = try list(personality["principles"], count: 16, field: "principles", nonempty: true)
      let workStyle = try object(personality["workStyle"], keys: ["initiative", "updates", "recovery"], field: "workStyle")
      detail.workStyle = .init(
        initiative: try string(workStyle["initiative"], limit: 4000, field: "workStyle.initiative", required: true),
        updates: try string(workStyle["updates"], limit: 4000, field: "workStyle.updates", required: true),
        recovery: try string(workStyle["recovery"], limit: 4000, field: "workStyle.recovery", required: true))
      if let value = personality["examples"] {
        guard let examples = value as? [Any], examples.count <= 8 else {
          throw CharacterPackError.invalidField("examples")
        }
        detail.examples = try examples.map { value in
          let example = try object(value, keys: ["situation", "response"], field: "example")
          return .init(
            situation: try string(example["situation"], limit: 4000, field: "example.situation", required: true),
            response: try string(example["response"], limit: 4000, field: "example.response", required: true))
        }
      }
    }
    detail.origin = origin
    var result = CharacterPack(format: CharacterPack.formatName, id: id, version: version,
      name: name, description: "", creator: creator, identity: .init(backstory: backstory, voice: voice),
      personality: .init(traits: [], instructions: []), appearance: .init(renderer: .nativeDoboo, tint: "#FF8F62"))
    result.characterization = detail
    return try result.validated()
  }

  private static func unwrapReport(_ container: [String: Any]) throws -> [String: Any] {
    guard container["original"] != nil || container["sourceSchema"] != nil else { return container }
    let report = try object(container, keys: ["sourceSchema", "sourceId", "sourceVersion", "targetId", "targetVersion", "original", "changes"], field: "migration")
    guard let original = report["original"] as? [String: Any],
      let schema = report["sourceSchema"] as? String, schemas.contains(schema),
      schema == original["schema"] as? String else { throw CharacterPackError.invalidField("migration.sourceSchema") }
    let sourceID = try identifier(report["sourceId"], field: "migration.sourceId")
    let sourceVersion = try semver(report["sourceVersion"], field: "migration.sourceVersion")
    let targetID = try identifier(report["targetId"], field: "migration.targetId")
    guard sourceID == original["id"] as? String, sourceVersion == original["version"] as? String,
      targetID == sourceID else { throw CharacterPackError.invalidField("migration.identity") }
    guard let targetVersion = report["targetVersion"] as? NSNumber,
      CFGetTypeID(targetVersion) != CFBooleanGetTypeID(), targetVersion.doubleValue.isFinite,
      targetVersion.doubleValue.rounded(.towardZero) == targetVersion.doubleValue,
      targetVersion.doubleValue >= 1, targetVersion.doubleValue <= 9_007_199_254_740_991 else {
      throw CharacterPackError.invalidField("migration.targetVersion")
    }
    if let changes = report["changes"] {
      _ = try list(changes, count: 32, field: "migration.changes", nonempty: false)
    }
    return original
  }

  private static func object(_ value: Any?, keys: Set<String>, field: String) throws -> [String: Any] {
    guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
      throw CharacterPackError.invalidField(field)
    }
    return object
  }

  private static func string(_ value: Any?, limit: Int, field: String, required: Bool = false) throws -> String {
    guard let value = value as? String else { throw CharacterPackError.invalidField(field) }
    try text(value, limit: limit, field: field, required: required)
    return value
  }

  private static func text(_ value: String, limit: Int, field: String, required: Bool = false, singleLine: Bool = false) throws {
    let lineBreaks: Set<UInt32> = [9, 10, 13, 0x85, 0x2028, 0x2029]
    // ECMAScript String.trim uses this set, which differs from Foundation for
    // U+0085 and U+FEFF. Keep required-text decisions identical to the JS importer.
    let trimScalars: Set<UInt32> = [9, 10, 11, 12, 13, 32, 0xA0, 0x1680,
      0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
      0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    guard value.unicodeScalars.count <= limit,
      !required || value.unicodeScalars.contains(where: { !trimScalars.contains($0.value) }),
      !value.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) || $0.value == 127 }),
      !singleLine || !value.unicodeScalars.contains(where: { lineBreaks.contains($0.value) }) else {
      throw CharacterPackError.invalidField(field)
    }
  }

  private static func identifier(_ value: Any?, field: String, startsWithLetter: Bool = false) throws -> String {
    guard let value = value as? String, (1...64).contains(value.utf8.count),
      value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
      !startsWithLetter || value.utf8.first.map({ (97...122).contains($0) }) == true else {
      throw CharacterPackError.invalidField(field)
    }
    return value
  }

  private static func semver(_ value: Any?, field: String) throws -> String {
    guard let value = value as? String, value.utf8.count <= 80 else { throw CharacterPackError.invalidField(field) }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else {
      throw CharacterPackError.invalidField(field)
    }
    return value
  }

  private static func list(_ value: Any?, count: Int, field: String, nonempty: Bool) throws -> [String] {
    guard let values = value as? [Any], values.count <= count, !nonempty || !values.isEmpty else {
      throw CharacterPackError.invalidField(field)
    }
    return try values.map { try string($0, limit: 4000, field: field, required: true) }
  }
}
