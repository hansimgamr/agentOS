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
