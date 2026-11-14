import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var router: AppRouter
    let projectID: String

    @State private var meshBusyVersionID: String?
    @State private var meshError: String?

    private var project: ScanProject? {
        store.project(id: projectID)
    }

    var body: some View {
        Group {
            if let project {
                versionList(project)
                    .navigationTitle(project.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .hideBackButtonKeepSwipe()
                    .safeAreaInset(edge: .bottom) {
                        BottomChromeBar(
                            showsPlus: true,
                            plusAccessibilityLabel: "Новая версия",
                            onPlus: { startNewVersion() }
                        )
                    }
                    .alert("Меш", isPresented: Binding(
                        get: { meshError != nil },
                        set: { if !$0 { meshError = nil } }
                    )) {
                        Button("OK", role: .cancel) { meshError = nil }
                    } message: {
                        Text(meshError ?? "")
                    }
            } else {
                ContentUnavailableView("Проект не найден", systemImage: "exclamationmark.triangle")
                    .hideBackButtonKeepSwipe()
            }
        }
    }

    @ViewBuilder
    private func versionList(_ project: ScanProject) -> some View {
        if project.versions.isEmpty {
            ContentUnavailableView(
                "Нет версий",
                systemImage: "camera",
                description: Text("Нажмите + внизу")
            )
        } else {
            List {
                ForEach(project.versionsOldestFirst) { version in
                    VersionRow(
                        projectID: projectID,
                        version: version,
                        isBusy: meshBusyVersionID == version.id,
                        onCreateMesh: { createMesh(version: version) },
                        onFetchForView: { fetchThenView(version: version) }
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
        }
    }

    private func startNewVersion() {
        guard let version = store.createVersion(projectID: projectID) else { return }
        router.open(.scanner(projectID: projectID, versionID: version.id))
    }

    private func createMesh(version: ScanVersion) {
        guard meshBusyVersionID == nil else { return }
        let settings = BackendSettingsStore.load()
        guard let baseURL = try? settings.resolvedBaseURL() else {
            meshError = "Backend не настроен"
            return
        }
        guard version.frameCount > 0 else {
            meshError = "Нет кадров в версии"
            return
        }

        meshBusyVersionID = version.id
        store.clearMesh(projectID: projectID, versionID: version.id)
        let folder = ProjectPaths.versionFolder(projectID: projectID, versionID: version.id)

        Task {
            defer {
                Task { @MainActor in meshBusyVersionID = nil }
            }
            do {
                let client = MeshAPIClient(baseURL: baseURL)
                _ = try await client.submitMesh(
                    projectID: projectID,
                    versionID: version.id,
                    folder: folder,
                    format: "usdz"
                )
                try await pollMesh(client: client, versionID: version.id)
            } catch {
                await MainActor.run {
                    meshError = error.localizedDescription
                }
            }
        }
    }

    private func fetchThenView(version: ScanVersion) {
        if store.localMeshURL(projectID: projectID, versionID: version.id) != nil {
            router.open(.mesh(projectID: projectID, versionID: version.id))
            return
        }
        createMesh(version: version)
    }

    private func pollMesh(client: MeshAPIClient, versionID: String) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let status = try await client.fetchMeshFile(projectID: projectID, versionID: versionID)
            switch status {
            case .ready(let data, let name):
                let url = ProjectPaths.meshSaveURL(
                    projectID: projectID,
                    versionID: versionID,
                    suggestedName: name
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try data.write(to: url)
                await MainActor.run {
                    store.markMeshReady(
                        projectID: projectID,
                        versionID: versionID,
                        fileName: url.lastPathComponent
                    )
                }
                return
            case .processing:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            case .missing:
                throw MeshAPIError.notReady
            }
        }
        throw MeshAPIError.notReady
    }
}

private struct VersionRow: View {
    @EnvironmentObject private var store: ProjectsStore
    let projectID: String
    let version: ScanVersion
    let isBusy: Bool
    let onCreateMesh: () -> Void
    let onFetchForView: () -> Void

    private var meshURL: URL? {
        store.localMeshURL(projectID: projectID, versionID: version.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                NavigationLink(value: AppRoute.scanner(projectID: projectID, versionID: version.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(version.createdAtLabel) · кадров: \(version.frameCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if isBusy {
                    ProgressView()
                } else if version.meshReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 12) {
                Button(action: onCreateMesh) {
                    Label(isBusy ? "Ждём…" : "Создать меш", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || version.frameCount == 0)

                if meshURL != nil {
                    NavigationLink(value: AppRoute.mesh(projectID: projectID, versionID: version.id)) {
                        Label("Просмотр", systemImage: "cube.transparent")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: onFetchForView) {
                        Label("Просмотр", systemImage: "cube.transparent")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || version.frameCount == 0)
                }
            }
        }
    }
}
