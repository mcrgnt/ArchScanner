import SwiftUI

@main
struct ArchScannerApp: App {
    @StateObject private var store = ProjectsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
