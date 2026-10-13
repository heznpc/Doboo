import SwiftUI

struct WatchLibraryView: View {
  @Bindable var library: CharacterLibrary
  var body: some View {
    NavigationStack {
      List {
        ForEach(library.packs) { pack in
          NavigationLink {
            WatchCharacterDetail(pack: pack, library: library)
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(pack.name).font(.headline)
                Text(pack.personality.traits.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
              }
              if library.selected.id == pack.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
            }
          }
        }
        Text("library.watchHelp").font(.footnote).foregroundStyle(.secondary)
      }
      .navigationTitle("library.title")
    }
  }
}

private struct WatchCharacterDetail: View {
  let pack: CharacterPack
  @Bindable var library: CharacterLibrary
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        PackCharacterView(pack: pack, interaction: .init(), phase: 0, motionEnabled: false)
          .frame(height: 110).frame(maxWidth: .infinity)
        Text(pack.name).font(.headline)
        Text(pack.description).font(.caption)
        Text(verbatim: "\(pack.id) · v\(pack.version)").font(.caption2).foregroundStyle(.secondary)
        Button(library.selected.id == pack.id ? "library.selected" : "library.select") {
          library.select(pack)
        }.buttonStyle(.borderedProminent)
        Text("character.personality").font(.headline)
        Text(pack.personality.traits.joined(separator: " · ")).font(.caption)
        Text(pack.identity.voice).font(.caption)
        ForEach(Array(pack.personality.instructions.enumerated()), id: \.offset) { _, instruction in
          Text(instruction).font(.caption2).foregroundStyle(.secondary)
        }
      }.padding(.horizontal)
    }.navigationTitle(pack.name)
  }
}
