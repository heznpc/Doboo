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

          CharacterPlayView(pack: library.selected, isEnabled: !creating && !importing)
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
        CharacterPlayView(pack: pack, isEnabled: !editing && !showingInstructions).frame(height: 280)
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
        CharacterSettingsView(pack: pack)
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
  var isEnabled = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @GestureState private var dragging = false
  @State private var interaction = BlobInteractionState()
  @State private var pressedFeedback = false
  @State private var releaseFeedback = false
  @State private var accessibleTask: Task<Void, Never>?
  @State private var accessiblePlayID: UUID?
  private var canInteract: Bool { isEnabled && scenePhase == .active }
  private var animated: Bool { canInteract && !reduceMotion }

  var body: some View {
    GeometryReader { proxy in
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { time in
        PackCharacterView(pack: pack, interaction: interaction,
          phase: animated ? time.date.timeIntervalSinceReferenceDate : 0, motionEnabled: animated)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).updating($dragging) { _, active, _ in active = true }
        .onChanged { value in
          guard canInteract else { cancelInteraction(); return }
          if accessiblePlayID != nil { cancelInteraction() }
          let wasPressed = interaction.isPressed
          guard interaction.press(at: value.location, in: proxy.size) else { cancelInteraction(); return }
          if !wasPressed { pressedFeedback.toggle() }
        }
        .onEnded { _ in
          guard accessiblePlayID == nil else { return }
          guard canInteract else { cancelInteraction(); return }
          releaseInteraction()
        })
      .allowsHitTesting(canInteract)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(pack.name)
      .accessibilityValue(interaction.isPressed ? Text("character.state.pressed") : Text("character.state.resting"))
      .accessibilityHint("character.hint")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("character.play")
      .accessibilityAction { playAccessibly(in: proxy.size) }
      .accessibilityAction(named: "character.action.squeeze") { playAccessibly(in: proxy.size) }
      .accessibilityAction(named: "character.action.left") { playAccessibly(in: proxy.size, point: .init(x: 0.2, y: 0.5)) }
      .accessibilityAction(named: "character.action.right") { playAccessibly(in: proxy.size, point: .init(x: 0.8, y: 0.5)) }
      .accessibilityAction(named: "character.action.top") { playAccessibly(in: proxy.size, point: .init(x: 0.5, y: 0.2)) }
      .accessibilityAction(named: "character.action.bottom") { playAccessibly(in: proxy.size, point: .init(x: 0.5, y: 0.8)) }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: pressedFeedback)
    .sensoryFeedback(.selection, trigger: releaseFeedback)
    .onChange(of: dragging) { _, active in
      if !active && accessiblePlayID == nil && interaction.isPressed { cancelInteraction() }
    }
    .onChange(of: canInteract) { _, enabled in if !enabled { cancelInteraction() } }
    .onChange(of: reduceMotion) { _, _ in cancelInteraction() }
    .onChange(of: pack.id) { _, _ in cancelInteraction() }
    .onChange(of: pack.version) { _, _ in cancelInteraction() }
    .onDisappear { cancelInteraction() }
  }

  private func playAccessibly(in size: CGSize, point: UnitPoint = .init(x: 0.7, y: 0.45)) {
    guard canInteract else { return }
    cancelInteraction()
    guard interaction.press(at: CGPoint(x: size.width * point.x, y: size.height * point.y), in: size)
    else { return }
    pressedFeedback.toggle()
    let playID = UUID()
    accessiblePlayID = playID
    accessibleTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard !Task.isCancelled, accessiblePlayID == playID, canInteract else { return }
      releaseInteraction()
      accessiblePlayID = nil
      accessibleTask = nil
    }
  }

  private func releaseInteraction() {
    guard interaction.isPressed else { return }
    interaction.release()
    releaseFeedback.toggle()
  }

  private func cancelInteraction() {
    accessibleTask?.cancel()
    accessibleTask = nil
    accessiblePlayID = nil
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { interaction.cancel() }
  }
}
