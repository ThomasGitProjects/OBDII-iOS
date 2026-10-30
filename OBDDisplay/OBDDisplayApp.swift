import SwiftUI

@main
struct OBDDisplayApp: App {
    @State private var manager = OBDLinkManager()
    @State private var preferences = AppPreferences()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .environment(preferences)
        }
    }
}
