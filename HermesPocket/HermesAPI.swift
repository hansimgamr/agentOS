import Foundation
import CryptoKit
import Security

private final class RelayTrust: NSObject, URLSessionTaskDelegate {
    private let host: String
    private let fingerprint: String

    init(host: String, fingerprint: String) {
        self.host = host.lowercased()
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge,
                          completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host.lowercased()
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.port == 8643, host == self.host,
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

final class HermesAPI: Sendable {
    private let session: URLSession
    private let trust: RelayTrust
    let baseURL: URL
    let apiKey: String

    init(endpoint: String, apiKey: String, fingerprint: String) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw HermesError.invalidURL }
        #if !targetEnvironment(simulator)
        guard scheme == "https", url.port == 8643, PairingQR.isLocalHost(host) else { throw HermesError.invalidURL }
        #endif
        if scheme == "http" && !["localhost"].contains(host) { throw HermesError.invalidURL }
        guard !apiKey.isEmpty else { throw HermesError.missingKey }
        self.baseURL = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")!
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let trust = RelayTrust(host: host, fingerprint: fingerprint)
        self.trust = trust
        self.session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

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
        let (data, response) = try await session.data(for: request("/health"))
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

    static func claimPairing(_ pairing: PairingQR, name: String) async throws -> (token: String, deviceID: String, certificateAcceptedAt: Date?) {
        let api = try HermesAPI(endpoint: pairing.endpoint, apiKey: "pairing", fingerprint: pairing.fingerprint)
        var req = URLRequest(url: api.url("/pair/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": pairing.code, "name": name])
        let (data, response) = try await api.session.data(for: req)
        try api.check(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceID = root["device_id"] as? String, deviceID.count == 16,
              deviceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HermesError.malformedResponse
        }
        return (try token(from: data), deviceID, (root["certificate_accepted_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    private static func token(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String, !token.isEmpty else { throw HermesError.malformedResponse }
        return token
    }

    func sessions(offset: Int = 0, limit: Int = 50) async throws -> [ChatSession] {
        let data = try await get("/api/sessions?limit=\(limit)&offset=\(offset)")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw HermesError.malformedResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let date = (row["last_active"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return ChatSession(id: id, title: row["title"] as? String,
                              preview: row["preview"] as? String, lastActive: date, modelName: row["model"] as? String)
        }
    }

    func searchMessages(sessionID: String, query: String) async throws -> String? {
        let id = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        var offset = 0
        while true {
            try Task.checkCancellation()
            let data = try await get("/api/sessions/\(id)/messages?limit=500&offset=\(offset)&order=oldest")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["data"] as? [[String: Any]] else { throw HermesError.malformedResponse }
            for row in rows {
                let text = Self.textContent(row["content"])
                if let snippet = ChatSearch.snippet(in: text, query: query) { return snippet }
            }
            if rows.count < 500 { return nil }
            offset += rows.count
        }
    }

    func deleteSession(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let (data, response) = try await session.data(for: request("/api/sessions/\(encoded)", method: "DELETE"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try check(response, data: data)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["deleted"] as? Bool == true else { throw HermesError.malformedResponse }
    }

    func createSession() async throws -> ChatSession {
        let data = try await post("/api/sessions", json: [:])
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
                               timestamp: (row["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }, modelName: row["model"] as? String)
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
        let (bytes, response) = try await session.bytes(for: req, delegate: trust)
        guard let http = response as? HTTPURLResponse else { throw HermesError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = "Request failed"
            var lineCount = 0
            for try await line in bytes.lines { body += " " + line; lineCount += 1; if lineCount == 8 { break } }
            throw HermesError.badResponse(http.statusCode, String(body.prefix(260)))
        }

        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw HermesError.malformedResponse
        }
        var decoder = ServerEventDecoder()
        var runCompleted = false
        func deliver(_ event: ServerEventDecoder.Event) async throws -> Bool {
            await receive(event.name, event.payload)
            switch event.name {
            case "error", "run.failed", "run.cancelled":
                let message = event.payload["message"] as? String ?? event.payload["error"] as? String
                    ?? (event.name == "run.cancelled" ? "Hermes stopped this response." : "Hermes could not complete this response.")
                throw HermesError.streamFailed(message)
            case "run.completed": runCompleted = true
            case "done":
                guard runCompleted else { throw HermesError.streamInterrupted }
                return true
            default: break
            }
            return false
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try decoder.append(byte), try await deliver(event) { return }
        }
        if let event = try decoder.finish(), try await deliver(event) { return }
        throw HermesError.streamInterrupted
    }

    func respondToApproval(runID: String, requestID: String?, choice: String) async throws {
        var body: [String: Any] = ["choice": choice]
        if let requestID { body["request_id"] = requestID }
        let pathID = runID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runID
        _ = try await post("/v1/runs/\(pathID)/approval", json: body)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(path))
        try check(response, data: data)
        return data
    }

    private func post(_ path: String, json: [String: Any]) async throws -> Data {
        let (data, response) = try await session.data(for: request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: json)))
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

// Parse bytes rather than AsyncBytes.lines, which omits the blank separators SSE needs.
struct ServerEventDecoder {
    struct Event { let name: String; let payload: [String: Any] }
    private var line = Data()
    private var name = "message"
    private var dataLines: [String] = []
    private var afterCR = false
    private var size = 0
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> Event? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            return try endLine()
        }
        size += 1
        guard size <= 8 * 1024 * 1024 else { throw HermesError.malformedResponse }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Event? {
        if !line.isEmpty, let event = try endLine() { return event }
        return try flush()
    }

    private mutating func endLine() throws -> Event? {
        guard var text = String(data: line, encoding: .utf8) else { throw HermesError.malformedResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
        if text.isEmpty { return try flush() }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if parts[0] == "event" { name = value }
        else if parts[0] == "data" { dataLines.append(value) }
        return nil
    }

    private mutating func flush() throws -> Event? {
        defer { name = "message"; dataLines.removeAll(keepingCapacity: true); size = 0 }
        guard !dataLines.isEmpty else { return nil }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError.malformedResponse
        }
        return Event(name: name, payload: payload)
    }
}
