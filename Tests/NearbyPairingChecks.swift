import Foundation

@main
enum NearbyPairingChecks {
    static let fakeInvitation = "hermespocket://pair?v=2&endpoint=https%3A%2F%2Ffixture-mac.local%3A8643&fingerprint=\(String(repeating: "a", count: 64))&code=\(String(repeating: "b", count: 43))"
    static let fakeDeviceToken = "FAKE-DEVICE-TOKEN-DO-NOT-USE"

    static func main() throws {
        try matchingCodesAndReleaseGate()
        try replayAndOrdering()
        try commitmentAndRevealTampering()
        try independentHandshakeCodes()
        try encryptedInvitationTampering()
        try malformedAndOversizedMessages()
        print("Nearby pairing protocol checks passed")
    }

    static func matchingCodesAndReleaseGate() throws {
        let (phone, mac, commit, hello, reveal) = try handshake()
        guard let phoneCode = phone.comparisonCode, let macCode = mac.comparisonCode,
              phoneCode == macCode, phoneCode.count == 6,
              phoneCode.utf8.allSatisfy({ (48...57).contains($0) }) else {
            fatalError("Both peers must derive the same six-digit comparison code")
        }
        let clearTranscript = String(decoding: commit + hello + reveal, as: UTF8.self)
        require(!clearTranscript.contains(fakeInvitation) && !clearTranscript.contains(fakeDeviceToken),
                "Invitation and device token must not appear before comparison")
        try expectThrow("Mac must not seal before explicit comparison confirmation") {
            _ = try mac.sealInvitation(fakeInvitation + fakeDeviceToken)
        }
        let (wrongPhone, wrongMac, _, _, _) = try handshake()
        let wrongMacCode = wrongMac.comparisonCode!
        let wrongAttemptCode = wrongMacCode == "000000" ? "000001" : "000000"
        try expectThrow("A different comparison code must not approve invitation release") {
            try wrongMac.confirmComparison(code: wrongAttemptCode)
        }
        try expectThrow("Failed comparison must not release a credential") {
            _ = try wrongMac.sealInvitation(fakeInvitation + fakeDeviceToken)
        }
        try expectThrow("A corrected code must not revive an aborted mismatch") {
            try wrongMac.confirmComparison(code: wrongMacCode)
        }
        require(wrongPhone.receivedInvitation == nil, "A failed comparison cannot deliver the invitation")
        require(phone.receivedInvitation == nil, "Phone must not receive an invitation before approval")

        try mac.confirmComparison(code: macCode)
        let sealed = try mac.sealInvitation(fakeInvitation + fakeDeviceToken)
        require(!String(decoding: sealed, as: UTF8.self).contains(fakeInvitation),
                "Invitation must be encrypted on the wire")
        try expectThrow("Invitation release must be one-use") { _ = try mac.sealInvitation(fakeInvitation) }
        _ = try phone.receive(sealed)
        require(phone.receivedInvitation == fakeInvitation + fakeDeviceToken,
                "Phone must decrypt the exact invitation after approval")
    }

    static func replayAndOrdering() throws {
        let phone = NearbyHandshake(role: .phone)
        let mac = NearbyHandshake(role: .mac)
        let commit = try phone.initialMessage()
        let hello = try unwrap(mac.receive(commit))
        try expectThrow("Commit replay must be rejected") { _ = try mac.receive(commit) }

        require(mac.comparisonCode == nil, "An incomplete Mac handshake cannot expose a comparison code")
        try expectThrow("A handshake invalidated by replay must not resume") { _ = try mac.receive(hello) }

        let (phone2, mac2, _, _, reveal2) = try handshake()
        try expectThrow("Phone cannot accept reveal as its first message") {
            _ = try NearbyHandshake(role: .phone).receive(reveal2)
        }
        try expectThrow("Mac cannot accept reveal before commitment") {
            _ = try NearbyHandshake(role: .mac).receive(reveal2)
        }
        try expectThrow("Phone cannot accept invitation before hello/reveal") {
            _ = try NearbyHandshake(role: .phone).receive(try JSONSerialization.data(withJSONObject: ["type": "invitation", "sealed": "AA=="]))
        }
        try mac2.confirmComparison(code: mac2.comparisonCode!)
        let invitation = try mac2.sealInvitation(fakeInvitation)
        _ = try phone2.receive(invitation)
        try expectThrow("Duplicate invitation delivery must be rejected") { _ = try phone2.receive(invitation) }
    }

