# Development and validation

Build instructions are in the README. Full Xcode is required for compiling the SwiftUI apps and Icon Composer assets. The installer script creates a package for the build machine's architecture.

## Automated checks

```sh
python3 -m unittest discover -s MacRelay -p 'test_*.py'
python3 -m unittest discover -s Tests -p 'test_relay_transport.py'
python3 Tests/run_stream_transport_checks.py
sh Tests/run_pairing_state_checks.sh
swiftc Shared/NearbyPairingProtocol.swift Tests/NearbyPairingChecks.swift -o /tmp/agentos-nearby-check
/tmp/agentos-nearby-check
swiftc HermesPocket/Models.swift Tests/PairingChecks.swift -o /tmp/agentos-pairing-check
/tmp/agentos-pairing-check
```

Backend tests cover invitation expiry, replay, concurrent claims, access renewal, revocation, request validation, setup preservation, missing configuration, and listener validation. Transport fixtures cover TLS pins, redirects, authorization failures, stream framing, images, terminal events, truncation, and cancellation.

The Swift state harness uses in-memory API, Keychain, and authentication doubles. It covers failed pairing rollback, send recovery, stale callbacks, deletion failure, and authentication-dependent settings. Shared nearby-protocol tests cover commitments, code comparison, approval, ordering, replay, and encrypted delivery.

## Live diagnostics

`MacRelay/verify.py` checks an already-configured local deployment. `Tests/PairingTransportChecks.swift` accepts an endpoint and public fingerprint at runtime and uses deliberately invalid access to check TLS and authorization. Live diagnostics are distinct from isolated tests.

## Physical-device checks

Before distributing a build, exercise QR scanning, nearby discovery and code comparison, denied permissions, Face ID/Touch ID and fallback authentication, microphone support, Siri, iPad layouts, Dynamic Type, VoiceOver, and reconnect/error recovery on supported devices. Automated checks and successful builds do not establish these hardware results.

Connection preparation supports a default local Hermes account. Custom profiles, nonstandard services, and fresh-machine setup need separate validation. The current installer uses ad-hoc app signing and has not been Developer ID signed or notarized.
