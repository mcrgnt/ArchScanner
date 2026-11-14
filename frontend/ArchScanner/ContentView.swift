import SwiftUI

struct ContentView: View {
    @StateObject private var router = AppRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            ProjectsListView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .project(let id):
                        ProjectDetailView(projectID: id)
                    case .scanner(let projectID, let versionID):
                        ScannerView(projectID: projectID, versionID: versionID)
                    case .mesh(let projectID, let versionID):
                        MeshViewerScreen(projectID: projectID, versionID: versionID)
                    }
                }
        }
        .environmentObject(router)
    }
}
