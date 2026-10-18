import SwiftUI

@main
struct DobooApp: App {
  @State private var library = CharacterLibrary()
  @State private var tasks = TaskConnection()
  var body: some Scene {
    WindowGroup {
      ContentView(library: library, tasks: tasks)
      .task {
        library.startTransfer(tasks: tasks)
        #if DEBUG
        library.importLaunchArgument()
        #endif
      }
    }
  }
}
