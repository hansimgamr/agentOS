# Nearby pairing protocol

Nearby pairing uses encrypted Apple Multipeer Connectivity sessions. Discovery starts when requested and ends after cancellation, expiry, or closing/hiding the companion. Discovery names are hints, not proof of identity or physical distance. Chat still requires a reachable local HTTPS relay.

## Handshake

1. The phone commits an ephemeral Curve25519 public key and random nonce before the Mac reveals its key and nonce.
2. The phone reveals its committed values. Both peers derive a session key with HKDF-SHA256 using the transcript.
3. Both screens display a six-digit HMAC comparison code. Approval on the Mac is required before releasing an invitation.
4. AES-GCM encrypts and authenticates the invitation in addition to session encryption.
5. The phone verifies the supplied relay certificate pin and exchanges the single-use invitation over HTTPS for its own device access.

Strict field validation, bounded messages, sequence checks, one selected peer, timeouts, and cancellation limit the exchange. Unexpected streams and file transfers are rejected. Credentials are not advertised in discovery metadata.

Compare codes on the actual devices. Six-digit comparison has finite guessing resistance and is not hardware attestation. The application protocol has not received an independent cryptographic review.

## References

- [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)
- [Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [VisionKit scanning](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller)
