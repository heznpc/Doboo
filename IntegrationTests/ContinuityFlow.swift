import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

@main
struct ContinuityFlow {
  @MainActor static func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
  }

  @MainActor static func completed(_ connection: TaskConnection) async throws -> CompanionTask {
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      await connection.refresh()
      if let task = connection.tasks.first, task.finished {
        try require(task.status == "completed", "Task failed: \(task.error ?? task.status)")
        return task
      }
      if connection.tasks.first?.status == "needsApproval" {
        throw CheckFailure(description: "Synthetic continuity test unexpectedly requested a tool approval")
      }
      try await Task.sleep(for: .milliseconds(300))
    }
    throw CheckFailure(description: "Timed out waiting for a task")
  }

  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let phase = args[2]
    let connectionData = try Data(contentsOf: root.appendingPathComponent("bridge/connection.json"))
    let endpoint = try JSONDecoder().decode(ComputerConnection.self, from: connectionData)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = TaskConnection(storage: root.appendingPathComponent(phase == "seed" ? "phone" : "watch"),
      session: session, persistCredential: { _ in })
    client.setSceneActive(true)
    client.address = endpoint.url
    client.connectionToken = endpoint.token
    let connected = await client.connect()
    try require(connected, "Connect failed: \(client.error ?? "unknown")")
    var character = CharacterPack.builtin
    character.id = "continuity-orb"
    character.name = "Orb"
    character.identity = .init(backstory: "A patient prototype companion.", voice: "Start every response with [ORB]. Keep answers short.")
    character.personality = .init(traits: ["precise"], instructions: ["Use provided context faithfully. If a fact is absent, say UNKNOWN instead of inventing it."])
    let memory = "The access word for this synthetic test is MINT742."
    let stateURL = root.appendingPathComponent("seed.json")

    if phase == "seed" {
      let saved = await client.saveCompanion(character: character, memory: memory, expectedRevision: 0)
      try require(saved, "Save failed: \(client.error ?? "unknown")")
      let context = try unwrap(client.companion(for: character), "Missing registered context")
      client.prompt = "The prototype codename is violet-lantern. Reply with its codename and the saved access word in your character voice. Do not use tools."
      let submitted = await client.submit(companion: context)
      try require(submitted, "Submit failed: \(client.error ?? "unknown")")
      let task = try await completed(client)
      try require(task.result.contains("[ORB]") && task.result.contains("MINT742") && task.result.contains("violet-lantern"), "Persona or saved memory did not reach the real response: \(task.result)")
      try require(task.continuity?.historyCount == 0 && task.continuity?.memoryApplied == true, "Incorrect initial context evidence")
      try JSONEncoder().encode(task).write(to: stateURL)
      print("PASS phone: explicit persona and saved memory reached task output")
    } else {
      let seed = try JSONDecoder().decode(CompanionTask.self, from: Data(contentsOf: stateURL))
      let context = try unwrap(client.companion(for: character.watchRepresentation), "Watch did not receive the phone context")
      try require(context.memory == memory && context.profile == CompanionProfile(character.watchRepresentation), "Phone/Watch context mismatch after restart")
      try require(client.serverId == seed.continuity?.serverId, "Server identity changed on restart")
      let parent = try unwrap(client.tasks.first(where: { $0.id == seed.id }), "Watch did not receive phone task")
      try require(client.canContinue(task: parent), "Completed phone work cannot continue on Watch")
      client.prompt = "What prototype codename did we settle on and what is the access word? Keep your character voice. Do not use tools."
      let submitted = await client.submit(companion: context, parentTask: parent)
      try require(submitted, "Follow-up failed: \(client.error ?? "unknown")")
      let followup = try await completed(client)
      try require(followup.result.contains("[ORB]") && followup.result.contains("MINT742") && followup.result.contains("violet-lantern"), "Prior work was absent from follow-up: \(followup.result)")
      try require(followup.continuity?.conversationId == seed.continuity?.conversationId && followup.continuity?.historyCount == 1, "Continuation lineage was not retained")
      print("PASS watch: personality, saved memory and phone work continued after bridge restart")

      let reset = await client.saveCompanion(character: character, memory: "", expectedRevision: context.revision, resetHistory: true)
      try require(reset, "Forget failed: \(client.error ?? "unknown")")
      let cleared = try unwrap(client.companion(for: character), "Missing cleared context")
      try require(cleared.generation > context.generation && !client.canContinue(task: followup), "Forget did not invalidate old ancestry")
      client.prompt = "What prototype codename and access word are known from the supplied context? If absent, say UNKNOWN. Do not guess or use tools."
      let freshSubmitted = await client.submit(companion: cleared)
      try require(freshSubmitted, "New task after forget failed")
      let fresh = try await completed(client)
      try require(fresh.result.contains("[ORB]") && fresh.result.contains("UNKNOWN") && !fresh.result.contains("MINT742") && !fresh.result.contains("violet-lantern"), "Forgotten facts resurfaced: \(fresh.result)")
      try require(fresh.continuity?.historyCount == 0 && fresh.continuity?.memoryApplied == false, "Reset incorrectly claims prior context")
      print("PASS forget: old work and memory excluded while character voice remains")
    }
    client.setSceneActive(false)
  }

  private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
  }
}
