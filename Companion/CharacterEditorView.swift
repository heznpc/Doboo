import SwiftUI
import UniformTypeIdentifiers

struct CharacterEditorView: View {
  let original: CharacterPack?
  @Bindable var library: CharacterLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CharacterPack
  @State private var importingSprite = false
  @State private var spriteName: String?
  @State private var spriteLayout: CharacterPack.Appearance.Sprite.Layout
  @State private var errorMessage: String?

  init(original: CharacterPack?, library: CharacterLibrary) {
    self.original = original
    self.library = library
    var value = original ?? CharacterPack(
      format: CharacterPack.formatName, id: "", version: 1, name: "", description: "", creator: "",
      identity: .init(backstory: "", voice: ""), personality: .init(traits: [], instructions: []),
      appearance: .init(renderer: .nativeDoboo, tint: "#FF8F62")
    )
    if original != nil && value.version < 9_007_199_254_740_991 { value.version += 1 }
    _draft = State(initialValue: value)
    _spriteLayout = State(initialValue: value.appearance.sprite?.layout ?? .petsV2)
  }

  private var existing: CharacterPack? { library.packs.first(where: { $0.id == draft.id }) }
  private var selectedTint: Binding<Color> {
    Binding(get: { Color(hex: draft.appearance.tint) }, set: { color in
      var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
      guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
      draft.appearance.tint = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    })
  }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        Section("editor.story") {
          TextField("editor.story", text: $draft.identity.backstory, axis: .vertical)
            .lineLimit(3...8).accessibilityIdentifier("editor.story")
          TextField("editor.voice", text: $draft.identity.voice, axis: .vertical)
            .lineLimit(2...5).accessibilityIdentifier("editor.voice")
        }
        traitsSection
        instructionsSection
        appearanceSection
        Section("editor.watchAppearance") {
          Toggle("editor.watchNative", isOn: Binding(
            get: { draft.appearance.watch?.renderer == .nativeDoboo },
            set: { enabled in
              draft.appearance.watch = enabled ? .init(renderer: .nativeDoboo, tint: draft.appearance.tint) : nil
            }))
          Text("editor.watchHelp")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if existing != nil {
          Section {
            Text("editor.update").font(.footnote).foregroundStyle(.secondary)
          }
        }
        if let errorMessage {
          Section { Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("editor.error") }
        }
      }
      .navigationTitle(LocalizedStringKey(original == nil ? "editor.create" : "editor.edit"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("editor.cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("editor.save", action: save).fontWeight(.semibold)
            .accessibilityIdentifier("editor.save")
        }
      }
      .fileImporter(isPresented: $importingSprite, allowedContentTypes: [.png], allowsMultipleSelection: false) { result in
        do { if let url = try result.get().first { try attachSprite(url) } }
        catch { errorMessage = error.localizedDescription }
      }
    }
  }

  private var identitySection: some View {
    Section {
      TextField("editor.name", text: $draft.name).accessibilityIdentifier("editor.name")
      TextField("editor.creator", text: $draft.creator).accessibilityIdentifier("editor.creator")
      TextField("editor.id", text: $draft.id).textInputAutocapitalization(.never).autocorrectionDisabled()
        .disabled(original != nil).accessibilityIdentifier("editor.id")
      LabeledContent("editor.version") {
        TextField("editor.version", value: $draft.version, format: .number)
          .keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("editor.version")
      }
      TextField("editor.description", text: $draft.description, axis: .vertical)
        .lineLimit(2...4).accessibilityIdentifier("editor.description")
    } footer: { Text("editor.idHelp") }
  }

  private var traitsSection: some View {
    Section("editor.traits") {
      ForEach(Array(draft.personality.traits.indices), id: \.self) { index in
        HStack {
          TextField("editor.traits", text: listBinding(\.traits, index: index))
            .accessibilityIdentifier("editor.trait.\(index)")
          Button(role: .destructive) {
            if draft.personality.traits.indices.contains(index) { draft.personality.traits.remove(at: index) }
          } label: {
            Image(systemName: "minus.circle").accessibilityLabel("editor.remove")
          }.buttonStyle(.borderless)
        }
      }
      Button { draft.personality.traits.append("") } label: { Label("editor.addTrait", systemImage: "plus") }
        .disabled(draft.personality.traits.count >= 20).accessibilityIdentifier("editor.addTrait")
    }
  }

  private var instructionsSection: some View {
    Section("editor.instructions") {
      ForEach(Array(draft.personality.instructions.indices), id: \.self) { index in
        HStack(alignment: .top) {
          TextField("editor.instructions", text: listBinding(\.instructions, index: index), axis: .vertical)
            .lineLimit(2...5).accessibilityIdentifier("editor.instruction.\(index)")
          Button(role: .destructive) {
            if draft.personality.instructions.indices.contains(index) { draft.personality.instructions.remove(at: index) }
          } label: {
            Image(systemName: "minus.circle").accessibilityLabel("editor.remove")
          }.buttonStyle(.borderless)
        }
      }
      Button { draft.personality.instructions.append("") } label: { Label("editor.addInstruction", systemImage: "plus") }
        .disabled(draft.personality.instructions.count >= 30).accessibilityIdentifier("editor.addInstruction")
    }
  }

  private var appearanceSection: some View {
    Section {
      Picker("editor.renderer", selection: $draft.appearance.renderer) {
        Text("editor.native").tag(CharacterPack.Appearance.Renderer.nativeDoboo)
        Text("editor.sprite").tag(CharacterPack.Appearance.Renderer.spritesheet)
      }.accessibilityIdentifier("editor.renderer")
      if draft.appearance.renderer == .nativeDoboo {
        ColorPicker("editor.tint", selection: selectedTint, supportsOpacity: false)
          .accessibilityIdentifier("editor.tint")
        PackCharacterView(pack: draft, interaction: .init(), phase: 0, motionEnabled: false)
          .frame(height: 160).frame(maxWidth: .infinity)
      } else {
        Picker("editor.layout", selection: $spriteLayout) {
          Text(verbatim: "Pets v1 · 1536 × 1872").tag(CharacterPack.Appearance.Sprite.Layout.petsV1)
          Text(verbatim: "Pets v2 · 1536 × 2288").tag(CharacterPack.Appearance.Sprite.Layout.petsV2)
        }.onChange(of: spriteLayout) { _, layout in draft.appearance.sprite?.layout = layout }
        Button { importingSprite = true } label: { Label("editor.attachPNG", systemImage: "photo.badge.plus") }
          .accessibilityIdentifier("editor.attachPNG")
        if let spriteName { Text(spriteName).font(.caption).foregroundStyle(.secondary) }
        if draft.appearance.sprite != nil {
          PackCharacterView(pack: draft, interaction: .init(), phase: 0, motionEnabled: false)
            .frame(height: 160).frame(maxWidth: .infinity)
            .id("\(spriteLayout.rawValue)-\(draft.appearance.sprite?.base64.hashValue ?? 0)")
        }
      }
    } header: { Text("editor.appearance") } footer: { Text("editor.spriteHelp") }
  }

  private func attachSprite(_ url: URL) throws {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let data = try CharacterLibrary.readBoundedFile(url)
    guard data.count <= CharacterPack.maximumImageBytes else { throw CharacterPackError.invalidImage }
    let dimensions = try PNGDimensions(data: data)
    guard dimensions.width == 1536, dimensions.height == spriteLayout.pixelHeight else {
      throw CharacterPackError.invalidImageDimensions
    }
    var candidate = draft
    candidate.appearance.sprite = .init(layout: spriteLayout, mimeType: "image/png", base64: data.base64EncodedString())
    try SpriteAtlas.validate(candidate)
    draft.appearance.sprite = candidate.appearance.sprite
    spriteName = url.lastPathComponent
    errorMessage = nil
  }

  private func listBinding(_ keyPath: WritableKeyPath<CharacterPack.Personality, [String]>, index: Int) -> Binding<String> {
    Binding(get: {
      let values = draft.personality[keyPath: keyPath]
      return values.indices.contains(index) ? values[index] : ""
    }, set: { value in
      guard draft.personality[keyPath: keyPath].indices.contains(index) else { return }
      draft.personality[keyPath: keyPath][index] = value
    })
  }

  private func save() {
    do {
      if let current = existing {
        guard draft.version > current.version else { throw CharacterPackError.conflictingVersion }
      }
      var candidate = draft
      if candidate.appearance.renderer == .nativeDoboo { candidate.appearance.sprite = nil }
      let saved = try library.importData(candidate.encoded())
      library.select(saved)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}
