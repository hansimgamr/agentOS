import Foundation

@main struct PairingStateChecks {
    @MainActor static func main() async throws {
        let old = HermesConnectionProfile(endpoint: "https://old.local:8643", fingerprint: String(repeating: "a", count: 64), token: "old-token", deviceID: "old-device")
        let candidateURL = URL(string: "hermespocket://pair?v=2&endpoint=https%3A%2F%2Fnew.local%3A8643&fingerprint=\(String(repeating: "b", count: 64))&code=\(String(repeating: "x", count: 43))")!
        func setup() -> ChatStore {
            TestKeychainStore.reset(); PairingTestControl.reset(); TestKeychainStore.profile = old
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hermes.deviceKeyRotatedAt")
            return ChatStore()
        }

        for failure in ["claim", "health", "storage"] {
            let store = setup(); store.draft = "keep this"; store.sessions = [ChatSession(id: "old-session")]
            if failure == "claim" { PairingTestControl.claimFails = true }
            if failure == "health" { PairingTestControl.failingHealthEndpoints.insert("https://new.local:8643") }
            if failure == "storage" { TestKeychainStore.failProfileSave = true }
            store.preparePair(from: candidateURL)
            await store.confirmPairing(store.pairingCandidate!)
            precondition(TestKeychainStore.profile == old && store.apiKey == old.token)
            precondition(store.draft == "keep this" && store.sessions.first?.id == "old-session")
        }

        let paired = setup(); paired.draft = "do not send this to the new server"; paired.sessions = [ChatSession(id: "old-session")]
        paired.preparePair(from: candidateURL)
        await paired.confirmPairing(paired.pairingCandidate!)
        precondition(TestKeychainStore.profile?.endpoint == "https://new.local:8643")
        precondition(paired.apiKey == "new-token" && paired.draft.isEmpty && paired.sessions.first?.id == "fresh")

        let connecting = setup(); PairingTestControl.healthSuspended = true
        let connectTask = Task { await connecting.connect() }
        await PairingTestControl.waitForHealth()
        connecting.disconnect(); PairingTestControl.releaseHealth()
        await connectTask.value
        precondition(TestKeychainStore.profile == nil && connecting.sessions.isEmpty && connecting.apiKey.isEmpty)

        let rotating = setup(); PairingTestControl.rotationSuspended = true
        let rotationTask = Task { await rotating.rotateDeviceKey() }
        await PairingTestControl.waitForRotation()
        let replacement = HermesConnectionProfile(endpoint: "https://other.local:8643", fingerprint: String(repeating: "c", count: 64), token: "replacement", deviceID: "replacement-id")
        TestKeychainStore.profile = replacement
        PairingTestControl.releaseRotation(); await rotationTask.value
        precondition(TestKeychainStore.profile == replacement && rotating.apiKey == old.token)
        let drafting = setup()
        drafting.selectedSessionID = "old-session"
        drafting.messages = [ChatMessage(role: .user, content: "old message")]
        drafting.draft = "old draft"
        drafting.error = "old error"
        precondition(drafting.startNewConversation())
        precondition(drafting.selectedSessionID == nil && drafting.messages.isEmpty && drafting.draft.isEmpty && drafting.error == nil)
        precondition(TestKeychainStore.profile == old)
        drafting.isSending = true
        drafting.draft = "sending draft"
        precondition(!drafting.startNewConversation() && drafting.draft == "sending draft")

        let rejected = setup()
        rejected.selectedSessionID = "old-session"
        rejected.draft = "retry me"
        let image = PendingImage(data: Data([1, 2, 3]), mimeType: "image/jpeg")
        rejected.pendingImage = image
        PairingTestControl.sendError = URLError(.serverCertificateUntrusted)
        await rejected.send()
        precondition(rejected.draft == "retry me" && rejected.pendingImage?.data == image.data)
        precondition(rejected.messages.isEmpty && !rejected.isSending)
        precondition(rejected.error?.contains("certificate") == true)

        let partial = setup()
        partial.selectedSessionID = "old-session"
        partial.draft = "do not auto-retry"
        PairingTestControl.sendEvents = [
            ("run.started", [:]),
            ("assistant.delta", ["delta": "partial reply"])
        ]
        PairingTestControl.sendError = HermesError.streamInterrupted
        await partial.send()
        precondition(partial.messages.contains { $0.role == .assistant && $0.content.contains("partial reply") })
        precondition(!partial.messages.contains { $0.content.contains("saved") })
        precondition(partial.draft.isEmpty && !partial.isSending)

        let stoppedBeforePost = setup()
        stoppedBeforePost.draft = "keep before network send"
        stoppedBeforePost.pendingImage = image
        PairingTestControl.createSuspended = true
        let createTask = Task { await stoppedBeforePost.send() }
        await PairingTestControl.waitForCreate()
        stoppedBeforePost.stop()
        PairingTestControl.releaseCreate()
        await createTask.value
        precondition(!PairingTestControl.sendCalled)
        precondition(stoppedBeforePost.draft == "keep before network send")
        precondition(stoppedBeforePost.pendingImage?.data == image.data && !stoppedBeforePost.isSending)

        let staleSelection = setup()
        staleSelection.selectedSessionID = "old-session"
        staleSelection.draft = "message in flight"
        PairingTestControl.sendEvents = [
            ("run.started", [:]),
            ("assistant.delta", ["delta": "partial"])
        ]
        PairingTestControl.sendSuspended = true
        PairingTestControl.sendError = HermesError.streamInterrupted
        let staleTask = Task { await staleSelection.send() }
        await PairingTestControl.waitForSend()
        let beforeSelectionChange = staleSelection.messages
        staleSelection.selectedSessionID = "other-session"
        staleSelection.error = "selection changed"
        PairingTestControl.releaseSend()
        await staleTask.value
        precondition(staleSelection.messages == beforeSelectionChange && staleSelection.error == "selection changed")

        let staleDisconnect = setup()
        staleDisconnect.selectedSessionID = "old-session"
        staleDisconnect.draft = "message in flight"
        PairingTestControl.sendEvents = [("run.started", [:])]
        PairingTestControl.sendSuspended = true
        PairingTestControl.sendError = HermesError.streamInterrupted
        let disconnectTask = Task { await staleDisconnect.send() }
        await PairingTestControl.waitForSend()
        staleDisconnect.disconnect()
        PairingTestControl.releaseSend()
        await disconnectTask.value
        precondition(staleDisconnect.messages.isEmpty && staleDisconnect.apiKey.isEmpty)
        precondition(staleDisconnect.error == nil && !staleDisconnect.isSending)
        print("Pairing state checks passed: pair rollback, send failure recovery, partial stream, stop race, and stale callback guards")
    }
}
