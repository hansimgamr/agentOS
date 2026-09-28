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
    var isStreaming: Bool = false

    init(id: String = UUID().uuidString, role: Role, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
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
