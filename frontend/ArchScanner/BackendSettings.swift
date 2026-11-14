import Foundation

struct BackendSettings: Codable, Equatable {
    /// Host or full URL, e.g. `100.64.0.2:8780` or `http://100.64.0.2:8780`
    var baseURL: String = ""

    var isConfigured: Bool {
        (try? resolvedBaseURL()) != nil
    }

    func resolvedBaseURL() throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw MeshAPIError.invalidBaseURL }
        if !raw.contains("://") {
            raw = "http://" + raw
        }
        while raw.hasSuffix("/") {
            raw.removeLast()
        }
        guard let url = URL(string: raw), url.host != nil else {
            throw MeshAPIError.invalidBaseURL
        }
        return url
    }
}

enum BackendSettingsStore {
    private static let key = "backendSettings.v1"

    static func load() -> BackendSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BackendSettings.self, from: data) else {
            return BackendSettings()
        }
        return decoded
    }

    static func save(_ settings: BackendSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum ProjectIdentity {
    private static let key = "archscanner.projectID"

    static func projectID() -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

enum MeshJobState: Equatable {
    case idle
    case submitting
    case processing(jobID: String)
    case ready
    case failed(String)

    var meshButtonTitle: String {
        switch self {
        case .idle: return "Меш"
        case .submitting: return "…"
        case .processing: return "Ждём"
        case .ready: return "Меш"
        case .failed: return "Ошибка"
        }
    }
}
