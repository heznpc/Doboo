import SwiftUI
import UniformTypeIdentifiers

struct CharacterLibraryView: View {
  @Bindable var library: CharacterLibrary
  @State private var importing = false
  @State private var creating = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text("gallery.heading").font(.largeTitle.bold())
            Text("gallery.subtitle").font(.body).foregroundStyle(.secondary)
          }
          .padding(.top, 8)

          CharacterPlayView(pack: library.selected)
            .frame(height: 240)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32))
            .overlay(alignment: .bottomLeading) {
              Label(library.selected.name, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).padding(18)
            }
          if let notice = library.notice {
            Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
              .accessibilityIdentifier("library.notice")
          }
          VStack(spacing: 12) {
            ForEach(library.packs) { pack in
              NavigationLink {
                CharacterDetailView(pack: pack, library: library)
              } label: {
                HStack(spacing: 16) {
                  PackCharacterView(pack: pack, interaction: .init(), phase: 0, motionEnabled: false)
                    .frame(width: 68, height: 74)
                    .background(Color(hex: pack.appearance.tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                  VStack(alignment: .leading, spacing: 5) {
                    Text(pack.name).font(.headline).foregroundStyle(.primary)
                    Text(pack.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Text(verbatim: "\(pack.id) · v\(pack.version)").font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: library.selected.id == pack.id ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(Color.accentColor)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.06)))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("character.card.\(pack.id)")
            }
          }
          Text("gallery.localNote").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("gallery.title")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button { creating = true } label: { Label("editor.create", systemImage: "sparkles") }
              .accessibilityIdentifier("library.create")
            Button { importing = true } label: { Label("library.import", systemImage: "square.and.arrow.down") }
              .accessibilityIdentifier("library.import")
          } label: { Label("editor.create", systemImage: "plus") }
            .accessibilityIdentifier("library.add")
        }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
        do { if let url = try result.get().first { library.importFile(url) } }
        catch { library.errorMessage = error.localizedDescription }
      }
      .sheet(isPresented: $creating) { CharacterEditorView(original: nil, library: library) }
      .alert("library.errorTitle", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
        Button("common.ok", role: .cancel) { library.errorMessage = nil }
      } message: { Text(library.errorMessage ?? "") }
    }
    .tint(Color(red: 0.46, green: 0.32, blue: 0.68))
  }
}

struct CharacterDetailView: View {
  let pack: CharacterPack
  @Bindable var library: CharacterLibrary
  @State private var exportedURL: URL?
  @State private var dotsURL: URL?
  @State private var subagentURL: URL?
  @State private var spriteURL: URL?
  @State private var showingInstructions = false
  @State private var editing = false
  private var currentPack: CharacterPack { library.packs.first(where: { $0.id == pack.id }) ?? pack }

