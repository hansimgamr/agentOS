import Foundation
import CryptoKit

// Commit before revealing either side's full transcript. Users must compare the
// resulting code on both screens before the Mac calls sealInvitation.
final class NearbyHandshake {
    enum Role { case phone, mac }
    enum Failure: Error { case invalidMessage, invalidState, commitmentMismatch }
    let role: Role
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    private var stage = 0
    private var commitment: Data?
    private var key: SymmetricKey?
    private(set) var comparisonCode: String?
    private(set) var receivedInvitation: String?

    init(role: Role) { self.role = role }

    func initialMessage() throws -> Data {
        guard role == .phone, stage == 0 else { throw Failure.invalidState }
        stage = 1
        return try encode(["type": "commit", "commitment": Data(SHA256.hash(data: publicKey + nonce)).base64EncodedString()])
    }

    // Returns the next handshake message, or nil when awaiting human approval.
    func receive(_ data: Data) throws -> Data? {
        do { return try process(data) }
        catch {
            stage = -1
            key = nil
            commitment = nil
            comparisonCode = nil
            receivedInvitation = nil
            throw error
        }
    }

    private func process(_ data: Data) throws -> Data? {
        guard data.count <= 4096,
              let message = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let type = message["type"] else { throw Failure.invalidMessage }
        switch (role, stage, type) {
        case (.mac, 0, "commit"):
            guard Set(message.keys) == ["type", "commitment"] else { throw Failure.invalidMessage }
            commitment = try bytes(message, "commitment")
            stage = 1
            return try encode(["type": "hello", "publicKey": publicKey.base64EncodedString(), "nonce": nonce.base64EncodedString()])
        case (.phone, 1, "hello"):
            guard Set(message.keys) == ["type", "publicKey", "nonce"] else { throw Failure.invalidMessage }
            let remoteKey = try bytes(message, "publicKey"), remoteNonce = try bytes(message, "nonce")
            try derive(remoteKey: remoteKey, phoneTranscript: publicKey + nonce, macTranscript: remoteKey + remoteNonce)
            stage = 2
            return try encode(["type": "reveal", "publicKey": publicKey.base64EncodedString(), "nonce": nonce.base64EncodedString()])
        case (.mac, 1, "reveal"):
            guard Set(message.keys) == ["type", "publicKey", "nonce"] else { throw Failure.invalidMessage }
            let remoteKey = try bytes(message, "publicKey"), remoteNonce = try bytes(message, "nonce")
            guard Data(SHA256.hash(data: remoteKey + remoteNonce)) == commitment else { throw Failure.commitmentMismatch }
            try derive(remoteKey: remoteKey, phoneTranscript: remoteKey + remoteNonce, macTranscript: publicKey + nonce)
            stage = 2
            return nil
        case (.phone, 2, "invitation"):
            guard Set(message.keys) == ["type", "sealed"], let key,
                  let value = message["sealed"], let combined = Data(base64Encoded: value) else { throw Failure.invalidMessage }
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key,
                                             authenticating: Data("agentOS-nearby-invitation-v1".utf8))
            guard let invitation = String(data: plaintext, encoding: .utf8), !invitation.isEmpty else { throw Failure.invalidMessage }
            receivedInvitation = invitation
            stage = 3
            return nil
        default: throw Failure.invalidState
        }
    }

    // Call only from the Mac's explicit “Codes match” action after visual comparison.
    func confirmComparison(code: String) throws {
        guard role == .mac, stage == 2, let comparisonCode, code == comparisonCode else {
            stage = -1
            key = nil
            comparisonCode = nil
            throw Failure.invalidState
        }
        stage = 4
    }

    func sealInvitation(_ invitation: String) throws -> Data {
        guard role == .mac, stage == 4, let key else { throw Failure.invalidState }
        guard invitation.utf8.count <= 2048 else { throw Failure.invalidMessage }
        let box = try AES.GCM.seal(Data(invitation.utf8), using: key,
                                   authenticating: Data("agentOS-nearby-invitation-v1".utf8))
        guard let combined = box.combined else { throw Failure.invalidMessage }
        stage = 3
        return try encode(["type": "invitation", "sealed": combined.base64EncodedString()])
    }

    private var publicKey: Data { privateKey.publicKey.rawRepresentation }
    private func derive(remoteKey: Data, phoneTranscript: Data, macTranscript: Data) throws {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteKey))
        let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data(SHA256.hash(data: phoneTranscript + macTranscript)),
            sharedInfo: Data("agentOS-nearby-v1".utf8), outputByteCount: 32)
        key = derived
        let check = HMAC<SHA256>.authenticationCode(for: Data("compare".utf8), using: derived)
        let number = check.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        comparisonCode = String(format: "%06u", number % 1_000_000)
    }
    private func bytes(_ message: [String: String], _ field: String) throws -> Data {
        guard let value = message[field], let data = Data(base64Encoded: value), data.count == 32 else { throw Failure.invalidMessage }
        return data
    }
    private func encode(_ message: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    }
}
