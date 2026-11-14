import SwiftUI
import UIKit

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

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path = NavigationPath()
    }
}

/// Bottom bar: optional + on the left, settings gear on the right.
struct BottomChromeBar: View {
    var showsPlus: Bool = false
    var plusAccessibilityLabel: String = "Добавить"
    var onPlus: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 20) {
            if showsPlus, let onPlus {
                Button(action: onPlus) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(plusAccessibilityLabel)
            }

            Spacer(minLength: 0)

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Настройки")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

extension View {
    /// Hide nav back button but keep edge swipe (кроме экранов, где back нужен явно).
    func hideBackButtonKeepSwipe() -> some View {
        self
            .navigationBarBackButtonHidden(true)
            .background(SwipeBackEnabler())
    }
}

/// Re-enable interactive pop when the back button is hidden.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackController {
        SwipeBackController()
    }

    func updateUIViewController(_ uiViewController: SwipeBackController, context: Context) {}
}

private final class SwipeBackController: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        nav.interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

enum ArchDateFormat {
    static let versionMeta: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
