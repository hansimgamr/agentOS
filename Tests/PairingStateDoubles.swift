import Foundation
import LocalAuthentication

struct HermesConnectionProfile: Codable, Equatable {
    let endpoint: String
    let fingerprint: String
    let token: String
    let deviceID: String?
    var certificateAcceptedAt: Date? = nil
}

enum TestKeychainStore {
    static var profile: HermesConnectionProfile?
    static var deviceKey: String?
    static var legacyKey: String?
    static var failProfileSave = false

    static func reset() { profile = nil; deviceKey = nil; legacyKey = nil; failProfileSave = false }
    static func readProfile() -> HermesConnectionProfile? { profile }
    static func saveProfile(_ value: HermesConnectionProfile) -> Bool {
        guard !failProfileSave else { return false }
        profile = value
        return true
    }
    static func deleteProfile() { profile = nil }
    static func read() -> String? { deviceKey }
    static func readLegacy() -> String? { legacyKey }
    static func save(_ value: String) -> Bool { deviceKey = value; return true }
    static func deleteDeviceKey() { deviceKey = nil }
    static func deleteLegacy() { legacyKey = nil }
}

@MainActor enum PairingTestControl {
    static var deleteFailureID: String?
    static var deletedIDs: [String] = []
    static var duringDelete: (() -> Void)?
    static var claimFails = false
    static var failingHealthEndpoints = Set<String>()
    static var healthSuspended = false
    static var healthStarted = false
    static var healthStartWaiter: CheckedContinuation<Void, Never>?
    static var healthRelease: CheckedContinuation<Void, Never>?
    static var rotationSuspended = false
    static var rotationStarted = false
    static var rotationStartWaiter: CheckedContinuation<Void, Never>?
    static var rotationRelease: CheckedContinuation<Void, Never>?
    static var createSuspended = false
    static var createStarted = false
    static var createStartWaiter: CheckedContinuation<Void, Never>?
    static var createRelease: CheckedContinuation<Void, Never>?
    static var sendEvents: [(String, [String: Any])] = []
    static var sendError: Error?
    static var sendSuspended = false
    static var sendStarted = false
    static var sendWaiting = false
    static var sendStartWaiter: CheckedContinuation<Void, Never>?
    static var sendWaiter: CheckedContinuation<Void, Never>?
    static var sendRelease: CheckedContinuation<Void, Never>?
    static var sendCalled = false

    static func reset() {
        deleteFailureID = nil; deletedIDs = []; duringDelete = nil
        claimFails = false; failingHealthEndpoints = []; healthSuspended = false; healthStarted = false
        rotationSuspended = false; rotationStarted = false
        createSuspended = false; createStarted = false; createStartWaiter = nil; createRelease = nil
        sendEvents = []; sendError = nil; sendSuspended = false; sendStarted = false; sendWaiting = false
        sendStartWaiter = nil; sendWaiter = nil; sendRelease = nil; sendCalled = false
    }
    static func waitForHealth() async {
        if healthStarted { return }
        await withCheckedContinuation { healthStartWaiter = $0 }
    }
    static func releaseHealth() { healthRelease?.resume(); healthRelease = nil }
    static func waitForRotation() async {
        if rotationStarted { return }
        await withCheckedContinuation { rotationStartWaiter = $0 }
    }
    static func releaseRotation() { rotationRelease?.resume(); rotationRelease = nil }
    static func waitForCreate() async {
        if createStarted { return }
        await withCheckedContinuation { createStartWaiter = $0 }
    }
    static func releaseCreate() { createRelease?.resume(); createRelease = nil }
    static func waitForSend() async {
        if sendWaiting { return }
        await withCheckedContinuation { sendWaiter = $0 }
    }
    static func releaseSend() { sendRelease?.resume(); sendRelease = nil }
}

@MainActor struct TestHermesAPI {
    let endpoint: String
    let apiKey: String
    init(endpoint: String, apiKey: String, fingerprint: String) throws {
        self.endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
    }
    static func claimPairing(_ pairing: PairingQR, name: String) async throws -> (token: String, deviceID: String, certificateAcceptedAt: Date?) {
        if PairingTestControl.claimFails { throw TestFailure.failed }
        return ("new-token", "0123456789abcdef", Date(timeIntervalSince1970: 1_800_000_000))
    }
    func checkConnection() async throws {
        if PairingTestControl.healthSuspended {
            await withCheckedContinuation {
                PairingTestControl.healthStarted = true
                PairingTestControl.healthStartWaiter?.resume()
                PairingTestControl.healthStartWaiter = nil
                PairingTestControl.healthRelease = $0
            }
        }
        if PairingTestControl.failingHealthEndpoints.contains(endpoint) { throw TestFailure.failed }
    }
    func migrateLegacyKey() async throws -> String { "migrated" }
    func rotateDeviceKey() async throws -> String {
        if PairingTestControl.rotationSuspended {
            await withCheckedContinuation {
                PairingTestControl.rotationStarted = true
                PairingTestControl.rotationStartWaiter?.resume()
                PairingTestControl.rotationStartWaiter = nil
                PairingTestControl.rotationRelease = $0
            }
        }
        return "rotated-token"
    }
    func sessions(offset: Int = 0, limit: Int = 50) async throws -> [ChatSession] { [ChatSession(id: "fresh")] }
    func messages(sessionID: String) async throws -> [ChatMessage] { [] }
    func searchMessages(sessionID: String, query: String) async throws -> String? { nil }
    func deleteSession(id: String) async throws {
        PairingTestControl.duringDelete?()
        if PairingTestControl.deleteFailureID == id { throw TestFailure.failed }
        PairingTestControl.deletedIDs.append(id)
    }
    func createSession() async throws -> ChatSession {
        if PairingTestControl.createSuspended {
            await withCheckedContinuation {
                PairingTestControl.createStarted = true
                PairingTestControl.createStartWaiter?.resume()
                PairingTestControl.createStartWaiter = nil
                PairingTestControl.createRelease = $0
            }
        }
        return ChatSession(id: "created")
    }
    func send(sessionID: String, text: String, image: PendingImage?, receive: @escaping @Sendable (String, [String: Any]) async -> Void) async throws {
        PairingTestControl.sendCalled = true
        PairingTestControl.sendStarted = true
        PairingTestControl.sendStartWaiter?.resume()
        PairingTestControl.sendStartWaiter = nil
        for (event, payload) in PairingTestControl.sendEvents { await receive(event, payload) }
        if PairingTestControl.sendSuspended {
            await withCheckedContinuation {
                PairingTestControl.sendRelease = $0
                PairingTestControl.sendWaiting = true
                PairingTestControl.sendWaiter?.resume()
                PairingTestControl.sendWaiter = nil
            }
        }
        if let error = PairingTestControl.sendError { throw error }
    }
    func respondToApproval(runID: String, requestID: String?, choice: String) async throws { }
}

enum TestFailure: Error { case failed }

@MainActor final class TestLAContext {
    static var allowed = false
    static var fails = false
    static var duringAuthentication: (() -> Void)?
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        precondition(policy == .deviceOwnerAuthentication)
        Self.duringAuthentication?()
        if Self.fails { throw TestFailure.failed }
        return Self.allowed
    }
}
