import SwiftUI

/// Gear → Settings on every screen except Settings itself.
struct SettingsGearToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Настройки")
            }
        }
    }
}

extension View {
    func settingsGear() -> some View {
        modifier(SettingsGearToolbar())
    }
}

enum AppRoute: Hashable, Identifiable {
    case project(String)
    case scanner(projectID: String, versionID: String)
    case mesh(projectID: String, versionID: String)

    var id: String {
        switch self {
        case .project(let id): return "p-\(id)"
        case .scanner(let p, let v): return "s-\(p)-\(v)"
        case .mesh(let p, let v): return "m-\(p)-\(v)"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path = NavigationPath()

    func open(_ route: AppRoute) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
