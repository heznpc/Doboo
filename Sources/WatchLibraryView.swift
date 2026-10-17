import SwiftUI

struct WatchLibraryView: View {
  @Bindable var library: CharacterLibrary
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(library.packs) { pack in
          Button {
            if library.selected.id != pack.id || library.selected.version != pack.version {
              library.select(pack)
            }
            if library.selected.id == pack.id && library.selected.version == pack.version {
              dismiss()
            }
          } label: {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 3) {
                Text(pack.name).font(.headline).lineLimit(2)
                if !pack.description.isEmpty {
                  Text(pack.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              Spacer(minLength: 0)
              if library.selected.id == pack.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.orange)
                  .accessibilityHidden(true)
              }
            }
            .frame(minHeight: 44)
          }
          .accessibilityValue(library.selected.id == pack.id ? Text("library.selected") : Text("library.select"))
          .accessibilityIdentifier("character.select.\(pack.id)")
        }
        Text("library.watchHelp").font(.footnote).foregroundStyle(.secondary)
      }
      .navigationTitle("library.title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }
        }
      }
    }
  }
}
