import SwiftUI

struct ProjectsListView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var router: AppRouter
    @State private var showNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        List {
            if store.projects.isEmpty {
                ContentUnavailableView(
                    "Нет проектов",
                    systemImage: "folder",
                    description: Text("Создайте первый проект")
                )
            } else {
                ForEach(store.projectsNewestFirst) { project in
                    NavigationLink(value: AppRoute.project(project.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name)
                                .font(.headline)
                            Text("\(project.versions.count) версий")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("Проекты")
        .settingsGear()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    newProjectName = ""
                    showNewProject = true
                } label: {
                    Label("Новый проект", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                newProjectName = ""
                showNewProject = true
            } label: {
                Text("Новый проект")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
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
        let items = store.projectsNewestFirst
        for index in offsets {
            store.deleteProject(id: items[index].id)
        }
    }
}
