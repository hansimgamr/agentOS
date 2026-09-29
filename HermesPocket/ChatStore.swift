import Foundation
import Observation
import UIKit

@MainActor @Observable
final class ChatStore {
    private let rotationDateKey = "hermes.deviceKeyRotatedAt"
    private let legacyFingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    var endpoint: String
    var apiKey: String
    var pairingCandidate: PairingQR?
    private var pairingInProgress = false
    private var rotationInProgress = false
    @ObservationIgnored private var connectionRevision = 0
    var sessions: [ChatSession] = []
    var selectedSessionID: String?
    var messages: [ChatMessage] = []
    var isConnected = false
    var deletingSessionIDs: Set<String> = []
    var isSending = false
    var status = "Connect to your Hermes agent"
    var error: String?
    var draft = ""
    var pendingImage: PendingImage?
    var toolActivity: String?
    var pendingApproval: PendingApproval?

    var selectedSession: ChatSession? { sessions.first { $0.id == selectedSessionID } }
    var isPairing: Bool { pairingInProgress }

    init() {
        if let profile = KeychainStore.readProfile() {
            endpoint = profile.endpoint
            apiKey = profile.token
            return
        }
        #if targetEnvironment(simulator)
        let localEndpoint = "http://localhost:8642"
        #else
        let localEndpoint = "https://fixture-mac.local:8643"
        #endif
        let savedEndpoint = UserDefaults.standard.string(forKey: "hermes.endpoint")
            .flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        endpoint = savedEndpoint == "http://localhost:8642" || savedEndpoint == "http://fixture-mac.local:8642" ? localEndpoint : (savedEndpoint ?? localEndpoint)
        let oldDeviceToken = KeychainStore.read()
        apiKey = oldDeviceToken ?? KeychainStore.readLegacy() ?? ""
        if let oldDeviceToken, (endpoint == "https://fixture-mac.local:8643" || endpoint == "https://fixture-mac.local:8643") {
            let migrated = HermesConnectionProfile(endpoint: endpoint, fingerprint: legacyFingerprint, token: oldDeviceToken, deviceID: nil)
            if KeychainStore.saveProfile(migrated) {
                KeychainStore.deleteDeviceKey()
                KeychainStore.deleteLegacy()
            }
        }
    }

    private var api: HermesAPI? {
        if let profile = KeychainStore.readProfile() {
            return try? HermesAPI(endpoint: profile.endpoint, apiKey: profile.token, fingerprint: profile.fingerprint)
        }
        guard endpoint == "https://fixture-mac.local:8643" || endpoint == "https://fixture-mac.local:8643"
                || endpoint == "http://localhost:8642" else { return nil }
        return try? HermesAPI(endpoint: endpoint, apiKey: apiKey, fingerprint: legacyFingerprint)
    }
    @ObservationIgnored private var activeStream: Task<Void, Error>?

    func saveSettings(endpoint: String, apiKey: String) {
        #if targetEnvironment(simulator)
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        UserDefaults.standard.set(self.endpoint, forKey: "hermes.endpoint")
        if !KeychainStore.saveLegacy(apiKey) { error = "Could not save the API key to Keychain." }
        #endif
    }

