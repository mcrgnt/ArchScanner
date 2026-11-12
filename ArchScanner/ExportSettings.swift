import Foundation

enum ExportMethod: String, Codable, CaseIterable, Identifiable {
    case s3 = "s3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .s3: return "S3 / MinIO"
        }
    }
}

struct S3ExportConfig: Codable, Equatable {
    var endpoint: String = ""
    var accessKey: String = ""
    var secretKey: String = ""
    var bucket: String = "archscanner"
    var region: String = "us-east-1"
    var prefix: String = "scans"
    var useSSL: Bool = false
    var pathStyle: Bool = true

    var isConfigured: Bool {
        let host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty
            && !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Normalized base URL without trailing slash, e.g. http://192.168.1.10:9000
    func baseURL() throws -> URL {
        var raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { throw S3ExportError.invalidEndpoint }
        if !raw.contains("://") {
            raw = (useSSL ? "https://" : "http://") + raw
        }
        guard var components = URLComponents(string: raw), let host = components.host, !host.isEmpty else {
            throw S3ExportError.invalidEndpoint
        }
        if components.scheme == nil {
            components.scheme = useSSL ? "https" : "http"
        }
        guard let url = components.url else { throw S3ExportError.invalidEndpoint }
        return url
    }
}

struct ExportSettings: Codable, Equatable {
    var method: ExportMethod = .s3
    var s3: S3ExportConfig = S3ExportConfig()

    var isConfigured: Bool {
        switch method {
        case .s3: return s3.isConfigured
        }
    }
}

enum ExportSettingsStore {
    private static let key = "exportSettings.v1"

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ExportSettings.self, from: data) else {
            return ExportSettings()
        }
        return decoded
    }

    static func save(_ settings: ExportSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum SeriesExportState: Equatable {
    case idle
    case exporting(done: Int, total: Int)
    case success
    case failed(String)

    var buttonTitle: String {
        switch self {
        case .idle: return "Экспорт"
        case .exporting(let done, let total): return "\(done)/\(total)"
        case .success: return "Готово"
        case .failed: return "Ошибка"
        }
    }
}
