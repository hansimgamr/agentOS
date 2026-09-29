import Foundation

// swiftc HermesPocket/Models.swift Tests/PairingChecks.swift -o /tmp/agentos-pairing-check && /tmp/agentos-pairing-check
@main
struct PairingChecks {
    static func main() {
        let pin = String(repeating: "a", count: 64)
        let code = String(repeating: "x", count: 43)
        func url(_ endpoint: String = "https://fixture-mac.local:8643", version: String = "2", fingerprint: String? = nil) -> URL {
            var parts = URLComponents()
            parts.scheme = "hermespocket"; parts.host = "pair"
            parts.queryItems = [.init(name: "v", value: version), .init(name: "endpoint", value: endpoint),
                                .init(name: "fingerprint", value: fingerprint ?? pin), .init(name: "code", value: code)]
            return parts.url!
        }
        precondition(PairingQR.parse(url())?.host == "fixture-mac.local")
        precondition(PairingQR.parse(url("https://my-mac.local:8643")) != nil)
        precondition(PairingQR.parse(url(version: "3")) == nil)
        precondition(PairingQR.parse(url(fingerprint: "invalid")) == nil)
        for endpoint in ["http://fixture-mac.local:8643", "https://example.com:8643", "https://fixture-mac.local:443",
                         "https://user:pass@fixture-mac.local:8643", "https://fixture-mac.local:8643/path",
                         "https://fixture-mac.local:8643?query=1", "https://fixture-mac.local:8643#fragment",
                         "https://10.bad.0.0.1:8643", "https://mac..local:8643"] {
            precondition(PairingQR.parse(url(endpoint)) == nil)
        }
        var duplicate = URLComponents(url: url(), resolvingAgainstBaseURL: false)!
        duplicate.queryItems!.append(.init(name: "code", value: code))
        precondition(PairingQR.parse(duplicate.url!) == nil)
        for field in ["user", "port", "path", "fragment"] {
            var parts = URLComponents(url: url(), resolvingAgainstBaseURL: false)!
            switch field {
            case "user": parts.user = "bad"
            case "port": parts.port = 123
            case "path": parts.path = "/unexpected"
            default: parts.fragment = "unexpected"
            }
            precondition(PairingQR.parse(parts.url!) == nil)
        }
        let legacy = URL(string: "hermespocket://pair?code=" + code)!
        precondition(PairingQR.parse(legacy) == nil)
        precondition(PairingQR.parse(legacy, trustedEndpoint: "https://my-mac.local:8643", trustedFingerprint: pin) != nil)
        precondition(!PairingQR.isLocalHost("10.bad.0.0.1"))
        precondition(!PairingQR.isLocalHost("fixture-mac.local"))
        print("Pairing parser checks passed: valid v2, trusted legacy, duplicate/invalid fields and endpoint restrictions")
    }
}
