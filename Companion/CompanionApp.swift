import SwiftUI

@main
struct DobooLibraryApp: App {
  @State private var library = CharacterLibrary()

  var body: some Scene {
    WindowGroup {
      CharacterLibraryView(library: library)
        .task {
          library.startTransfer()
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
