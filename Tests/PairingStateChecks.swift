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
        print("Pairing state checks passed: failures preserve profile, success replaces state, stale connect and rotation are ignored")
    }
}
