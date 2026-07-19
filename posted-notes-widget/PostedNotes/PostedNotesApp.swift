import SwiftUI

@main
struct PostedNotesApp: App {
    var body: some Scene {
        WindowGroup("Posted Notes") {
            ContentView()
                .frame(minWidth: 380, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}
