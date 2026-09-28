import Foundation
import CryptoKit
import Security

private final class RelayTrust: NSObject, URLSessionDelegate {
    private let fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host.lowercased()
        guard challenge.protectionSpace.port == 8643,
              host == "fixture-mac.local" || host == "fixture-mac.local" else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HermesAPI: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RelayTrust(), delegateQueue: nil)
    }()
    let baseURL: URL
    let apiKey: String

    init(endpoint: String, apiKey: String) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw HermesError.invalidURL }
        #if !targetEnvironment(simulator)
        guard scheme == "https", url.port == 8643,
              ["fixture-mac.local", "fixture-mac.local"].contains(url.host!.lowercased()) else {
            throw HermesError.invalidURL
        }
        #endif
        if scheme == "http" && !["localhost", "localhost"].contains(url.host!.lowercased()) {
            throw HermesError.invalidURL
        }
        guard !apiKey.isEmpty else { throw HermesError.missingKey }
        self.baseURL = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")!
        self.apiKey = apiKey
    }

    private func url(_ path: String) -> URL {
        let relativePath = String(path.drop(while: { $0 == "/" }))
        return URL(string: relativePath, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 60
        return request
    }

    func checkConnection() async throws {
        let (data, response) = try await Self.session.data(for: request("/health"))
        try check(response, data: data)
    }

    func migrateLegacyKey() async throws -> String {
        let data = try await post("/pair/migrate", json: [:])
        return try Self.token(from: data)
    }

    func rotateDeviceKey() async throws -> String {
        let data = try await post("/device/rotate", json: [:])
        return try Self.token(from: data)
    }

    static func claimPairing(endpoint: String, code: String, name: String) async throws -> String {
        let api = try HermesAPI(endpoint: endpoint, apiKey: "pairing")
        var req = URLRequest(url: api.url("/pair/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        let (data, response) = try await session.data(for: req)
        try api.check(response, data: data)
        return try token(from: data)
    }

    private static func token(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String, !token.isEmpty else { throw HermesError.malformedResponse }
        return token
    }

    func sessions() async throws -> [ChatSession] {
        let data = try await get("/api/sessions?limit=50")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw HermesError.malformedResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let date = (row["last_active"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return ChatSession(id: id, title: row["title"] as? String,
                              preview: row["preview"] as? String, lastActive: date)
        }
    }

    func createSession() async throws -> ChatSession {
        let data = try await post("/api/sessions", json: ["title": "New conversation"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let id = session["id"] as? String else { throw HermesError.malformedResponse }
        return ChatSession(id: id, title: session["title"] as? String,
                           lastActive: (session["last_active"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date())
    }

    func messages(sessionID: String) async throws -> [ChatMessage] {
        let path = "/api/sessions/\(sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID)/messages?limit=100&order=latest"
        let data = try await get(path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw HermesError.malformedResponse }
        return rows.compactMap { row in
            guard let rawRole = row["role"] as? String,
                  let role = ChatMessage.Role(rawValue: rawRole) else { return nil }
            let content = Self.textContent(row["content"])
            guard !content.isEmpty else { return nil }
            return ChatMessage(id: row["id"] as? String ?? UUID().uuidString, role: role, content: content,
                               timestamp: (row["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
    }

    func send(sessionID: String, text: String, image: PendingImage?,
              receive: @escaping @Sendable (String, [String: Any]) async -> Void) async throws {
        let encodedID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        var content: [[String: Any]] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "text", "text": text])
        }
        if let image {
            let base64 = image.data.base64EncodedString()
            content.append(["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(base64)", "detail": "high"]])
        }
        let input: Any = content.count == 1 && image == nil ? text : content
        let payload: [String: Any] = ["input": input]
        var req = request("/api/sessions/\(encodedID)/chat/stream", method: "POST",
                          body: try JSONSerialization.data(withJSONObject: payload))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw HermesError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = "Request failed"
            var lineCount = 0
            for try await line in bytes.lines { body += " " + line; lineCount += 1; if lineCount == 8 { break } }
            throw HermesError.badResponse(http.statusCode, String(body.prefix(260)))
        }

        var event = "message"
        var dataLines: [String] = []
        for try await line in bytes.lines {
            if line.isEmpty {
                if !dataLines.isEmpty,
                   let data = dataLines.joined(separator: "\n").data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    await receive(event, object)
                }
                event = "message"
                dataLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    func respondToApproval(runID: String, requestID: String?, choice: String) async throws {
        var body: [String: Any] = ["choice": choice]
        if let requestID { body["request_id"] = requestID }
        let pathID = runID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runID
        _ = try await post("/v1/runs/\(pathID)/approval", json: body)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request(path))
        try check(response, data: data)
        return data
    }

    private func post(_ path: String, json: [String: Any]) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: json)))
        try check(response, data: data)
        return data
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw HermesError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Request failed"
            throw HermesError.badResponse(http.statusCode, String(message.prefix(260)))
        }
    }

    private static func textContent(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part["text"] as? String { return text }
            if let text = part["content"] as? String { return text }
            if part["type"] as? String == "image_url" { return "[Image]" }
            return nil
        }.joined(separator: "\n")
    }
}
