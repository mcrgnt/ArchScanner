import SwiftUI

struct ProjectsListView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var router: AppRouter
    @State private var showNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView(
                    "Нет проектов",
                    systemImage: "folder",
                    description: Text("Нажмите + внизу")
                )
            } else {
                List {
                    ForEach(store.projectsOldestFirst) { project in
                        NavigationLink(value: AppRoute.project(project.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.headline)
                                Text(versionsLabel(project.versions.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
            }
        }
        .navigationTitle("Проекты")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            BottomChromeBar(
                showsPlus: true,
                plusAccessibilityLabel: "Новый проект",
                onPlus: {
                    newProjectName = ""
                    showNewProject = true
                }
            )
        }
        .alert("Новый проект", isPresented: $showNewProject) {
            TextField("Название", text: $newProjectName)
            Button("Создать") {
                let project = store.createProject(name: newProjectName)
                router.open(.project(project.id))
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Имя можно изменить позже")
        }
    }

    private func delete(at offsets: IndexSet) {
        let items = store.projectsOldestFirst
        for index in offsets {
            store.deleteProject(id: items[index].id)
        }
    }

    private func versionsLabel(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1, mod100 != 11 {
            word = "версия"
        } else if (2...4).contains(mod10), !(12...14).contains(mod100) {
            word = "версии"
        } else {
            word = "версий"
        }
        return "\(count) \(word)"
    }
}
