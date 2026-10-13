import Foundation

// Compile with Sources/Core/*.swift to exercise the exact native model against
// a gallery-exported file through two independent stores, without a separate parser.
@main
struct VerifyPack {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      FileHandle.standardError.write(Data("Usage: verify-pack input.doboo.json output.doboo.json\n".utf8))
      exit(2)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= CharacterPack.maximumJSONBytes else { throw CharacterPackError.jsonTooLarge }
    let pack = try CharacterPack.decode(Data(contentsOf: input))
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var sender = try CharacterStore(directory: scratch.appendingPathComponent("sender"))
    _ = try sender.importPack(pack)
    try sender.select(id: pack.id)
    let shared = try sender.selected.encoded()
    var receiver = try CharacterStore(directory: scratch.appendingPathComponent("receiver"))
    _ = try receiver.importPack(CharacterPack.decode(shared))
    try receiver.select(id: pack.id)
    var conflicting = pack
    conflicting.name = "Conflicting content"
    do {
      _ = try receiver.importPack(conflicting)
      fatalError("Same-version conflict was not rejected")
    } catch CharacterPackError.conflictingVersion {}
    let reopened = try CharacterStore(directory: scratch.appendingPathComponent("receiver"))
    guard reopened.selected == pack else { fatalError("Exchange or persistence changed character") }
    try reopened.selected.encoded().write(to: output, options: .atomic)
    try Data(CharacterExports.dots(pack).utf8).write(to: output.appendingPathExtension("dots.md"), options: .atomic)
    try Data(CharacterExports.codex(pack).utf8).write(to: output.appendingPathExtension("toml"), options: .atomic)
    print("Native round trip: \(pack.id)@\(pack.version)")
  }
}
