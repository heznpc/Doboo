import SwiftUI

/// Shows the authored character, including imported creative settings, without
/// confusing its source revision with the editable Doboo revision.
struct CharacterSettingsView: View {
  let pack: CharacterPack

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("character.settings").font(.title2.bold())
      CharacterOriginView(origin: pack.characterization?.origin)
      CharacterSettingsCard(title: "character.identity", symbol: "book", identifier: "identity") {
        setting("character.appearanceDescription", value: pack.characterization?.appearanceDescription ?? "", field: "appearance")
        setting("editor.story", value: pack.identity.backstory, field: "backstory")
        setting("editor.voice", value: pack.identity.voice, field: "voice")
      }
      CharacterSettingsCard(title: "character.personality", symbol: "person.text.rectangle", identifier: "personality") {
        setting("editor.traits", value: pack.personality.traits.joined(separator: " · "), field: "traits")
        setting("character.perspective", value: pack.characterization?.perspective ?? "", field: "perspective")
        setting("character.principles", value: (pack.characterization?.principles ?? []).map { "• \($0)" }.joined(separator: "\n"), field: "principles")
      }
      CharacterSettingsCard(title: "character.workStyle", symbol: "hand.draw", identifier: "workStyle") {
        setting("character.initiative", value: pack.characterization?.workStyle.initiative ?? "", field: "workStyle.initiative")
        setting("character.updates", value: pack.characterization?.workStyle.updates ?? "", field: "workStyle.updates")
        setting("character.recovery", value: pack.characterization?.workStyle.recovery ?? "", field: "workStyle.recovery")
      }
      CharacterSettingsCard(title: "character.examples", symbol: "quote.bubble", identifier: "examples") {
        if let examples = pack.characterization?.examples, !examples.isEmpty {
          ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
            setting("character.situation", value: example.situation, field: "examples[\(index)].situation")
            setting("character.response", value: example.response, field: "examples[\(index)].response")
            if index < examples.count - 1 { Divider() }
          }
        } else { Text("character.notSet").foregroundStyle(.secondary) }
      }
      if !pack.personality.instructions.isEmpty {
        CharacterSettingsCard(title: "character.otherInstructions", symbol: "list.bullet", identifier: "instructions") {
          Text(pack.personality.instructions.map { "• \($0)" }.joined(separator: "\n"))
            .textSelection(.enabled)
        }
      }
    }
  }

  private func originalField(_ field: String) -> String? {
    guard let origin = pack.characterization?.origin, field != "traits" else { return nil }
    if origin.schema == "troupe.character.v1" {
      if ["appearance", "backstory", "voice"].contains(field) { return "identity." + field }
      return origin.personalityId == nil ? nil : "personality." + field
    }
    if origin.schema == "innercast.character.v1", field.hasPrefix("examples[") { return nil }
    if ["appearance", "backstory"].contains(field) { return nil }
    if origin.schema == "troupe.personality.v1", field == "voice" { return nil }
    return field
  }

  private func setting(_ title: LocalizedStringKey, value: String, field: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline.weight(.semibold))
      if let sourceField = originalField(field) {
        Text(sourceField).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      if value.isEmpty { Text("character.notSet").foregroundStyle(.secondary) }
      else { Text(value).textSelection(.enabled) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CharacterSettingsCard<Content: View>: View {
  let title: LocalizedStringKey
  let symbol: String
  let identifier: String
  @ViewBuilder var content: () -> Content
  @State private var expanded = true

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 16, content: content)
        .font(.body).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label(title, systemImage: symbol).font(.headline)
    }
    .padding(16)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("character.settings.\(identifier)")
  }
}

struct CharacterOriginView: View {
  let origin: CharacterPack.Characterization.Origin?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let origin {
        Label(origin.schema.hasPrefix("troupe.") ? "Troupe" : "Innercast", systemImage: "square.stack.3d.up")
          .font(.headline).accessibilityIdentifier("character.origin")
        Text("\(origin.id) · \(origin.version)").font(.subheadline).textSelection(.enabled)
        let personality = [origin.personalityName, origin.personalityId, origin.personalityVersion].compactMap { $0 }.filter { !$0.isEmpty }
        if !personality.isEmpty {
          Text(personality.joined(separator: " · "))
            .font(.subheadline).textSelection(.enabled)
        }
        Text(origin.schema).font(.caption.monospaced()).foregroundStyle(.secondary)
        Text("character.sourceHelp").font(.footnote).foregroundStyle(.secondary)
      } else {
        Text("character.noSource").font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}
