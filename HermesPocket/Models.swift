import Foundation

struct ChatSession: Identifiable, Hashable {
    let id: String
    var title: String
    var preview: String
    var lastActive: Date?

    init(id: String, title: String? = nil, preview: String? = nil, lastActive: Date? = nil) {
        self.id = id
        self.title = title?.isEmpty == false ? title! : "New conversation"
        self.preview = preview ?? ""
        self.lastActive = lastActive
    }
}

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, tool }
    let id: String
    var role: Role
    var content: String
    var timestamp: Date?
    var isStreaming: Bool = false

    init(id: String = UUID().uuidString, role: Role, content: String, isStreaming: Bool = false, timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
}

struct PendingApproval: Identifiable {
    let id: String
    let runID: String
    let requestID: String?
    let summary: String
    let choices: [String]
}

enum HermesError: LocalizedError {
    case invalidURL, missingKey, keychainFailure, badResponse(Int, String), malformedResponse, noSession

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid Hermes API URL."
        case .missingKey: "Pair this device with the QR code shown on your Mac."
        case .keychainFailure: "Could not save this device's access in Keychain."
        case let .badResponse(code, message): "Hermes returned HTTP \(code): \(message)"
        case .malformedResponse: "Hermes returned an unreadable response."
        case .noSession: "Create a conversation before sending a message."
        }
    }
}

struct PairingQR: Equatable {
    let endpoint: String
    let host: String
    let fingerprint: String
    let code: String

    static func parse(_ url: URL, trustedEndpoint: String? = nil, trustedFingerprint: String? = nil) -> PairingQR? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "hermespocket", components.host == "pair", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems,
              items.allSatisfy({ $0.value != nil }) else { return nil }
        if items.count == 1, items[0].name == "code",
           let trustedEndpoint, let trustedFingerprint,
           let endpoint = URLComponents(string: trustedEndpoint),
           endpoint.scheme == "https", endpoint.port == 8643,
           let host = endpoint.host?.lowercased(),
           Self.isLocalHost(host),
           trustedFingerprint.count == 64,
           trustedFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
           let code = items[0].value, Self.isPairingCode(code) {
            return PairingQR(endpoint: "https://\(host):8643", host: host,
                             fingerprint: trustedFingerprint, code: code)
        }
        guard items.count == 4,
              Set(items.map(\.name)) == ["v", "endpoint", "fingerprint", "code"] else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard values["v"] == "2",
              let endpoint = values["endpoint"], let endpointURL = URLComponents(string: endpoint),
              endpointURL.scheme == "https", endpointURL.user == nil, endpointURL.password == nil,
              endpointURL.port == 8643, endpointURL.path.isEmpty || endpointURL.path == "/",
              endpointURL.query == nil, endpointURL.fragment == nil,
              endpointURL.percentEncodedPath.isEmpty || endpointURL.percentEncodedPath == "/",
              let host = endpointURL.host?.lowercased(), Self.isLocalHost(host),
              let fingerprint = values["fingerprint"], fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let code = values["code"], Self.isPairingCode(code) else { return nil }
        return PairingQR(endpoint: "https://\(endpointURL.host!.lowercased()):8643", host: host,
                         fingerprint: fingerprint, code: code)
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") {
            let labels = host.dropLast(6).split(separator: ".", omittingEmptySubsequences: false)
            return !labels.isEmpty && labels.allSatisfy { label in
                !label.isEmpty && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 192 && octets[1] == 168
            || octets[0] == 172 && (16...31).contains(octets[1])
            || octets[0] == 169 && octets[1] == 254
    }

    private static func isPairingCode(_ code: String) -> Bool {
        code.count == 43 && code.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

// Keep timestamps compact while avoiding ambiguous dates across years.
enum ChatTimestamp {
    static func label(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
            ? "MMM d · h:mm a" : "MMM d, yyyy · h:mm a"
        return formatter.string(from: date)
    }
}


enum ChatSearch {
    static func snippet(in text: String, query: String) -> String? {
        guard !query.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(180))
    }
}
