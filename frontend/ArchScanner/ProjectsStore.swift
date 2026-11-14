import Foundation
import SwiftUI

struct ScanVersion: Identifiable, Codable, Equatable {
    let id: String
    var createdAt: Date
    var frameCount: Int
    var meshReady: Bool
    var localMeshFileName: String?

    var displayTitle: String { id }

    var createdAtLabel: String {
        ArchDateFormat.versionMeta.string(from: createdAt)
    }
}

struct ScanProject: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var versions: [ScanVersion]

    /// Oldest → newest (newest at bottom of inverted UI).
    var versionsOldestFirst: [ScanVersion] {
        versions.sorted { $0.createdAt < $1.createdAt }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, versions
    }

    init(id: String, name: String, createdAt: Date, updatedAt: Date, versions: [ScanVersion]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versions = versions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        versions = try c.decodeIfPresent([ScanVersion].self, forKey: .versions) ?? []
        if let updated = try c.decodeIfPresent(Date.self, forKey: .updatedAt) {
            updatedAt = updated
        } else {
            updatedAt = versions.map(\.createdAt).max() ?? createdAt
        }
    }
}

enum ProjectPaths {
    static let projectsRootName = "Projects"
    static let storeFileName = "projects.json"

    static func documentsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func storeURL() -> URL {
        documentsRoot().appendingPathComponent(storeFileName)
    }

    static func projectRoot(projectID: String) -> URL {
        documentsRoot()
            .appendingPathComponent(projectsRootName, isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }

    static func versionFolder(projectID: String, versionID: String) -> URL {
        projectRoot(projectID: projectID)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(versionID, isDirectory: true)
    }

    static func meshSaveURL(projectID: String, versionID: String, suggestedName: String) -> URL {
        let folder = versionFolder(projectID: projectID, versionID: versionID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = suggestedName.isEmpty ? "\(versionID).usdz" : suggestedName
        return folder.appendingPathComponent(safe)
    }
}

final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [ScanProject] = []

    static let shared = ProjectsStore()

    init() {
        load()
    }

    /// Oldest update → newest (newest at bottom).
    var projectsOldestFirst: [ScanProject] {
        projects.sorted { $0.updatedAt < $1.updatedAt }
    }

    func project(id: String) -> ScanProject? {
        projects.first { $0.id == id }
    }

    func version(projectID: String, versionID: String) -> ScanVersion? {
        project(id: projectID)?.versions.first { $0.id == versionID }
    }

    @discardableResult
    func createProject(name: String) -> ScanProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let project = ScanProject(
            id: UUID().uuidString.lowercased(),
            name: trimmed.isEmpty ? "Проект" : trimmed,
            createdAt: now,
            updatedAt: now,
            versions: []
        )
        projects.append(project)
        let versions = ProjectPaths.projectRoot(projectID: project.id)
            .appendingPathComponent("versions", isDirectory: true)
        try? FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        save()
        return project
    }

    @discardableResult
    func createVersion(projectID: String) -> ScanVersion? {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let versionID = nextVersionID(projectID: projectID)
        let now = Date()
        let version = ScanVersion(
            id: versionID,
            createdAt: now,
            frameCount: 0,
            meshReady: false,
            localMeshFileName: nil
        )
        let folder = ProjectPaths.versionFolder(projectID: projectID, versionID: versionID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FrameMetadataWriter.writeSeriesManifest(
            seriesName: versionID,
            folder: folder,
            frameCount: 0,
            createdAt: now
        )
        projects[idx].versions.append(version)
        projects[idx].updatedAt = now
        save()
        return version
    }

    func updateFrameCount(projectID: String, versionID: String, count: Int) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[pIdx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        guard projects[pIdx].versions[vIdx].frameCount != count else { return }
        projects[pIdx].versions[vIdx].frameCount = count
        projects[pIdx].updatedAt = Date()
        save()
    }

    func markMeshReady(projectID: String, versionID: String, fileName: String) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[pIdx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        projects[pIdx].versions[vIdx].meshReady = true
        projects[pIdx].versions[vIdx].localMeshFileName = fileName
        projects[pIdx].updatedAt = Date()
        save()
    }

    func clearMesh(projectID: String, versionID: String) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[pIdx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        projects[pIdx].versions[vIdx].meshReady = false
        projects[pIdx].versions[vIdx].localMeshFileName = nil
        save()
    }

    func renameProject(id: String, name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[idx].name = trimmed.isEmpty ? projects[idx].name : trimmed
        projects[idx].updatedAt = Date()
        save()
    }

    func deleteProject(id: String) {
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: ProjectPaths.projectRoot(projectID: id))
        save()
    }

    func localMeshURL(projectID: String, versionID: String) -> URL? {
        guard let version = version(projectID: projectID, versionID: versionID),
              let name = version.localMeshFileName, !name.isEmpty else { return nil }
        let url = ProjectPaths.versionFolder(projectID: projectID, versionID: versionID)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        let url = ProjectPaths.storeURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ScanProject].self, from: data) else {
            projects = []
            return
        }
        projects = decoded
    }

    private func save() {
        let url = ProjectPaths.storeURL()
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Next id: v1, v2, …
    private func nextVersionID(projectID: String) -> String {
        let existing = project(id: projectID)?.versions.map(\.id) ?? []
        let maxExplicit = existing.compactMap { id -> Int? in
            guard id.first == "v" else { return nil }
            return Int(id.dropFirst())
        }.max() ?? 0
        if maxExplicit > 0 {
            return "v\(maxExplicit + 1)"
        }
        return "v\(existing.count + 1)"
    }
}