    func connect() async {
        let revision = connectionRevision
        guard var api else { error = apiKey.isEmpty ? HermesError.missingKey.localizedDescription : HermesError.invalidURL.localizedDescription; return }
        status = "Connecting…"
        do {
            #if !targetEnvironment(simulator)
            if KeychainStore.readProfile() == nil, KeychainStore.read() == nil, KeychainStore.readLegacy() != nil {
                let token = try await api.migrateLegacyKey()
                let profile = HermesConnectionProfile(endpoint: endpoint, fingerprint: legacyFingerprint, token: token, deviceID: nil)
                guard KeychainStore.saveProfile(profile) else { throw HermesError.keychainFailure }
                KeychainStore.deleteLegacy()
                apiKey = token
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
                api = try HermesAPI(endpoint: endpoint, apiKey: token, fingerprint: legacyFingerprint)
            }
            #endif
            guard revision == connectionRevision else { return }
            try await api.checkConnection()
            guard revision == connectionRevision else { return }
            isConnected = true
            status = "Connected to Hermes"
            error = nil
            let refreshedSessions = try await api.sessions()
            guard revision == connectionRevision else { return }
            sessions = refreshedSessions
            if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                messages = []
            }
            if let selectedSessionID {
                let refreshedMessages = try await api.messages(sessionID: selectedSessionID)
                guard revision == connectionRevision else { return }
                messages = refreshedMessages
            }
            #if !targetEnvironment(simulator)
            let lastRotation = UserDefaults.standard.double(forKey: rotationDateKey)
            if !apiKey.isEmpty && Date().timeIntervalSince1970 - lastRotation > 30 * 24 * 60 * 60 {
                await rotateDeviceKey()
            }
            #endif
        } catch {
            guard revision == connectionRevision else { return }
            isConnected = false
            status = "Hermes is unavailable"
            self.error = error.localizedDescription
        }
    }

    func preparePair(from url: URL) {
        guard !pairingInProgress, !rotationInProgress, !isSending else { return }
        let profile = KeychainStore.readProfile()
        let legacyEndpoint = profile?.endpoint ?? (["https://fixture-mac.local:8643", "https://fixture-mac.local:8643"].contains(endpoint)
            ? endpoint : "https://fixture-mac.local:8643")
        let candidate = PairingQR.parse(url, trustedEndpoint: legacyEndpoint,
                                        trustedFingerprint: profile?.fingerprint ?? legacyFingerprint)
        guard let candidate else {
            error = "This pairing QR code is invalid or unsupported."
            return
        }
        pairingCandidate = candidate
        error = nil
    }

    func cancelPairing() { pairingCandidate = nil }

    func disconnect() {
        connectionRevision += 1
        activeStream?.cancel()
        activeStream = nil
        KeychainStore.deleteProfile()
        KeychainStore.deleteDeviceKey()
        KeychainStore.deleteLegacy()
        apiKey = ""
        sessions = []
        messages = []
        selectedSessionID = nil
        pendingApproval = nil
        pendingImage = nil
        toolActivity = nil
        draft = ""
        isSending = false
        isConnected = false
        status = "Connect to your Hermes agent"
    }

    func confirmPairing(_ candidate: PairingQR) async {
        guard !pairingInProgress, !rotationInProgress, !isSending,
              pairingCandidate == nil || pairingCandidate == candidate else { return }
        pairingInProgress = true
        defer { pairingInProgress = false }
        let revision = connectionRevision
        let previousStatus = status
        let wasConnected = isConnected
        if pairingCandidate == candidate { pairingCandidate = nil }
        status = "Pairing this iPhone…"
        do {
            let result = try await HermesAPI.claimPairing(candidate, name: UIDevice.current.name)
            let profile = HermesConnectionProfile(endpoint: candidate.endpoint, fingerprint: candidate.fingerprint,
                                                  token: result.token, deviceID: result.deviceID)
            let candidateAPI = try HermesAPI(endpoint: profile.endpoint, apiKey: profile.token, fingerprint: profile.fingerprint)
            try await candidateAPI.checkConnection()
            guard revision == connectionRevision else { return }
            guard KeychainStore.saveProfile(profile) else { throw HermesError.keychainFailure }
            connectionRevision += 1
            KeychainStore.deleteDeviceKey()
            KeychainStore.deleteLegacy()
            apiKey = result.token
            endpoint = candidate.endpoint
            sessions = []
            selectedSessionID = nil
            messages = []
            draft = ""
            pendingImage = nil
            pendingApproval = nil
            toolActivity = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
            await connect()
        } catch { status = wasConnected ? previousStatus : "Pairing failed"; self.error = error.localizedDescription }
    }

    func rotateDeviceKey() async {
        guard !rotationInProgress, !pairingInProgress, !apiKey.isEmpty, let api else { error = "Pair this device first."; return }
        rotationInProgress = true
        defer { rotationInProgress = false }
        let credential = apiKey
        let oldProfile = KeychainStore.readProfile()
        do {
            let token = try await api.rotateDeviceKey()
            guard apiKey == credential, KeychainStore.readProfile() == oldProfile else { return }
            if let oldProfile {
                let updated = HermesConnectionProfile(endpoint: oldProfile.endpoint, fingerprint: oldProfile.fingerprint,
                                                      token: token, deviceID: oldProfile.deviceID)
                guard KeychainStore.saveProfile(updated) else { throw HermesError.keychainFailure }
            } else {
                guard KeychainStore.save(token) else { throw HermesError.keychainFailure }
            }
            connectionRevision += 1
            apiKey = token
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rotationDateKey)
            status = "Device access rotated"
            error = nil
        } catch {
            guard apiKey == credential, KeychainStore.readProfile() == oldProfile else { return }
            self.error = error.localizedDescription
        }
    }

    func searchChats(_ query: String) async throws -> [ChatSession] {
        guard let api else { throw HermesError.missingKey }
        var results: [ChatSession] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await api.sessions(offset: offset, limit: 200)
            let previousCount = seen.count
            for var session in page where seen.insert(session.id).inserted {
                if session.title.localizedStandardContains(query) {
                    results.append(session)
                } else if let snippet = try await api.searchMessages(sessionID: session.id, query: query) {
                    session.preview = snippet
                    results.append(session)
                }
            }
            if page.count < 200 || seen.count == previousCount { return results }
            offset += page.count
        }
    }

    func deleteSession(_ id: String) async throws {
        guard !isSending, !deletingSessionIDs.contains(id) else { return }
        guard let api else { throw HermesError.missingKey }
        deletingSessionIDs.insert(id)
        defer { deletingSessionIDs.remove(id) }
        try await api.deleteSession(id: id)
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = nil
            messages = []
            pendingApproval = nil
            toolActivity = nil
            draft = ""
            pendingImage = nil
        }
    }

    @discardableResult
    func startNewConversation() -> Bool {
        guard !isSending, !pairingInProgress else { return false }
        selectedSessionID = nil
        messages = []
        draft = ""
        pendingImage = nil
        pendingApproval = nil
        toolActivity = nil
        error = nil
        return true
    }

    func select(_ session: ChatSession) async {
        selectedSessionID = session.id
        messages = []
        await loadMessages(sessionID: session.id)
    }

    func loadMessages(sessionID: String) async {
        guard let api else { return }
        do {
            let loaded = try await api.messages(sessionID: sessionID)
            guard selectedSessionID == sessionID else { return }
            messages = loaded
            error = nil
        } catch {
            guard selectedSessionID == sessionID else { return }
            self.error = error.localizedDescription
        }
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
