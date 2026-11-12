import Foundation
import CryptoKit

enum S3ExportError: LocalizedError {
    case invalidEndpoint
    case httpStatus(Int, String)
    case emptySeries

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Некорректный endpoint"
        case .httpStatus(let code, let body): return "S3 HTTP \(code): \(body.prefix(200))"
        case .emptySeries: return "Нет файлов для экспорта"
        }
    }
}

actor S3Exporter {
    let config: S3ExportConfig

    init(config: S3ExportConfig) {
        self.config = config
    }

    func ensureBucket() async throws {
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try objectURL(key: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request = try sign(request, canonicalURI: "/\(bucket)", payloadHash: emptyPayloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        // 200 created, 409 already exists — both OK for MinIO/AWS
        if !(200..<300).contains(http.statusCode) && http.statusCode != 409 {
            throw S3ExportError.httpStatus(http.statusCode, "")
        }
    }

    func uploadFile(localURL: URL, key: String, contentType: String) async throws {
        let data = try Data(contentsOf: localURL)
        try await put(key: key, data: data, contentType: contentType)
    }

    func put(key: String, data: Data, contentType: String) async throws {
        let url = try objectURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data

        let payloadHash = sha256Hex(data)
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalURI = "/\(bucket)/\(key.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"))"
        request = try sign(request, canonicalURI: canonicalURI, payloadHash: payloadHash)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3ExportError.httpStatus(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw S3ExportError.httpStatus(http.statusCode, body)
        }
    }

    // MARK: - URL

    private func objectURL(key: String?) throws -> URL {
        let base = try config.baseURL()
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = "/\(bucket)"
        if let key, !key.isEmpty {
            path += "/" + key
        }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw S3ExportError.invalidEndpoint
        }
        return url
    }

    // MARK: - SigV4

    private var emptyPayloadHash: String {
        sha256Hex(Data())
    }

    private func sign(_ request: URLRequest, canonicalURI: String, payloadHash: String) throws -> URLRequest {
        var req = request
        let now = Date()
        let amzDate = amzDateString(now)
        let dateStamp = String(amzDate.prefix(8))
        let region = config.region.isEmpty ? "us-east-1" : config.region
        let service = "s3"
        let host = try hostHeader()

        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let contentType = req.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

        let canonicalHeaders =
            "content-type:\(contentType)\n" +
            "host:\(host)\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(amzDate)\n"

        let canonicalRequest = [
            req.httpMethod ?? "PUT",
            canonicalURI,
            "", // query
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = awsSigningKey(
            secret: config.secretKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let accessKey = config.accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorization =
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    private func hostHeader() throws -> String {
        let base = try config.baseURL()
        guard let host = base.host else { throw S3ExportError.invalidEndpoint }
        if let port = base.port {
            return "\(host):\(port)"
        }
        return host
    }

    private func amzDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hmac(_ key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private func hmacHex(key: Data, data: Data) -> String {
        hmac(key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func awsSigningKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(kDate, data: Data(region.utf8))
        let kService = hmac(kRegion, data: Data(service.utf8))
        return hmac(kService, data: Data("aws4_request".utf8))
    }
}