  var body: some View {
    let pack = currentPack
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        CharacterPlayView(pack: pack).frame(height: 280)
          .background(Color(hex: pack.appearance.tint).opacity(0.10), in: RoundedRectangle(cornerRadius: 30))
        VStack(alignment: .leading, spacing: 8) {
          Text(pack.name).font(.largeTitle.bold()).accessibilityIdentifier("character.detail.name")
          Text(pack.description).font(.body).foregroundStyle(.secondary)
          Text(verbatim: "\(pack.id) · v\(pack.version) · \(pack.creator)")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .accessibilityIdentifier("character.detail.identity")
        }
        Button { library.select(pack) } label: {
          Label(library.selected.id == pack.id ? "library.selected" : "library.select", systemImage: "checkmark.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("character.select")

        VStack(alignment: .leading, spacing: 12) {
          Button { library.transfer?.send(pack) } label: {
            Label("transfer.send", systemImage: "applewatch.radiowaves.left.and.right")
          }
          .buttonStyle(.bordered).accessibilityIdentifier("character.send")
          Text(library.transferStatus).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("character.transferStatus")
        }
        GroupBox("character.personality") {
          VStack(alignment: .leading, spacing: 12) {
            Text(pack.personality.traits.joined(separator: " · ")).font(.headline)
            Text(pack.identity.voice).foregroundStyle(.secondary)
            ForEach(Array(pack.personality.instructions.enumerated()), id: \.offset) { _, instruction in
              Label { Text(instruction) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
            }
          }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        if !pack.identity.backstory.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("character.story").font(.headline)
            Text(pack.identity.backstory).foregroundStyle(.secondary)
          }
        }
        if let exportedURL {
          ShareLink(item: exportedURL) { Label("library.share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("character.share")
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("character.exports").font(.title3.bold())
          Button { showingInstructions = true } label: { Label("character.dotInstructions", systemImage: "text.bubble") }
            .accessibilityIdentifier("character.instructions")
          if let dotsURL {
            ShareLink(item: dotsURL) { Label("character.dotsShare", systemImage: "doc.text") }
              .accessibilityIdentifier("character.dotsShare")
          }
          if let subagentURL {
            ShareLink(item: subagentURL) { Label("character.subagent", systemImage: "person.crop.rectangle.stack") }
              .accessibilityIdentifier("character.subagentShare")
          }
          if let spriteURL {
            ShareLink(item: spriteURL) { Label("character.spriteExport", systemImage: "photo") }
              .accessibilityIdentifier("character.spriteShare")
          } else {
            Text("character.spriteMissing").font(.footnote).foregroundStyle(.secondary)
          }
          Text("character.exportHelp").font(.footnote).foregroundStyle(.secondary)
        }
      }
      .padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
    .navigationTitle(pack.name).navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("editor.edit") { editing = true }.accessibilityIdentifier("character.edit")
      }
    }
    .task(id: "\(pack.id)@\(pack.version)") {
      do {
        exportedURL = try library.exportURL(for: pack)
        dotsURL = try CharacterExports.url(for: pack, kind: .dots)
        subagentURL = try CharacterExports.url(for: pack, kind: .subagent)
        spriteURL = pack.appearance.sprite == nil ? nil : try CharacterExports.url(for: pack, kind: .sprite)
      }
      catch { library.errorMessage = error.localizedDescription }
    }
    .sheet(isPresented: $showingInstructions) { DotInstructionsView(pack: pack) }
    .sheet(isPresented: $editing) { CharacterEditorView(original: currentPack, library: library) }
  }
}

private struct DotInstructionsView: View {
  let pack: CharacterPack
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false
  @State private var instructions = ""
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("character.dotHelp").foregroundStyle(.secondary)
          Text(instructions).font(.callout.monospaced()).textSelection(.enabled)
          Button {
            UIPasteboard.general.string = instructions
            copied = true
          } label: { Label(copied ? "common.copied" : "common.copy", systemImage: "doc.on.doc") }
        }.padding(24)
      }
      .navigationTitle("character.dotInstructions")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.close") { dismiss() } } }
      .task { instructions = (try? CharacterExports.dots(pack)) ?? "" }
    }
  }
}

/// Uses the same interaction state and renderer as Watch, with iPhone haptics.
struct CharacterPlayView: View {
  let pack: CharacterPack
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @GestureState private var dragging = false
  @State private var interaction = BlobInteractionState()
  @State private var pressedFeedback = false
  @State private var releaseFeedback = false
  @State private var accessibleTask: Task<Void, Never>?
  private var animated: Bool { !reduceMotion && scenePhase == .active }

  var body: some View {
    GeometryReader { proxy in
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { time in
        PackCharacterView(pack: pack.watchRepresentation, interaction: interaction,
          phase: animated ? time.date.timeIntervalSinceReferenceDate : 0, motionEnabled: animated)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).updating($dragging) { _, active, _ in active = true }
        .onChanged { value in
          guard scenePhase == .active else { return }
          accessibleTask?.cancel()
          if !interaction.isPressed { pressedFeedback.toggle() }
          interaction.press(at: value.location, in: proxy.size)
        }
        .onEnded { _ in
          if interaction.isPressed { interaction.release(); releaseFeedback.toggle() }
        })
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(pack.name)
      .accessibilityValue(interaction.isPressed ? Text("character.state.pressed") : Text("character.state.resting"))
      .accessibilityHint("character.hint")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("character.play")
      .accessibilityAction {
        accessibleTask?.cancel()
        interaction.press(at: CGPoint(x: proxy.size.width * 0.7, y: proxy.size.height * 0.45), in: proxy.size)
        pressedFeedback.toggle()
        accessibleTask = Task { @MainActor in
          do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
          guard !Task.isCancelled else { return }
          interaction.release(); releaseFeedback.toggle()
        }
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: pressedFeedback)
    .sensoryFeedback(.selection, trigger: releaseFeedback)
    .onChange(of: dragging) { _, active in if !active { interaction.cancel() } }
    .onChange(of: scenePhase) { _, state in if state != .active { accessibleTask?.cancel(); interaction.cancel() } }
    .onDisappear { accessibleTask?.cancel(); interaction.cancel() }
  }
}
