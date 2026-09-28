# Pairing and device access

## QR pairing

Choose **Scan QR code** in the Mac companion, then scan inside agentOS on your iPhone or iPad. A versioned invitation contains the local HTTPS endpoint, public certificate fingerprint, and a single-use code that expires after five minutes.

An in-app scan starts certificate verification and claims device access automatically. Links opened by an external Camera app ask for pairing confirmation. A failed claim or connection check preserves an existing saved profile.

Canceling, regenerating, or allowing an invitation to expire invalidates the unused invitation. If a response is lost after a claim, generate another invitation; an unused device record can be revoked from the companion.

## Nearby pairing

Choose **Scan nearby** on the Mac and **Pair nearby** on iOS. Select the Mac, accept its request, compare the six-digit codes on both screens, and approve only if they match. See [the nearby protocol](NEARBY_PAIRING.md).

## Access management

The phone stores its endpoint, certificate fingerprint, and device access together in Keychain. The Mac retains its Hermes master key and stores hashes of device credentials.

Device credentials renew after 30 days on the next successful connection, or manually in Settings. The previous credential has a ten-minute grace period. Renewal replaces access for that device; it does not restore revoked access.

**Revoke** on the Mac blocks subsequent authenticated requests. An already-running request may still finish. **Disconnect** on iOS removes the local profile; also revoke the device on the Mac when server access must be removed. Removing a pairing requires system authentication.

New pairings record the certificate acceptance time. Older records may show Not recorded; certificate acceptance is distinct from certificate issuance or expiry.
