import Foundation
import LocalAuthentication
import Observation
import UIKit

@MainActor @Observable
final class ChatStore {
    private let rotationDateKey = "hermes.deviceKeyRotatedAt"
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
    var status = "Not connected"
    private(set) var isRemovingPairing = false
    private(set) var isChangingAppProtection = false
    var appProtectionError: String?
    var needsPairing = false
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
        endpoint = UserDefaults.standard.string(forKey: "hermes.endpoint") ?? "http://localhost:8642"
        apiKey = KeychainStore.readLegacy() ?? ""
        #else
        endpoint = ""
        apiKey = ""
        #endif
    }

    private var api: HermesAPI? {
        if let profile = KeychainStore.readProfile() {
            return try? HermesAPI(endpoint: profile.endpoint, apiKey: profile.token, fingerprint: profile.fingerprint)
        }
        #if targetEnvironment(simulator)
        return try? HermesAPI(endpoint: endpoint, apiKey: apiKey, fingerprint: "")
        #else
        return nil
        #endif
    }
    @ObservationIgnored private var activeStream: Task<Void, Error>?
    @ObservationIgnored private var activeSendID: UUID?
    @ObservationIgnored private var activeSendAccepted = false
    @ObservationIgnored private var sendStopRequested = false

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
        guard !apiKey.isEmpty else { isConnected = false; needsPairing = false; error = nil; status = "Not connected"; return }
        guard let api else { error = apiKey.isEmpty ? HermesError.missingKey.localizedDescription : HermesError.invalidURL.localizedDescription; return }
        status = "Connecting…"
        do {
            guard revision == connectionRevision else { return }
            try await api.checkConnection()
            guard revision == connectionRevision else { return }
            needsPairing = false
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
                messages = withStoredModels(refreshedMessages, sessionID: selectedSessionID)
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
            recordError(error)
        }
    }

    private func recordError(_ failure: Error) {
        if case HermesError.badResponse(401, _) = failure, !apiKey.isEmpty {
            needsPairing = true
            isConnected = false
            status = "Pair this device again"
        }
        error = failure.localizedDescription
    }

    private func pairingInvitation(from url: URL) -> PairingQR? {
        guard !pairingInProgress, !rotationInProgress, !isSending else { return nil }
        let profile = KeychainStore.readProfile()
        let candidate = PairingQR.parse(url, trustedEndpoint: profile?.endpoint,
                                        trustedFingerprint: profile?.fingerprint)
        guard let candidate else {
            error = "This pairing QR code is invalid or unsupported."
            return nil
        }
        error = nil
        return candidate
    }

    func preparePair(from url: URL) {
        pairingCandidate = pairingInvitation(from: url)
    }

    // Only the in-app scanner and authenticated nearby exchange may use this path.
    // External URL callbacks must retain an explicit pairing confirmation.
    func pairFromVerifiedInvitation(_ url: URL) async {
        guard pairingCandidate == nil, let candidate = pairingInvitation(from: url) else { return }
        await confirmPairing(candidate)
    }

    func cancelPairing() { pairingCandidate = nil }

    func disableAppProtectionWithAuthentication() async {
        guard !isChangingAppProtection, !Task.isCancelled else { return }
        isChangingAppProtection = true
        appProtectionError = nil
        defer { isChangingAppProtection = false }
        let context = LAContext()
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Authenticate to turn off \(DeviceAuthentication.name) protection for agentOS.")
            guard !Task.isCancelled else { return }
            guard allowed else {
                appProtectionError = "Protection stays on. Authenticate to turn it off."
                return
            }
            UserDefaults.standard.set(false, forKey: "faceIDEnabled")
        } catch {
            guard !Task.isCancelled else { return }
            appProtectionError = "Protection stays on. Authenticate to turn it off."
        }
    }

    func disconnectWithAuthentication() async {
        guard !isRemovingPairing, !isSending, !isPairing, !apiKey.isEmpty else { return }
        isRemovingPairing = true
        defer { isRemovingPairing = false }
        let revision = connectionRevision
        let context = LAContext()
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Authenticate to remove this iPhone’s Hermes pairing.")
            guard allowed, revision == connectionRevision else { return }
            disconnect()
        } catch {
            guard revision == connectionRevision else { return }
            self.error = "Pairing was not removed. Authenticate to disconnect this iPhone."
        }
    }

    func disconnect() {
        connectionRevision += 1
        activeStream?.cancel()
        activeStream = nil
        activeSendID = nil
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
        needsPairing = false
        error = nil
        status = "Not connected"
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
                                                  token: result.token, deviceID: result.deviceID, certificateAcceptedAt: result.certificateAcceptedAt ?? Date())
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
        } catch { status = wasConnected ? previousStatus : "Pairing failed"; recordError(error) }
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
                                                      token: token, deviceID: oldProfile.deviceID, certificateAcceptedAt: oldProfile.certificateAcceptedAt)
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
            recordError(error)
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
        let revision = connectionRevision
        deletingSessionIDs.insert(id)
        defer { deletingSessionIDs.remove(id) }
        try await api.deleteSession(id: id)
        guard revision == connectionRevision else { throw CancellationError() }
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

    func deleteSessions(_ ids: Set<String>) async throws {
        let revision = connectionRevision
        for id in ids.sorted() {
            guard revision == connectionRevision, !isSending else { throw CancellationError() }
            try await deleteSession(id)
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
            messages = withStoredModels(loaded, sessionID: sessionID)
            error = nil
        } catch {
            guard selectedSessionID == sessionID else { return }
            recordError(error)
        }
    }

    func send() async {
        guard !isSending else { return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil else { return }
        guard let api else { error = HermesError.missingKey.localizedDescription; return }
        let sendID = UUID()
        let revision = connectionRevision
        let token = apiKey
        let selectedAtStart = selectedSessionID
        activeSendID = sendID
        activeSendAccepted = false
        sendStopRequested = false
        isSending = true
        error = nil
        toolActivity = nil
        draft = ""
        pendingImage = nil
        if selectedSessionID == nil {
            do {
                let session = try await api.createSession()
                guard isCurrentSend(sendID, revision: revision, sessionID: selectedAtStart, token: token) else {
                    finishSend(sendID)
                    return
                }
                sessions.insert(session, at: 0)
                selectedSessionID = session.id
                if sendStopRequested {
                    restoreDraft(originalDraft, image: image)
                    finishSend(sendID)
                    return
                }
            } catch {
                guard isCurrentSend(sendID, revision: revision, sessionID: selectedAtStart, token: token) else {
                    finishSend(sendID)
                    return
                }
                restoreDraft(originalDraft, image: image)
                recordError(error)
                finishSend(sendID)
                return
            }
        }
        guard let sessionID = selectedSessionID,
              activeSendID == sendID, connectionRevision == revision, apiKey == token else {
            finishSend(sendID)
            return
        }
        if sendStopRequested {
            restoreDraft(originalDraft, image: image)
            finishSend(sendID)
            return
        }
        let user = ChatMessage(role: .user, content: text.isEmpty ? "[Image]" : text + (image == nil ? "" : "\n[Image]"), timestamp: Date())
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true, timestamp: Date())
        messages.append(contentsOf: [user, reply])
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].lastActive = user.timestamp
        }
        do {
            activeStream = Task { [weak self] in
                try await api.send(sessionID: sessionID, text: text, image: image) { [weak self] event, payload in
                    await self?.handle(event: event, payload: payload, messageID: reply.id, sendID: sendID,
                                       revision: revision, sessionID: sessionID, token: token)
                }
            }
            try await activeStream?.value
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else {
                finishSend(sendID)
                return
            }
            if let last = messages.lastIndex(where: { $0.id == reply.id }), messages[last].isStreaming {
                messages[last].isStreaming = false
            }
            toolActivity = nil
            await reconcileAfterSend(api, sessionID: sessionID, reply: reply, sendID: sendID,
                                     revision: revision, token: token)
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else {
                finishSend(sendID)
                return
            }
            finishSend(sendID)
        } catch {
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else {
                finishSend(sendID)
                return
            }
            let accepted = activeSendAccepted || isAcceptedStreamFailure(error)
            if !accepted && isDefiniteRejection(error) {
                messages.removeAll { $0.id == user.id || $0.id == reply.id }
                restoreDraft(originalDraft, image: image)
                self.error = isCertificateFailure(error)
                    ? "Hermes’s certificate could not be verified. Your message was not sent; check the trusted connection before retrying."
                    : error.localizedDescription
            } else {
                if let last = messages.lastIndex(where: { $0.id == reply.id }) {
                    messages[last].isStreaming = false
                    if messages[last].content.isEmpty {
                        messages[last].content = sendStopRequested
                            ? "Stopped before a reply arrived. Hermes may have received this message; refresh before retrying."
                            : "No complete reply arrived. Hermes may have received this message; refresh before retrying."
                    }
                }
                toolActivity = nil
                self.error = sendStopRequested ? "Stopped. Refresh the conversation before retrying." : error.localizedDescription
                if accepted {
                    await reconcileAfterSend(api, sessionID: sessionID, reply: reply, sendID: sendID,
                                             revision: revision, token: token)
                    guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else {
                        finishSend(sendID)
                        return
                    }
                }
            }
            if case HermesError.badResponse(401, _) = error { recordError(error) }
            finishSend(sendID)
        }
    }

    private func isCurrentSend(_ id: UUID, revision: Int, sessionID: String?, token: String) -> Bool {
        activeSendID == id && connectionRevision == revision && selectedSessionID == sessionID && apiKey == token
    }

    private func finishSend(_ id: UUID) {
        guard activeSendID == id else { return }
        activeStream = nil
        activeSendID = nil
        activeSendAccepted = false
        sendStopRequested = false
        isSending = false
        toolActivity = nil
        pendingApproval = nil
    }

    private func restoreDraft(_ original: String, image: PendingImage?) {
        if draft.isEmpty { draft = original }
        else if !original.isEmpty { draft = original + "\n\n" + draft }
        if pendingImage == nil { pendingImage = image }
    }

    private func isCertificateFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
                .clientCertificateRequired].contains(error.code)
    }

    private func isDefiniteRejection(_ error: Error) -> Bool {
        if isCertificateFailure(error) { return true }
        if let error = error as? URLError {
            return [.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(error.code)
        }
        if case HermesError.badResponse(let status, _) = error { return (400..<500).contains(status) }
        return false
    }

    private func isAcceptedStreamFailure(_ error: Error) -> Bool {
        switch error {
        case HermesError.streamInterrupted, HermesError.streamFailed: return true
        default: return false
        }
    }

    private func handle(event: String, payload: [String: Any], messageID: String, sendID: UUID,
                        revision: Int, sessionID: String, token: String) {
        guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else { return }
        if event == "run.started" { activeSendAccepted = true }
        handle(event: event, payload: payload, messageID: messageID)
    }

    private func reconcileAfterSend(_ api: HermesAPI, sessionID: String, reply: ChatMessage,
                                    sendID: UUID, revision: Int, token: String) async {
        do {
            let saved = try await api.messages(sessionID: sessionID)
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else { return }
            // Never erase streamed text with an empty or not-yet-persisted final turn.
            if let local = messages.first(where: { $0.id == reply.id }),
               !local.content.isEmpty,
               saved.contains(where: { $0.role == .assistant && $0.content == local.content }) {
                var labeled = saved
                if let modelName = local.modelName,
                   let index = labeled.lastIndex(where: { $0.role == .assistant && $0.content == local.content }) {
                    labeled[index].modelName = modelName
                    UserDefaults.standard.set(modelName, forKey: modelKey(sessionID: sessionID, messageID: labeled[index].id))
                }
                messages = withStoredModels(labeled, sessionID: sessionID)
            }
            let refreshed = try await api.sessions()
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else { return }
            sessions = refreshed
        } catch {
            guard isCurrentSend(sendID, revision: revision, sessionID: sessionID, token: token) else { return }
            if self.error == nil { self.error = "The response is shown, but saved history could not be refreshed. Refresh before retrying." }
        }
    }

    func stop() {
        guard isSending else { return }
        sendStopRequested = true
        activeStream?.cancel()
    }

    func respondToApproval(_ choice: String) async {
        guard let approval = pendingApproval, let api else { return }
        do {
            try await api.respondToApproval(runID: approval.runID, requestID: approval.requestID, choice: choice)
            pendingApproval = nil
            error = nil
        } catch { recordError(error) }
    }

    private func modelKey(sessionID: String, messageID: String) -> String {
        "agentOS.messageModel|\(endpoint)|\(sessionID)|\(messageID)"
    }

    private func withStoredModels(_ items: [ChatMessage], sessionID: String) -> [ChatMessage] {
        items.map { item in
            var message = item
            if message.modelName == nil {
                message.modelName = UserDefaults.standard.string(forKey: modelKey(sessionID: sessionID, messageID: message.id))
            }
            return message
        }
    }

    private func handle(event: String, payload: [String: Any], messageID: String) {
        guard let index = messages.lastIndex(where: { $0.id == messageID }) else { return }
        if let runtime = payload["runtime"] as? [String: Any],
           let modelName = runtime["model"] as? String, !modelName.isEmpty {
            messages[index].modelName = modelName
        }
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
