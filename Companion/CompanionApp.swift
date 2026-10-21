import SwiftUI

@main
struct DobooLibraryApp: App {
  @State private var library = CharacterLibrary()
  @State private var tasks = TaskConnection()

  var body: some Scene {
    WindowGroup {
      TabView {
        CompanionHomeView(library: library, tasks: tasks)
          .tabItem { Label("동반자", systemImage: "heart") }
        StoryDashboard(connection: tasks, library: library)
          .tabItem { Label("story.title", systemImage: "book") }
        CharacterLibraryView(library: library)
          .tabItem { Label("캐릭터", systemImage: "person.crop.square") }
      }
        .task {
          library.startTransfer(tasks: tasks)
          #if DEBUG
          library.importLaunchArgument()
          #endif
        }
        .onOpenURL { url in
          if url.isFileURL { library.importFile(url) }
        }
    }
  }
}
