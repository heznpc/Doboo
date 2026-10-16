import SwiftUI

struct DobooMenuView: View {
  let name: String
  let widgetSyncError: String?
  let onCharacters: () -> Void
  let onSettings: () -> Void
  let onHelp: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Button(action: onCharacters) {
          Label("library.title", systemImage: "person.crop.square")
        }
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

struct DobooWelcomeView: View {
  let onStart: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("welcome.title")
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
          Text("welcome.body")
          Label("help.touch", systemImage: "hand.draw")
          Label("help.release", systemImage: "sparkles")
          Text("welcome.preferences")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button("welcome.start", action: onStart)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .navigationTitle("app.name")
    }
    .interactiveDismissDisabled()
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
