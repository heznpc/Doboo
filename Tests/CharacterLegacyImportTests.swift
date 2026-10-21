import Foundation
import Testing
#if canImport(Doboo)
@testable import Doboo
#else
@testable import DobooCore
#endif

struct CharacterLegacyImportTests {
  private func personality() -> [String: Any] {
    ["schema": "troupe.personality.v1", "id": "patient-guide", "version": "1.2.3", "name": "Patient guide",
     "perspective": "관찰한 사실을 먼저 살펴봅니다.", "principles": ["사용자의 목적을 유지합니다.", "관찰과 추측을 구분합니다."],
     "workStyle": ["initiative": "정한 범위에서 먼저 시도합니다.", "updates": "바뀐 결과를 짧게 공유합니다.", "recovery": "틀린 점을 인정하고 고칩니다."],
     "examples": [["situation": "실패한 작업을 다시 부탁받았을 때", "response": "실패한 원인을 확인하고 이어서 할 일을 정하겠습니다."]]]
  }

  private func character() -> [String: Any] {
    ["schema": "troupe.character.v1", "id": "mori", "version": "2.1.0",
     "identity": ["name": "Mori", "appearance": "잎 모양의 귀를 가진 둥근 초록색 친구.",
                  "backstory": "숲의 오래된 기록을 정리하던 친구입니다.", "voice": "짧고 차분한 존댓말로 말합니다."],
     "personality": personality()]
  }

  private func innercast() -> [String: Any] {
    var value = personality()
    value["schema"] = "innercast.character.v1"
    value["voice"] = "구체적인 근거를 짧게 설명합니다."
    value.removeValue(forKey: "examples")
    return value
  }

