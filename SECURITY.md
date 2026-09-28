# Security

Keep deployment credentials outside the source repository. Never commit or upload environment files, API keys, device tokens, pairing codes or QR images, Keychain exports, private signing material, or runtime credential registries. Do not paste them into issues, commit messages, screenshots, build logs, or documentation. Use placeholders when explaining configuration.

## Authentication and transport

Hermes listens on loopback. A local HTTPS relay accepts paired device credentials and substitutes the Mac-only Hermes credential when forwarding permitted routes. The iOS client pins the relay certificate and rejects redirects. Certificate fingerprints are public identifiers, not authentication credentials. Certificate private keys remain outside the repository.

The relay stores hashes of device credentials. Pairing codes are single-use and expire after five minutes. Device credentials rotate after 30 days on the next successful connection, or manually in Settings. Previous credentials have a ten-minute rotation grace period. Device revocation is available in the Mac companion or through `MacRelay/pair.py revoke DEVICE_ID`.

The app stores device access in the device-only, when-unlocked Keychain and, by default, gates the interface using the biometric type reported by LocalAuthentication. The toggle names Face ID or Touch ID; system authentication retains the device passcode fallback. Protected content is concealed while inactive and the app locks when entering the background. Dictation requires on-device speech recognition. Chat content and images may still be sent to the model provider configured in Hermes.

## Operational boundaries

Paired devices can invoke the agent through chat and approval routes. Protect and revoke them accordingly. This is a local-network deployment; do not expose the relay through router port forwarding. The relay listener is configured locally during Prepare connection. New iPhone pairings import a local HTTPS endpoint and exact public certificate fingerprint from a user-scanned versioned QR; no machine-specific endpoint or certificate trust is bundled. Existing saved Keychain profiles retain their trust; older installs without a complete profile must pair again. This is not a public certificate enrollment service.

Keep the Mac environment, relay private key, pairing files, and device registry in their private runtime directory with owner-only access. Pairing QR images are sensitive even though short-lived. They must not be published.

## Credential handling

Keep credentials out of source files, issues, screenshots, and logs. If a credential is exposed, revoke or rotate it promptly. Protect the runtime directory and avoid sharing pairing invitations.

Search retrieves history through the existing authenticated API into memory only. It does not publish chat contents to Spotlight or Siri. The Siri shortcut opens the foreground app's protected search interface. Dictation uses on-device Speech recognition and preserves a review-before-send step.

## Companion trust model

The companion runs an owner-local management helper over standard input/output; it opens no network admin port. Helper responses contain no master keys, stored token hashes, or agent content. A fresh invitation response necessarily contains a short-lived secret in its QR URL; it stays in app memory and must not appear in logs, screenshots, documentation, or Git. Ticket-specific cancellation prevents a stale window from invalidating a newer invitation.

A user-initiated in-app QR scan or the encrypted, Mac-approved nearby exchange establishes the pairing source. Scan only a code displayed by your own Mac companion. External links require explicit confirmation on the phone. TLS pinning protects the subsequent exchange; it does not make a malicious QR trustworthy. Pairing requests use the invitation, never an existing device bearer token. The new connection is stored as one Keychain profile after verification; failed attempts preserve the previous profile.

Revocation denies future requests, including old rotation-grace tokens. Already-running streams may continue until completion, and downloaded data cannot be recalled. The companion requires a trusted local user account and the existing private Hermes runtime directory. It is not hardened against code executing as that same user.

The device-specific app-protection toggle controls the app unlock requirement and defaults to on. Turning it off first requires a fresh device-owner authentication (the detected biometric, with the system passcode fallback). Failed, cancelled, or abandoned requests leave it enabled. Only successful authentication removes this additional app gate; Keychain storage and TLS protections remain in place. Inactive previews are concealed while Face ID protection is enabled. With protection off, the app uses its normal unshielded launch/resume appearance.

## Nearby discovery and pairing

