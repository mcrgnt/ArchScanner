import Foundation
import SwiftUI

struct ScanVersion: Identifiable, Codable, Equatable {
    let id: String
    var createdAt: Date
    var frameCount: Int
    var meshReady: Bool
    var localMeshFileName: String?

    var displayTitle: String { id }
}

struct ScanProject: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var createdAt: Date
    var versions: [ScanVersion]

    var versionsNewestFirst: [ScanVersion] {
        versions.sorted { $0.createdAt > $1.createdAt }
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

    var projectsNewestFirst: [ScanProject] {
        projects.sorted { $0.createdAt > $1.createdAt }
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
        let project = ScanProject(
            id: UUID().uuidString.lowercased(),
            name: trimmed.isEmpty ? "Проект" : trimmed,
            createdAt: Date(),
            versions: []
        )
        projects.insert(project, at: 0)
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
        let version = ScanVersion(
            id: versionID,
            createdAt: Date(),
            frameCount: 0,
            meshReady: false,
            localMeshFileName: nil
        )
        let folder = ProjectPaths.versionFolder(projectID: projectID, versionID: versionID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FrameMetadataWriter.writeSeriesManifest(seriesName: versionID, folder: folder, frameCount: 0)
        projects[idx].versions.insert(version, at: 0)
        save()
        return version
    }

    func updateFrameCount(projectID: String, versionID: String, count: Int) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[pIdx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        guard projects[pIdx].versions[vIdx].frameCount != count else { return }
        projects[pIdx].versions[vIdx].frameCount = count
        save()
    }

    func markMeshReady(projectID: String, versionID: String, fileName: String) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let vIdx = projects[pIdx].versions.firstIndex(where: { $0.id == versionID }) else { return }
        projects[pIdx].versions[vIdx].meshReady = true
        projects[pIdx].versions[vIdx].localMeshFileName = fileName
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

    private func nextVersionID(projectID: String) -> String {
        let prefix = todayPrefix()
        let existing = project(id: projectID)?.versions.map(\.id) ?? []
        var maxIndex = 0
        let pattern = #"^\#(NSRegularExpression.escapedPattern(for: prefix))_(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return String(format: "%@_%03d", prefix, 1)
        }
        for name in existing {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  match.numberOfRanges == 2,
                  let idxRange = Range(match.range(at: 1), in: name),
                  let value = Int(name[idxRange]) else { continue }
            maxIndex = max(maxIndex, value)
        }
        return String(format: "%@_%03d", prefix, maxIndex + 1)
    }

    private func todayPrefix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
