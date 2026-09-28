import Foundation
import Observation
import UIKit

@MainActor @Observable
final class ChatStore {
    private let rotationDateKey = "hermes.deviceKeyRotatedAt"
    var endpoint: String = {
        let saved = UserDefaults.standard.string(forKey: "hermes.endpoint")?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        #if targetEnvironment(simulator)
        let local = "http://localhost:8642"
        #else
        let local = "https://fixture-mac.local:8643"
        #endif
        return saved == nil || saved == "http://localhost:8642" || saved == "http://fixture-mac.local:8642" ? local : saved!
    }()
    var apiKey = KeychainStore.read() ?? KeychainStore.readLegacy() ?? ""
    var sessions: [ChatSession] = []
    var selectedSessionID: String?
    var messages: [ChatMessage] = []
    var isConnected = false
    var isSending = false
    var status = "Connect to your Hermes agent"
    var error: String?
    var draft = ""
    var pendingImage: PendingImage?
    var toolActivity: String?
    var pendingApproval: PendingApproval?

    var selectedSession: ChatSession? { sessions.first { $0.id == selectedSessionID } }

    private var api: HermesAPI? {
        try? HermesAPI(endpoint: endpoint, apiKey: apiKey)
    }
    @ObservationIgnored private var activeStream: Task<Void, Error>?

    func saveSettings(endpoint: String, apiKey: String) {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        UserDefaults.standard.set(self.endpoint, forKey: "hermes.endpoint")
        #if targetEnvironment(simulator)
        if !KeychainStore.saveLegacy(apiKey) { error = "Could not save the API key to Keychain." }
        #endif
    }

    func connect() async {
        guard var api else { error = apiKey.isEmpty ? HermesError.missingKey.localizedDescription : HermesError.invalidURL.localizedDescription; return }
        status = "Connecting…"
        do {
            #if !targetEnvironment(simulator)
            if KeychainStore.read() == nil, KeychainStore.readLegacy() != nil {
                let token = try await api.migrateLegacyKey()
                guard KeychainStore.save(token) else { throw HermesError.keychainFailure }
                KeychainStore.deleteLegacy()
                apiKey = token
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
                api = try HermesAPI(endpoint: endpoint, apiKey: token)
            }
            #endif
            try await api.checkConnection()
            isConnected = true
            status = "Connected to Hermes"
            error = nil
            sessions = try await api.sessions()
            if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                messages = []
            }
            if let selectedSessionID { await loadMessages(sessionID: selectedSessionID) }
            #if !targetEnvironment(simulator)
            let lastRotation = UserDefaults.standard.double(forKey: rotationDateKey)
            if KeychainStore.read() != nil && Date().timeIntervalSince1970 - lastRotation > 30 * 24 * 60 * 60 {
                await rotateDeviceKey()
            }
            #endif
        } catch { isConnected = false; status = "Hermes is unavailable"; self.error = error.localizedDescription }
    }

    func pair(from url: URL) async {
        guard url.scheme == "hermespocket", url.host == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return }
        status = "Pairing this iPhone…"
        do {
            let token = try await HermesAPI.claimPairing(endpoint: endpoint, code: code, name: UIDevice.current.name)
            guard KeychainStore.save(token) else { throw HermesError.keychainFailure }
            KeychainStore.deleteLegacy()
            apiKey = token
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
            await connect()
        } catch { status = "Pairing failed"; self.error = error.localizedDescription }
    }

    func rotateDeviceKey() async {
        guard KeychainStore.read() != nil, let api else { error = "Pair this device first."; return }
        do {
            let token = try await api.rotateDeviceKey()
            guard KeychainStore.save(token) else { throw HermesError.keychainFailure }
            apiKey = token
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
            status = "Device access rotated"
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func createSession() async {
        guard let api else { error = HermesError.missingKey.localizedDescription; return }
        do {
            let session = try await api.createSession()
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
            messages = []
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func select(_ session: ChatSession) async {
        selectedSessionID = session.id
        messages = []
        await loadMessages(sessionID: session.id)
    }

    func loadMessages(sessionID: String) async {
        guard let api else { return }
        do { messages = try await api.messages(sessionID: sessionID); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func send() async {
        guard !isSending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil else { return }
        guard let api else { error = HermesError.missingKey.localizedDescription; return }
        isSending = true
        error = nil
        toolActivity = nil
        draft = ""
        pendingImage = nil
        if selectedSessionID == nil {
            do {
                let session = try await api.createSession()
                sessions.insert(session, at: 0)
                selectedSessionID = session.id
            } catch {
                draft = text
                pendingImage = image
                self.error = error.localizedDescription
                isSending = false
                return
            }
        }
        guard let sessionID = selectedSessionID else { isSending = false; error = HermesError.noSession.localizedDescription; return }
        let user = ChatMessage(role: .user, content: text.isEmpty ? "[Image]" : text + (image == nil ? "" : "\n[Image]"), timestamp: Date())
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true, timestamp: Date())
        messages.append(contentsOf: [user, reply])
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].lastActive = user.timestamp
        }
        do {
            activeStream = Task { [weak self] in
                try await api.send(sessionID: sessionID, text: text, image: image) { [weak self] event, payload in
                await self?.handle(event: event, payload: payload, messageID: reply.id)
                }
            }
            try await activeStream?.value
            activeStream = nil
            if let last = messages.lastIndex(where: { $0.id == reply.id }), messages[last].isStreaming {
                messages[last].isStreaming = false
            }
            isSending = false
            activeStream = nil
            toolActivity = nil
            let streamedError = error
            await loadMessages(sessionID: sessionID)
            if let streamedError { error = streamedError }
            sessions = (try? await api.sessions()) ?? sessions
        } catch {
            activeStream = nil
            if let last = messages.lastIndex(where: { $0.id == reply.id }) {
                messages[last].isStreaming = false
                if messages[last].content.isEmpty { messages[last].content = "The response was interrupted. Your conversation is saved; reconnect and refresh before retrying." }
            }
            isSending = false
            toolActivity = nil
            self.error = error.localizedDescription
        }
    }

    func stop() { activeStream?.cancel() }

    func respondToApproval(_ choice: String) async {
        guard let approval = pendingApproval, let api else { return }
        do {
            try await api.respondToApproval(runID: approval.runID, requestID: approval.requestID, choice: choice)
            pendingApproval = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func handle(event: String, payload: [String: Any], messageID: String) {
        guard let index = messages.lastIndex(where: { $0.id == messageID }) else { return }
        switch event {
        case "assistant.delta":
            messages[index].content += payload["delta"] as? String ?? ""
        case "assistant.completed":
            if let content = payload["content"] as? String { messages[index].content = content }
            messages[index].isStreaming = false
        case "tool.started":
            toolActivity = payload["tool_name"] as? String ?? "Hermes is using a tool"
        case "tool.completed", "tool.failed":
            toolActivity = nil
        case "approval.request":
            guard let runID = payload["run_id"] as? String else { return }
            let command = payload["command"] as? String ?? payload["description"] as? String ?? "Hermes is requesting permission to run an action."
            pendingApproval = PendingApproval(id: payload["request_id"] as? String ?? UUID().uuidString,
                                              runID: runID,
                                              requestID: payload["request_id"] as? String,
                                              summary: command,
                                              choices: payload["choices"] as? [String] ?? ["once", "deny"])
        case "error", "run.failed":
            error = (payload["message"] as? String) ?? (payload["error"] as? String) ?? "Hermes could not complete this turn."
            messages[index].isStreaming = false
        case "run.completed", "run.cancelled":
            messages[index].isStreaming = false
        default:
            break
        }
    }
}
