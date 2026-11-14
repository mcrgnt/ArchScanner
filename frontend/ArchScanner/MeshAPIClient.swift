import Foundation

enum MeshAPIError: LocalizedError {
    case invalidBaseURL
    case httpStatus(Int, String)
    case missingJobID
    case emptySeries
    case notReady

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Некорректный Backend URL"
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .missingJobID:
            return "Ответ без job_id"
        case .emptySeries:
            return "Нет кадров в серии"
        case .notReady:
            return "Меш ещё не готов"
        }
    }
}

enum MeshFileStatus {
    case ready(Data, suggestedName: String)
    case processing
    case missing
}

actor MeshAPIClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func pingProjects() async throws {
        let url = baseURL.appendingPathComponent("api/v1/projects")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response: response, data: data, ok: [200])
    }

    func submitMesh(
        projectID: String,
        versionID: String,
        folder: URL,
        format: String = "usdz",
        maxImages: Int? = nil
    ) async throws -> String {
        let files = try seriesFiles(in: folder)
        guard !files.isEmpty else { throw MeshAPIError.emptySeries }

        let url = baseURL
            .appendingPathComponent("api/v1/projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("versions")
            .appendingPathComponent(versionID)
            .appendingPathComponent("mesh")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(
            boundary: boundary,
            files: files,
            format: format,
            maxImages: maxImages
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response: response, data: data, ok: [202, 200])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobID = json["job_id"] as? String,
              !jobID.isEmpty else {
            throw MeshAPIError.missingJobID
        }
        return jobID
    }

    func fetchMeshFile(projectID: String, versionID: String) async throws -> MeshFileStatus {
        let url = baseURL
            .appendingPathComponent("api/v1/projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("versions")
            .appendingPathComponent(versionID)
            .appendingPathComponent("mesh")
            .appendingPathComponent("file")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeshAPIError.httpStatus(-1, "no response")
        }
        switch http.statusCode {
        case 200:
            let name = filenameFrom(response: http) ?? "\(versionID).usdz"
            return .ready(data, suggestedName: name)
        case 202:
            return .processing
        case 404:
            return .missing
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MeshAPIError.httpStatus(http.statusCode, body)
        }
    }

    func jobStatus(jobID: String) async throws -> String {
        let url = baseURL
            .appendingPathComponent("api/v1/jobs")
            .appendingPathComponent(jobID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response: response, data: data, ok: [200])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return "unknown"
        }
        return status
    }

    private func seriesFiles(in folder: URL) throws -> [URL] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return urls
            .filter { !$0.hasDirectoryPath }
            .filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func multipartBody(
        boundary: String,
        files: [URL],
        format: String,
        maxImages: Int?
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        func append(_ string: String) {
            if let d = string.data(using: .utf8) {
                body.append(d)
            }
        }

        for file in files {
            let name = file.lastPathComponent
            let data = try Data(contentsOf: file)
            let mime: String
            switch file.pathExtension.lowercased() {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "json": mime = "application/json"
            default: mime = "application/octet-stream"
            }
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"frames\"; filename=\"\(name)\"\(crlf)")
            append("Content-Type: \(mime)\(crlf)\(crlf)")
            body.append(data)
            append(crlf)
        }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"format\"\(crlf)\(crlf)")
        append("\(format)\(crlf)")

        if let maxImages {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"max_images\"\(crlf)\(crlf)")
            append("\(maxImages)\(crlf)")
        }

        append("--\(boundary)--\(crlf)")
        return body
    }

    private func throwIfNeeded(response: URLResponse, data: Data, ok: [Int]) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MeshAPIError.httpStatus(-1, "no response")
        }
        guard ok.contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MeshAPIError.httpStatus(http.statusCode, body)
        }
    }

    private func filenameFrom(response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        // attachment; filename="foo.usdz"
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                var value = trimmed.dropFirst("filename=".count)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = value.dropFirst().dropLast()
                }
                return String(value)
            }
        }
        return nil
    }
}
