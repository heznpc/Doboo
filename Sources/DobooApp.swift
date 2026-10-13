import SwiftUI

@main
struct DobooApp: App {
  @State private var library = CharacterLibrary()
  @State private var tasks = TaskConnection()
  var body: some Scene {
    WindowGroup {
      ContentView(library: library, tasks: tasks)
      .task {
        library.startTransfer()
        #if DEBUG
        library.importLaunchArgument()
        #endif
      }
    }
  }
}
