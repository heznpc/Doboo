import SwiftUI

@main
struct DobooApp: App {
  @State private var library = CharacterLibrary()
  var body: some Scene {
    WindowGroup {
      ContentView(library: library)
        .task { library.startTransfer() }
    }
  }
}