Nearby discovery is opt-in and is not evidence of physical distance or device identity. The Mac approves a requesting peer, and both screens display a comparison code derived from a committed ephemeral Curve25519 exchange. An explicit Mac confirmation gates invitation creation and authenticated AES-GCM delivery. The app still validates the invitation and automatically checks the supplied relay certificate pin before claiming access. Six-digit comparison depends on the user actually comparing both screens; the handshake has not received an independent cryptographic audit. See [the nearby-pairing design](docs/NEARBY_PAIRING.md) for protocol and transport limits. No credentials are advertised in discovery metadata.

The QR scanner reads pairing codes with VisionKit and requests camera access only when opened. Camera frames are not uploaded or persisted by agentOS. The scanned invitation remains in memory; the client automatically verifies its exact certificate pin and completes pairing.

## Streaming transport

Fresh streaming requests explicitly use the same pinned trust delegate as ordinary API requests, including task-level TLS challenges and redirect rejection. No health preflight is required for trust. SSE parsing is bounded and requires terminal completion; a disconnected stream is not proof that a message was saved or unsent. The app does not automatically retry uncertain sends. The [send-path audit](docs/CHAT_TRANSPORT.md) records the reproduced failure and verification scope.

With Face ID disabled, the root view renders directly on launch and resume, without an unlock-screen or privacy-cover transition. With protection enabled, successful authentication reveals cached app content without an added SwiftUI transition or redundant connection refresh. System Face ID timing remains controlled by iOS.

## Revoked access and recovery

A rejected device credential requires pairing again. The recovery screen does not bypass authentication or silently re-enroll the phone. Disconnect removes local credentials and clears stale errors; it does not revoke server-side access. Manual token rotation renews authorized access and cannot restore a revoked device.

## Certificate acceptance metadata

New QR/nearby claims store a server timestamp and the relay certificate fingerprint with the device record. The timestamp is returned to the iPhone and saved with its pinned connection profile in Keychain after a successful health check. It records pairing completion, not certificate issuance/expiry or a separately attested human action. Key rotation preserves it. Older records stay unknown; pairing with an older relay records the local completion time on the phone only. Metadata does not alter certificate pinning, authentication, or revocation.

## Authenticate before removing pairings

The Mac companion's Revoke action and iPhone Settings' Disconnect action evaluate Apple's `deviceOwnerAuthentication` policy before removing access. This permits Touch ID/Face ID with the OS password/passcode fallback. Cancellation, failure, and unavailable authentication leave access unchanged. The iPhone additionally refuses to remove a replacement pairing if the connection changed during authentication. This UI gate is independent of the optional app-unlock preference; Mac command-line administration remains available to the account owner.

## Local preparation

Prepare connection is a local child-process action, not a network administration endpoint. It requires an existing Hermes CLI, preserves strong existing API keys, generates missing keys privately, and rejects linked/unowned target files. It creates a private-LAN HTTPS relay and keeps the Hermes API on loopback. Existing certificate/key pairs are reused, never silently replaced. It may configure and restart an unhealthy default Hermes gateway through the installed CLI. The helper does not configure the model provider, install Hermes, or forward router ports.

## Pairing consent and automatic pin checks

User-initiated in-app QR scanning and the approved encrypted nearby exchange establish the invitation source. These paths automatically claim using the supplied certificate fingerprint, with no redundant fingerprint checkbox. External URL callbacks still require explicit pairing consent; URL delivery alone cannot prove a Camera scan. Nearby number comparison remains required. TLS pin checks, redirect rejection, one-use invitation expiry, and Keychain persistence are unchanged; failed claims, health checks, or storage leave an existing profile intact.

Authentication labels use `LAContext.biometryType` after a biometric capability query: Face ID or Touch ID, otherwise Passcode on iOS and Password on macOS. This changes presentation only; device-owner authentication and its system-managed fallback remain in force. No hardware model guessing or biometric data collection is used.
