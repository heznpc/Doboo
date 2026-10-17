import SwiftUI

struct DobooMenuView: View {
  let name: String
  let widgetSyncError: String?
  let onPlacement: () -> Void
  let onCharacters: () -> Void
  let onSettings: () -> Void
  let onHelp: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Button(action: onPlacement) {
          Label("placement.title", systemImage: "applewatch")
        }
        .accessibilityIdentifier("menu.placement")
        Button(action: onCharacters) {
          Label("library.title", systemImage: "person.crop.square")
        }
        .accessibilityIdentifier("menu.characters")
        Button(action: onSettings) {
          Label("settings.title", systemImage: "gearshape")
        }
        Button(action: onHelp) {
          Label("help.title", systemImage: "questionmark.circle")
        }
        if let widgetSyncError {
          Text(widgetSyncError).font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle(name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }
        }
      }
    }
  }
}

struct DobooPlacementView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("placement.face.title") {
          Text("placement.face.body")
        }
        Section("placement.stack.title") {
          Text("placement.stack.body")
        }
        Section {
          Text("help.widgetMotion")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .navigationTitle("placement.title")
      .accessibilityIdentifier("placement.instructions")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }
        }
      }
    }
  }
}

struct DobooSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var hapticsEnabled: Bool
  @Binding var motionEnabled: Bool

  var body: some View {
    NavigationStack {
      List {
        Section {
          Toggle("settings.haptics", isOn: $hapticsEnabled)
          Toggle("settings.motion", isOn: $motionEnabled)
        } footer: {
          if reduceMotion {
            Text("settings.reduceMotion")
          } else {
            Text("settings.motionDescription")
          }
        }

        Section {
          NavigationLink {
            DobooHelpView()
          } label: {
            Label("help.title", systemImage: "questionmark.circle")
          }
          NavigationLink {
            DobooPrivacyView()
          } label: {
            Label("privacy.title", systemImage: "hand.raised")
          }
        }

        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("app.name")
              .font(.headline)
            Text("about.tagline")
              .font(.footnote)
            Text(verbatim: "Heznpc")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      }
      .navigationTitle("settings.title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.close") { dismiss() }
        }
      }
    }
  }
}

struct DobooHelpSheetView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      DobooHelpView()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("common.close") { dismiss() }
          }
        }
    }
  }
}

struct DobooHelpView: View {
  var body: some View {
    List {
      Section {
        Text("help.touch")
        Text("help.release")
        Text("help.voiceOver")
      } header: {
        Text("help.playTitle")
      }
      Section {
        Text("help.haptics")
        Text("help.motion")
      } header: {
        Text("help.comfortTitle")
      }
      Section {
        Text("help.widgetPlacement")
        Text("help.widgetMotion")
      } header: {
        Text("help.widgetTitle")
      }
    }
    .navigationTitle("help.title")
  }
}

private struct DobooPrivacyView: View {
  var body: some View {
    List {
      Section {
        Text("privacy.local")
        Text("privacy.preferences")
      } header: {
        Text("privacy.dataTitle")
      }
      Section {
        Text("privacy.system")
      } header: {
        Text("privacy.systemTitle")
      }
    }
    .navigationTitle("privacy.title")
  }
}