    static func commitmentAndRevealTampering() throws {
        do {
            let phone = NearbyHandshake(role: .phone)
            let mac = NearbyHandshake(role: .mac)
            let original = try phone.initialMessage()
            var message = try object(original)
            var commitment = Data(base64Encoded: message["commitment"]!)!
            commitment[0] ^= 1
            message["commitment"] = commitment.base64EncodedString()
            let hello = try unwrap(mac.receive(try encode(message)))
            let reveal = try unwrap(phone.receive(hello))
            try expectThrow("Changed commitment must be rejected") { _ = try mac.receive(reveal) }
            require(mac.comparisonCode == nil, "Bad commitment must erase comparison state")
            try expectThrow("Changed commitment rejection must be terminal") { _ = try mac.receive(reveal) }
        }

        do {
            let phone = NearbyHandshake(role: .phone)
            let mac = NearbyHandshake(role: .mac)
            let commit = try phone.initialMessage()
            let hello = try unwrap(mac.receive(commit))
            var reveal = try object(try unwrap(phone.receive(hello)))
            var nonce = Data(base64Encoded: reveal["nonce"]!)!
            nonce[0] ^= 1
            reveal["nonce"] = nonce.base64EncodedString()
            try expectThrow("Changed reveal must fail its commitment") { _ = try mac.receive(try encode(reveal)) }
            require(mac.comparisonCode == nil, "Bad reveal must not leave a usable comparison code")
        }
    }

    static func encryptedInvitationTampering() throws {
        let (phone, mac, _, _, _) = try handshake()
        try mac.confirmComparison(code: mac.comparisonCode!)
        let sealed = try mac.sealInvitation(fakeInvitation + fakeDeviceToken)
        var envelope = try object(sealed)
        var combined = Data(base64Encoded: envelope["sealed"]!)!
        combined[combined.count / 2] ^= 0x40
        envelope["sealed"] = combined.base64EncodedString()
        try expectThrow("Modified ciphertext must fail authentication") { _ = try phone.receive(try encode(envelope)) }
        require(phone.receivedInvitation == nil, "Tampered ciphertext must not release invitation")
        try expectThrow("Authentication failure must close the receiver") { _ = try phone.receive(sealed) }
    }

    static func independentHandshakeCodes() throws {
        // A key-substitution intermediary terminates separate DH handshakes.
        // The codes should differ so a person comparing screens can reject it.
        var sawMismatch = false
        for _ in 0..<3 {
            let phone = NearbyHandshake(role: .phone)
            let mac = NearbyHandshake(role: .mac)
            let intermediary = NearbyHandshake(role: .mac)
            let commit = try phone.initialMessage()
            _ = try mac.receive(commit)
            let substitutedHello = try unwrap(intermediary.receive(commit))
            let reveal = try unwrap(phone.receive(substitutedHello))
            try require(mac.receive(reveal) == nil, "Real Mac must wait for comparison")
            if phone.comparisonCode != mac.comparisonCode { sawMismatch = true }
        }
        require(sawMismatch, "Substituted DH peers should yield different comparison codes")
    }

    static func malformedAndOversizedMessages() throws {
        let mac = NearbyHandshake(role: .mac)
        try expectThrow("Malformed JSON must be rejected") { _ = try mac.receive(Data("{not json".utf8)) }
        let validCommit = try NearbyHandshake(role: .phone).initialMessage()
        try expectThrow("Malformed input rejection must be terminal") { _ = try mac.receive(validCommit) }

        let oversize = Data(repeating: 0x41, count: 4097)
        try expectThrow("Messages larger than 4096 bytes must be rejected") {
            _ = try NearbyHandshake(role: .mac).receive(oversize)
        }

        let wrongFields = try JSONSerialization.data(withJSONObject: ["type": "commit", "commitment": "AA==", "extra": "ignored?"])
        try expectThrow("Unexpected message fields must be rejected") {
            _ = try NearbyHandshake(role: .mac).receive(wrongFields)
        }

        let wrongLength = try JSONSerialization.data(withJSONObject: ["type": "commit", "commitment": Data(repeating: 0, count: 31).base64EncodedString()])
        try expectThrow("Short commitments must be rejected") {
            _ = try NearbyHandshake(role: .mac).receive(wrongLength)
        }
    }

    static func handshake() throws -> (NearbyHandshake, NearbyHandshake, Data, Data, Data) {
        let phone = NearbyHandshake(role: .phone)
        let mac = NearbyHandshake(role: .mac)
        let commit = try phone.initialMessage()
        let hello = try unwrap(mac.receive(commit))
        let reveal = try unwrap(phone.receive(hello))
        try require(mac.receive(reveal) == nil, "Mac must wait for explicit human confirmation")
        return (phone, mac, commit, hello, reveal)
    }

    static func object(_ data: Data) throws -> [String: String] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CheckFailure.unexpectedMessage
        }
        return value
    }

    static func encode(_ value: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func unwrap(_ value: Data?) throws -> Data {
        guard let value else { throw CheckFailure.unexpectedMessage }
        return value
    }

    static func expectThrow(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw CheckFailure.expectedRejection(message)
        } catch is NearbyHandshake.Failure {
            return
        } catch let failure as CheckFailure {
            throw failure
        } catch {
            // CryptoKit authentication/key-agreement errors are valid rejections.
            return
        }
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }

    enum CheckFailure: Error {
        case unexpectedMessage
        case expectedRejection(String)
    }
}
