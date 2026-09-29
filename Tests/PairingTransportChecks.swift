import Foundation

// swiftc HermesPocket/Models.swift HermesPocket/KeychainStore.swift HermesPocket/HermesAPI.swift Tests/PairingTransportChecks.swift -o /tmp/agentos-pin-check
// Run with the configured public HTTPS endpoint and public certificate fingerprint.
@main
struct PairingTransportChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Provide endpoint and public fingerprint") }
        let endpoint = CommandLine.arguments[1]
        let fingerprint = CommandLine.arguments[2]
        for streaming in [true, false] {
            // Each check starts a fresh URLSession: a health preflight hid the original stream bug.
            let validPin = try HermesAPI(endpoint: endpoint, apiKey: "deliberately-invalid-test-token", fingerprint: fingerprint)
            do {
                if streaming { try await validPin.send(sessionID: "pin-check", text: "test", image: nil) { _, _ in } }
                else { try await validPin.checkConnection() }
                fatalError("Relay must reject invalid token")
            } catch HermesError.badResponse(let status, _) { precondition(status == 401) }
            let wrongPin = try HermesAPI(endpoint: endpoint, apiKey: "deliberately-invalid-test-token", fingerprint: String(repeating: "0", count: 64))
            do {
                if streaming { try await wrongPin.send(sessionID: "pin-check", text: "test", image: nil) { _, _ in } }
                else { try await wrongPin.checkConnection() }
                fatalError("Wrong pin must fail before authenticated HTTP")
            } catch is HermesError { fatalError("Wrong pin reached HTTP instead of failing TLS") }
            catch { }
        }
        print("Cold TLS checks passed for health and streaming: correct pin reaches auth; wrong pin rejected before HTTP")
    }
}