  private func data(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private func report(_ original: [String: Any]) -> [String: Any] {
    ["sourceSchema": original["schema"]!, "sourceId": original["id"]!, "sourceVersion": original["version"]!,
     "targetId": original["id"]!, "targetVersion": 3, "original": original,
     "changes": ["정수 버전은 사용자가 지정했습니다.", "원본 설정은 변환 기록에 남습니다."]]
  }

  @Test func rawCharacterRestoresAllStructuredSettingsWithoutFlattening() throws {
    let source = character()
    let result = try CharacterLegacyImport.convert(data(source), version: 7, creator: "Tester")
    let detail = try #require(result.characterization)
    #expect(result.id == "mori")
    #expect(result.name == "Mori")
    #expect(result.version == 7)
    #expect(result.creator == "Tester")
    #expect(result.description.isEmpty)
    #expect(result.identity.backstory == "숲의 오래된 기록을 정리하던 친구입니다.")
    #expect(result.identity.voice == "짧고 차분한 존댓말로 말합니다.")
    #expect(result.personality.traits.isEmpty)
    #expect(result.personality.instructions.isEmpty)
    #expect(detail.appearanceDescription == "잎 모양의 귀를 가진 둥근 초록색 친구.")
    #expect(detail.perspective == "관찰한 사실을 먼저 살펴봅니다.")
    #expect(detail.principles == ["사용자의 목적을 유지합니다.", "관찰과 추측을 구분합니다."])
    #expect(detail.workStyle == .init(initiative: "정한 범위에서 먼저 시도합니다.", updates: "바뀐 결과를 짧게 공유합니다.", recovery: "틀린 점을 인정하고 고칩니다."))
    #expect(detail.examples == [.init(situation: "실패한 작업을 다시 부탁받았을 때", response: "실패한 원인을 확인하고 이어서 할 일을 정하겠습니다.")])
    #expect(detail.origin == .init(schema: "troupe.character.v1", id: "mori", version: "2.1.0",
      personalityId: "patient-guide", personalityVersion: "1.2.3", personalityName: "Patient guide"))
    #expect(result.appearance.renderer == .nativeDoboo)
    #expect(result.appearance.tint == "#FF8F62")
    #expect(result.appearance.sprite == nil)
    #expect(try CharacterPack.decode(result.encoded()) == result)
  }

  @Test func innercastAndStandalonePersonalityKeepTheirOwnIdentity() throws {
    let inner = try CharacterLegacyImport.convert(data(innercast()), version: 1, creator: "Tester")
    #expect(inner.id == "patient-guide")
    #expect(inner.name == "Patient guide")
    #expect(inner.identity.backstory.isEmpty)
    #expect(inner.identity.voice == "구체적인 근거를 짧게 설명합니다.")
    #expect(inner.characterization?.examples.isEmpty == true)
    #expect(inner.characterization?.origin?.schema == "innercast.character.v1")

    let p = try CharacterLegacyImport.convert(data(personality()), version: 2, creator: "Tester")
    #expect(p.id == "patient-guide")
    #expect(p.identity.voice.isEmpty)
    #expect(p.identity.backstory.isEmpty)
    #expect(p.characterization?.appearanceDescription.isEmpty == true)
    #expect(p.characterization?.examples.count == 1)
    #expect(p.characterization?.origin?.personalityId == nil)
  }

  @Test func migrationReportMatchesRawConversionButUsesCurrentEditorRevision() throws {
    let source = character()
    let expected = try CharacterLegacyImport.convert(data(source), version: 2_147_483_648, creator: "Current editor")
    let result = try CharacterLegacyImport.convert(data(report(source)), version: 2_147_483_648, creator: "Current editor")
    #expect(result == expected)
    #expect(result.version != 3)
    var minimal = report(source)
    minimal.removeValue(forKey: "changes")
    #expect(try CharacterLegacyImport.convert(data(minimal), version: result.version, creator: result.creator) == result)
  }

  @Test func fullLengthAuthoredTextIsPreservedWithoutTruncation() throws {
    let long = String(repeating: "🌱", count: 4000)
    var source = character()
    source["identity"] = ["name": "Mori", "appearance": long, "backstory": long, "voice": long]
    var p = personality()
    p["perspective"] = long
    p["principles"] = Array(repeating: long, count: 16)
    p["workStyle"] = ["initiative": long, "updates": long, "recovery": long]
    p["examples"] = Array(repeating: ["situation": long, "response": long], count: 8)
    source["personality"] = p
    let result = try CharacterLegacyImport.convert(data(report(source)), version: 8, creator: "Tester")
    let detail = try #require(result.characterization)
    #expect(result.identity.backstory == long)
    #expect(result.identity.voice == long)
    #expect(detail.appearanceDescription == long)
    #expect(detail.perspective == long)
    #expect(detail.principles == Array(repeating: long, count: 16))
    #expect(detail.workStyle == .init(initiative: long, updates: long, recovery: long))
    #expect(detail.examples == Array(repeating: .init(situation: long, response: long), count: 8))
    #expect(try CharacterPack.decode(result.encoded()) == result)
  }

  @Test func forgedAndMalformedMigrationMetadataIsRejected() throws {
    let mutations: [(String, Any)] = [
      ("sourceSchema", "innercast.character.v1"), ("sourceId", "someone-else"),
      ("sourceVersion", "9.9.9"), ("targetId", "someone-else"), ("targetVersion", true),
      ("targetVersion", 0), ("targetVersion", 1.5), ("targetVersion", "3"),
      ("targetVersion", 9_007_199_254_740_992 as Int64), ("changes", [false]),
      ("original", NSNull()), ("unexpected", "do not silently discard")
    ]
    for (key, value) in mutations {
      var bad = report(character()); bad[key] = value
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(data(bad), version: 1, creator: "Tester") }
    }
    for key in ["sourceSchema", "sourceId", "sourceVersion", "targetId", "targetVersion", "original"] {
      var missing = report(character()); missing.removeValue(forKey: key)
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(data(missing), version: 1, creator: "Tester") }
    }
  }

  @Test func invalidNestedTypesUnknownFieldsAndLimitsAreRejected() throws {
    var cases: [[String: Any]] = []
    for value: Any in [false, 0, "", [], ["unexpected": "value"]] {
      var source = character(); source["personality"] = value; cases.append(source)
    }
    for (key, value): (String, Any) in [
      ("id", "../outside"), ("id", "mori\n"), ("version", "1.2.3\n"),
      ("version", "١.٢.٣"), ("version", "1.0"), ("version", String(repeating: "1", count: 80) + ".0.0"),
      ("extra", "unrecognized")
    ] {
      var source = character(); source[key] = value; cases.append(source)
    }
    for (key, value): (String, Any) in [
      ("id", "1guide"), ("schema", "innercast.character.v1"), ("version", "1.0.0-beta"),
      ("name", "two\nlines"), ("principles", []), ("principles", Array(repeating: "x", count: 17)),
      ("principles", [String(repeating: "x", count: 4001)]), ("examples", NSNull()),
      ("examples", [["situation": "s", "response": "r", "unknown": true]]),
      ("examples", Array(repeating: ["situation": "s", "response": "r"], count: 9)),
      ("workStyle", ["initiative": "i", "updates": "u"]),
      ("workStyle", ["initiative": "i", "updates": "u", "recovery": "r", "unknown": true])
    ] {
      var source = character(), p = personality(); p[key] = value; source["personality"] = p; cases.append(source)
    }
    var unknownIdentity = character()
    unknownIdentity["identity"] = ["name": "Mori", "appearance": "a", "backstory": "b", "voice": "v", "extra": "x"]
    cases.append(unknownIdentity)
    var invalidControl = innercast(); invalidControl["voice"] = "hello\u{0001}"; cases.append(invalidControl)
    for source in cases {
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(data(source), version: 1, creator: "Tester") }
    }
  }

  @Test func optionalCastPersonalityCanBeAbsentOrNullWithoutInventingSettings() throws {
    var source = character(); source.removeValue(forKey: "personality")
    let missing = try CharacterLegacyImport.convert(data(source), version: 1, creator: "Tester")
    source["personality"] = NSNull()
    #expect(try CharacterLegacyImport.convert(data(source), version: 1, creator: "Tester") == missing)
    #expect(missing.characterization?.principles.isEmpty == true)
    #expect(missing.characterization?.origin?.personalityId == nil)
    #expect(missing.identity.backstory == "숲의 오래된 기록을 정리하던 친구입니다.")
  }

  @Test func inputAndTargetBoundsAreValidatedBeforeConversion() throws {
    #expect(throws: CharacterPackError.jsonTooLarge) {
      try CharacterLegacyImport.convert(Data(repeating: 0, count: CharacterPack.maximumJSONBytes + 1), version: 1, creator: "Tester")
    }
    let invalidSurrogate = Data(#"{"schema":"innercast.character.v1","id":"x","version":"1.0.0","name":"X","perspective":"\ud800","voice":"v","principles":["p"],"workStyle":{"initiative":"i","updates":"u","recovery":"r"}}"#.utf8)
    for bad in [Data("not JSON".utf8), Data("[]".utf8), Data("null".utf8), invalidSurrogate] {
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(bad, version: 1, creator: "Tester") }
    }
    for version: Int64 in [0, -1, 9_007_199_254_740_992] {
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(data(character()), version: version, creator: "Tester") }
    }
    for creator in ["", "\u{FEFF}", "two\nlines", String(repeating: "x", count: 81)] {
      #expect(throws: (any Error).self) { try CharacterLegacyImport.convert(data(character()), version: 1, creator: creator) }
    }
  }
}
